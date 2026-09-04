/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIDevice+FBHelpers.h"

#import <arpa/inet.h>
#import <dlfcn.h>
#import <float.h>
#import <ifaddrs.h>
#import <mach/mach_time.h>
#import <math.h>
#import <UIKit/UIKit.h>
#include <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

#import "FBErrorBuilder.h"
#import "FBImageUtils.h"
#import "FBLogger.h"
#import "FBMacros.h"
#import "FBMathUtils.h"
#import "FBScreenshot.h"
#import "FBXCDeviceEvent.h"
#import "FBXCodeCompatibility.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIDevice.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCPointerEventPath.h"

static const NSTimeInterval FBHomeButtonCoolOffTime = 1.;
static const NSTimeInterval FBScreenLockTimeout = 5.;
static const NSUInteger FBPointArrayMaxInjectedPoints = 70;
static const NSTimeInterval FBPointArrayMinInjectedStep = 1.0 / 30.0;

static BOOL FBExtractCoordinatePoint(id rawPoint,
                                     CGFloat *x,
                                     CGFloat *y,
                                     NSNumber *__autoreleasing _Nullable *timestamp)
{
  if ([rawPoint isKindOfClass:NSDictionary.class]) {
    NSDictionary *pointDict = (NSDictionary *)rawPoint;
    id rawX = pointDict[@"x"] ?: pointDict[@"X"];
    id rawY = pointDict[@"y"] ?: pointDict[@"Y"];
    id rawTime = pointDict[@"t"] ?: pointDict[@"time"] ?: pointDict[@"timestamp"] ?: pointDict[@"delay"] ?: pointDict[@"duration"];
    if (![rawX isKindOfClass:NSNumber.class] || ![rawY isKindOfClass:NSNumber.class]) {
      return NO;
    }
    *x = ((NSNumber *)rawX).doubleValue;
    *y = ((NSNumber *)rawY).doubleValue;
    if (timestamp) {
      *timestamp = [rawTime isKindOfClass:NSNumber.class] ? (NSNumber *)rawTime : nil;
    }
    return YES;
  }
  if ([rawPoint isKindOfClass:NSArray.class]) {
    NSArray *pointValues = (NSArray *)rawPoint;
    if (pointValues.count < 2 ||
        ![pointValues[0] isKindOfClass:NSNumber.class] ||
        ![pointValues[1] isKindOfClass:NSNumber.class]) {
      return NO;
    }
    *x = ((NSNumber *)pointValues[0]).doubleValue;
    *y = ((NSNumber *)pointValues[1]).doubleValue;
    if (timestamp) {
      *timestamp = pointValues.count > 2 && [pointValues[2] isKindOfClass:NSNumber.class]
        ? (NSNumber *)pointValues[2]
        : nil;
    }
    return YES;
  }
  return NO;
}

static NSTimeInterval FBPointArrayTimestampSeconds(id rawTimestamp)
{
  if (![rawTimestamp isKindOfClass:NSNumber.class]) {
    return NAN;
  }
  NSTimeInterval result = ((NSNumber *)rawTimestamp).doubleValue;
  return result > 10.0 ? result / 1000.0 : result;
}

static NSArray<NSDictionary<NSString *, id> *> *FBCompactPointArray(NSArray<NSDictionary<NSString *, id> *> *points,
                                                                     NSUInteger maxPoints)
{
  if (points.count <= maxPoints) {
    return points;
  }

  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray arrayWithCapacity:maxPoints];
  NSUInteger lastIndex = points.count - 1;
  for (NSUInteger idx = 0; idx < maxPoints; idx++) {
    NSUInteger sourceIndex = (NSUInteger)llround(((double)idx * (double)lastIndex) / (double)(maxPoints - 1));
    [result addObject:points[sourceIndex]];
  }
  return result.copy;
}

static NSArray<NSDictionary<NSString *, id> *> *FBThrottlePointArrayForInjection(NSArray<NSDictionary<NSString *, id> *> *points)
{
  if (points.count <= 2) {
    return points;
  }

  NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray arrayWithCapacity:MIN(points.count, FBPointArrayMaxInjectedPoints)];
  NSDictionary<NSString *, id> *first = points.firstObject;
  [result addObject:first];

  NSTimeInterval lastKeptOffset = FBPointArrayTimestampSeconds(first[@"t"]);
  if (!isfinite(lastKeptOffset)) {
    lastKeptOffset = 0;
  }

  for (NSUInteger idx = 1; idx + 1 < points.count; idx++) {
    NSDictionary<NSString *, id> *point = points[idx];
    NSTimeInterval offset = FBPointArrayTimestampSeconds(point[@"t"]);
    if (idx == 1 && isfinite(offset)) {
      [result addObject:point];
      lastKeptOffset = offset;
      continue;
    }
    if (!isfinite(offset) || offset - lastKeptOffset < FBPointArrayMinInjectedStep) {
      continue;
    }
    [result addObject:point];
    lastKeptOffset = offset;
  }

  NSDictionary<NSString *, id> *last = points.lastObject;
  if (result.lastObject != last) {
    [result addObject:last];
  }

  return FBCompactPointArray(result.copy, FBPointArrayMaxInjectedPoints);
}

typedef struct {
  CGPoint origin;
  CGVector xAxis;
  CGVector yAxis;
} FBPointArrayScreenTransform;

static CGSize FBPointArrayScreenSizeForApplication(XCUIApplication *app)
{
  static UIInterfaceOrientation cachedOrientation = UIInterfaceOrientationUnknown;
  static CGSize cachedSize;
  UIInterfaceOrientation orientation = app.interfaceOrientation;
  @synchronized ([XCUIDevice class]) {
    if (cachedOrientation == orientation && cachedSize.width > 0 && cachedSize.height > 0) {
      return cachedSize;
    }
  }
  CGSize size = FBAdjustDimensionsForApplication(app.wdFrame.size, orientation);
  @synchronized ([XCUIDevice class]) {
    cachedOrientation = orientation;
    cachedSize = size;
  }
  return size;
}

static FBPointArrayScreenTransform FBPointArrayScreenTransformMakeForApplication(XCUIApplication *app)
{
  CGSize size = FBPointArrayScreenSizeForApplication(app);
  switch (app.interfaceOrientation) {
    case UIInterfaceOrientationLandscapeLeft:
      return (FBPointArrayScreenTransform){
        .origin = CGPointMake(0, size.width),
        .xAxis = CGVectorMake(0, -1),
        .yAxis = CGVectorMake(1, 0),
      };
    case UIInterfaceOrientationLandscapeRight:
      return (FBPointArrayScreenTransform){
        .origin = CGPointMake(size.height, 0),
        .xAxis = CGVectorMake(0, 1),
        .yAxis = CGVectorMake(-1, 0),
      };
    case UIInterfaceOrientationPortraitUpsideDown:
      return (FBPointArrayScreenTransform){
        .origin = CGPointMake(size.width, size.height),
        .xAxis = CGVectorMake(-1, 0),
        .yAxis = CGVectorMake(0, -1),
      };
    case UIInterfaceOrientationUnknown:
    case UIInterfaceOrientationPortrait:
    default:
      return (FBPointArrayScreenTransform){
        .origin = CGPointZero,
        .xAxis = CGVectorMake(1, 0),
        .yAxis = CGVectorMake(0, 1),
      };
  }
}

static CGPoint FBPointArrayScreenPoint(FBPointArrayScreenTransform transform, CGFloat x, CGFloat y)
{
  return CGPointMake(transform.origin.x + x * transform.xAxis.dx + y * transform.yAxis.dx,
                     transform.origin.y + x * transform.xAxis.dy + y * transform.yAxis.dy);
}

typedef CFTypeRef FBRealtimeTouchIOHIDEventRef;
typedef CFTypeRef FBRealtimeTouchIOHIDEventSystemClientRef;
typedef double FBRealtimeTouchIOHIDFloat;
typedef uint32_t FBRealtimeTouchIOHIDEventMask;
typedef uint32_t FBRealtimeTouchIOHIDOptions;

typedef FBRealtimeTouchIOHIDEventRef (*FBRealtimeTouchIOHIDCreateDigitizerEvent)(CFAllocatorRef allocator,
                                                                                 uint64_t timestamp,
                                                                                 uint32_t type,
                                                                                 uint32_t index,
                                                                                 uint32_t identity,
                                                                                 FBRealtimeTouchIOHIDEventMask eventMask,
                                                                                 uint32_t buttonMask,
                                                                                 FBRealtimeTouchIOHIDFloat x,
                                                                                 FBRealtimeTouchIOHIDFloat y,
                                                                                 FBRealtimeTouchIOHIDFloat z,
                                                                                 FBRealtimeTouchIOHIDFloat tipPressure,
                                                                                 FBRealtimeTouchIOHIDFloat barrelPressure,
                                                                                 Boolean range,
                                                                                 Boolean touch,
                                                                                 FBRealtimeTouchIOHIDOptions options);

typedef FBRealtimeTouchIOHIDEventRef (*FBRealtimeTouchIOHIDCreateDigitizerFingerEvent)(CFAllocatorRef allocator,
                                                                                       uint64_t timestamp,
                                                                                       uint32_t index,
                                                                                       uint32_t identity,
                                                                                       FBRealtimeTouchIOHIDEventMask eventMask,
                                                                                       FBRealtimeTouchIOHIDFloat x,
                                                                                       FBRealtimeTouchIOHIDFloat y,
                                                                                       FBRealtimeTouchIOHIDFloat z,
                                                                                       FBRealtimeTouchIOHIDFloat tipPressure,
                                                                                       FBRealtimeTouchIOHIDFloat twist,
                                                                                       Boolean range,
                                                                                       Boolean touch,
                                                                                       FBRealtimeTouchIOHIDOptions options);

typedef FBRealtimeTouchIOHIDEventRef (*FBRealtimeTouchIOHIDCreateDigitizerFingerEventWithQuality)(CFAllocatorRef allocator,
                                                                                                   uint64_t timestamp,
                                                                                                   uint32_t index,
                                                                                                   uint32_t identity,
                                                                                                   FBRealtimeTouchIOHIDEventMask eventMask,
                                                                                                   FBRealtimeTouchIOHIDFloat x,
                                                                                                   FBRealtimeTouchIOHIDFloat y,
                                                                                                   FBRealtimeTouchIOHIDFloat z,
                                                                                                   FBRealtimeTouchIOHIDFloat tipPressure,
                                                                                                   FBRealtimeTouchIOHIDFloat twist,
                                                                                                   FBRealtimeTouchIOHIDFloat minorRadius,
                                                                                                   FBRealtimeTouchIOHIDFloat majorRadius,
                                                                                                   FBRealtimeTouchIOHIDFloat quality,
                                                                                                   FBRealtimeTouchIOHIDFloat density,
                                                                                                   FBRealtimeTouchIOHIDFloat irregularity,
                                                                                                   Boolean range,
                                                                                                   Boolean touch,
                                                                                                   FBRealtimeTouchIOHIDOptions options);

typedef FBRealtimeTouchIOHIDEventSystemClientRef (*FBRealtimeTouchIOHIDSystemClientCreate)(CFAllocatorRef allocator);
typedef void (*FBRealtimeTouchIOHIDSystemClientDispatchEvent)(FBRealtimeTouchIOHIDEventSystemClientRef client, FBRealtimeTouchIOHIDEventRef event);
typedef void (*FBRealtimeTouchIOHIDAppendEvent)(FBRealtimeTouchIOHIDEventRef parent,
                                                FBRealtimeTouchIOHIDEventRef child);
typedef void (*FBRealtimeTouchIOHIDSetIntegerValue)(FBRealtimeTouchIOHIDEventRef event, uint32_t field, CFIndex value);
typedef void (*FBRealtimeTouchIOHIDSetFloatValue)(FBRealtimeTouchIOHIDEventRef event, uint32_t field, FBRealtimeTouchIOHIDFloat value);
typedef void (*FBRealtimeTouchIOHIDSetSenderID)(FBRealtimeTouchIOHIDEventRef event, uint64_t senderID);
typedef CFTypeRef (*FBRealtimeTouchSecTaskCreateFromSelf)(CFAllocatorRef allocator);
typedef CFTypeRef (*FBRealtimeTouchSecTaskCopyValueForEntitlement)(CFTypeRef task, CFStringRef entitlement, CFErrorRef *error);

static NSString *const FBRealtimeTouchErrorDomain = @"com.facebook.WebDriverAgent.realtime-touch";
static void *FBRealtimeTouchQueueSpecificKey = &FBRealtimeTouchQueueSpecificKey;
static const uint32_t FBRealtimeTouchIOHIDEventRange = 0x00000001;
static const uint32_t FBRealtimeTouchIOHIDEventTouch = 0x00000002;
static const uint32_t FBRealtimeTouchIOHIDEventPosition = 0x00000004;
static const uint32_t FBRealtimeTouchIOHIDEventIdentity = 0x00000020;
static const uint32_t FBRealtimeTouchIOHIDFieldIsBuiltIn = 0x00000004;
static const uint32_t FBRealtimeTouchIOHIDFieldDigitizerMajorRadius = 0x000B0014;
static const uint32_t FBRealtimeTouchIOHIDFieldDigitizerMinorRadius = 0x000B0015;
static const uint32_t FBRealtimeTouchIOHIDFieldDigitizerIsDisplayIntegrated = 0x000B0019;

static NSError *FBRealtimeTouchMakeError(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain:FBRealtimeTouchErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"Unknown realtime touch error" }];
}

static BOOL FBRealtimeTouchIsFiniteCoordinate(double value)
{
  return isfinite(value) && value >= 0.0;
}

static BOOL FBRealtimeTouchDebugEnabled(void)
{
  static dispatch_once_t onceToken;
  static BOOL enabled = NO;
  dispatch_once(&onceToken, ^{
    NSString *value = NSProcessInfo.processInfo.environment[@"WDA_REALTIME_TOUCH_DEBUG"];
    NSString *normalized = value.lowercaseString;
    enabled = [normalized isEqualToString:@"1"] ||
      [normalized isEqualToString:@"true"] ||
      [normalized isEqualToString:@"yes"] ||
      [normalized isEqualToString:@"on"];
  });
  return enabled;
}

static double FBRealtimeTouchMachTicksPerMillisecond(void)
{
  static dispatch_once_t onceToken;
  static double ticksPerMs = 0.0;
  dispatch_once(&onceToken, ^{
    mach_timebase_info_data_t info = {0};
    if (mach_timebase_info(&info) == KERN_SUCCESS && info.numer > 0) {
      ticksPerMs = ((double)NSEC_PER_SEC / 1000.0 * (double)info.denom) / (double)info.numer;
    } else {
      ticksPerMs = 1.0;
    }
  });
  return ticksPerMs;
}

static double FBRealtimeTouchWallClockMs(void)
{
  return NSDate.date.timeIntervalSince1970 * 1000.0;
}

static void FBRealtimeTouchLog(NSString *stage, NSString *phase, NSDictionary<NSString *, id> *values)
{
  if (!FBRealtimeTouchDebugEnabled()) {
    return;
  }
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:8 + values.count];
  [parts addObject:@"[RT INPUT]"];
  if (stage.length > 0) {
    [parts addObject:[NSString stringWithFormat:@"stage=%@", stage]];
  }
  if (phase.length > 0) {
    [parts addObject:[NSString stringWithFormat:@"phase=%@", phase]];
  }
  [parts addObject:[NSString stringWithFormat:@"wallTs=%.3f", FBRealtimeTouchWallClockMs()]];
  [parts addObject:[NSString stringWithFormat:@"machTs=%llu", mach_absolute_time()]];
  for (NSString *key in values) {
    id value = values[key];
    [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value ?: @"-"]];
  }
  [FBLogger log:[parts componentsJoinedByString:@" "]];
}

static id FBRealtimeTouchCopyEntitlementValue(NSString *name)
{
  static void *securityHandle;
  static FBRealtimeTouchSecTaskCreateFromSelf createFromSelf;
  static FBRealtimeTouchSecTaskCopyValueForEntitlement copyEntitlement;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    securityHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    if (securityHandle != NULL) {
      createFromSelf = (FBRealtimeTouchSecTaskCreateFromSelf)dlsym(securityHandle, "SecTaskCreateFromSelf");
      copyEntitlement = (FBRealtimeTouchSecTaskCopyValueForEntitlement)dlsym(securityHandle, "SecTaskCopyValueForEntitlement");
    }
  });
  if (createFromSelf == NULL || copyEntitlement == NULL) {
    return nil;
  }

  CFTypeRef task = createFromSelf(kCFAllocatorDefault);
  if (task == NULL) {
    return nil;
  }
  CFTypeRef value = copyEntitlement(task, (__bridge CFStringRef)name, NULL);
  CFRelease(task);
  if (value == NULL || value == kCFNull) {
    return nil;
  }
  return CFBridgingRelease(value);
}

static BOOL FBRealtimeTouchEntitlementEnabled(NSString *name)
{
  id value = FBRealtimeTouchCopyEntitlementValue(name);
  if ([value isKindOfClass:NSNumber.class]) {
    return [value boolValue];
  }
  if ([value isKindOfClass:NSString.class]) {
    NSString *normalized = [value lowercaseString];
    return [normalized isEqualToString:@"1"]
      || [normalized isEqualToString:@"true"]
      || [normalized isEqualToString:@"yes"]
      || [normalized isEqualToString:@"on"];
  }
  return value != nil;
}

static NSArray<NSString *> *FBRealtimeTouchMissingSymbols(FBRealtimeTouchIOHIDCreateDigitizerEvent createParent,
                                                          FBRealtimeTouchIOHIDCreateDigitizerFingerEvent createFinger,
                                                          FBRealtimeTouchIOHIDSystemClientCreate createClient,
                                                          FBRealtimeTouchIOHIDSystemClientDispatchEvent dispatchEvent,
                                                          FBRealtimeTouchIOHIDAppendEvent appendEvent)
{
  NSMutableArray<NSString *> *missing = [NSMutableArray array];
  if (createParent == NULL) {
    [missing addObject:@"IOHIDEventCreateDigitizerEvent"];
  }
  if (createFinger == NULL) {
    [missing addObject:@"IOHIDEventCreateDigitizerFingerEvent"];
  }
  if (createClient == NULL) {
    [missing addObject:@"IOHIDEventSystemClientCreate"];
  }
  if (dispatchEvent == NULL) {
    [missing addObject:@"IOHIDEventSystemClientDispatchEvent"];
  }
  if (appendEvent == NULL) {
    [missing addObject:@"IOHIDEventAppendEvent"];
  }
  return missing.copy;
}

static CGSize FBRealtimeTouchScreenSizeForApplication(XCUIApplication *app)
{
  NSString *useXCTestScreen = NSProcessInfo.processInfo.environment[@"WDA_REALTIME_TOUCH_USE_XCTEST_SCREEN"];
  BOOL shouldUseXCTestScreen = [useXCTestScreen isEqualToString:@"1"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"true"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"yes"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"on"];
  if (shouldUseXCTestScreen && nil != app) {
    @try {
      CGSize appSize = FBPointArrayScreenSizeForApplication(app);
      if (appSize.width > 0.0 && appSize.height > 0.0) {
        return appSize;
      }
    } @catch (NSException *exception) {
      [FBLogger logFmt:@"Realtime touch falling back to UIScreen size after XCTest screen lookup failed: %@",
                       exception.reason ?: exception.name];
    }
  }

  CGSize screenSize = UIScreen.mainScreen.bounds.size;
  if ((screenSize.width <= 0.0 || screenSize.height <= 0.0) && UIScreen.mainScreen.scale > 0.0) {
    CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
    screenSize = CGSizeMake(nativeSize.width / UIScreen.mainScreen.scale,
                            nativeSize.height / UIScreen.mainScreen.scale);
  }
  return screenSize;
}

static XCUIApplication *FBRealtimeTouchApplicationForScreenSizing(void)
{
  NSString *useXCTestScreen = NSProcessInfo.processInfo.environment[@"WDA_REALTIME_TOUCH_USE_XCTEST_SCREEN"];
  BOOL shouldUseXCTestScreen = [useXCTestScreen isEqualToString:@"1"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"true"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"yes"] ||
    [useXCTestScreen.lowercaseString isEqualToString:@"on"];
  if (!shouldUseXCTestScreen) {
    return nil;
  }
  @try {
    return XCUIApplication.fb_activeApplication;
  } @catch (NSException *exception) {
    [FBLogger logFmt:@"Realtime touch active application lookup failed: %@",
                     exception.reason ?: exception.name];
    return nil;
  }
}

static BOOL FBRealtimeTouchNormalizePoint(XCUIApplication *app,
                                          CGFloat x,
                                          CGFloat y,
                                          double *normalizedX,
                                          double *normalizedY,
                                          CGSize *screenSize,
                                          NSError **error)
{
  if (!FBRealtimeTouchIsFiniteCoordinate(x) || !FBRealtimeTouchIsFiniteCoordinate(y)) {
    if (error) {
      *error = FBRealtimeTouchMakeError(1, @"Touch coordinates must be finite, non-negative numbers");
    }
    return NO;
  }

  CGSize currentScreenSize = FBRealtimeTouchScreenSizeForApplication(app);
  if (currentScreenSize.width <= 0.0 || currentScreenSize.height <= 0.0) {
    if (error) {
      *error = FBRealtimeTouchMakeError(2, @"Cannot determine the screen size for realtime touch");
    }
    return NO;
  }
  if (screenSize) {
    *screenSize = currentScreenSize;
  }

  CGFloat clampedX = MIN(MAX(0.0, x), currentScreenSize.width);
  CGFloat clampedY = MIN(MAX(0.0, y), currentScreenSize.height);
  if (normalizedX) {
    *normalizedX = clampedX / currentScreenSize.width;
  }
  if (normalizedY) {
    *normalizedY = clampedY / currentScreenSize.height;
  }
  return YES;
}

@interface FBRealtimeTouchInjector : NSObject

+ (instancetype)sharedInjector;

- (BOOL)touchDownAtX:(CGFloat)x
                   y:(CGFloat)y
           pointerId:(NSUInteger)pointerId
            sequence:(nullable NSNumber *)sequence
     clientTimestamp:(nullable NSNumber *)clientTimestamp
               error:(NSError **)error;

- (BOOL)touchMoveAtX:(CGFloat)x
                   y:(CGFloat)y
           pointerId:(NSUInteger)pointerId
            sequence:(nullable NSNumber *)sequence
     clientTimestamp:(nullable NSNumber *)clientTimestamp
               error:(NSError **)error;

- (BOOL)touchUpAtX:(CGFloat)x
                 y:(CGFloat)y
         pointerId:(NSUInteger)pointerId
          sequence:(nullable NSNumber *)sequence
   clientTimestamp:(nullable NSNumber *)clientTimestamp
             error:(NSError **)error;

- (void)cancelActiveTouch;

- (NSDictionary<NSString *, id> *)statusWithDispatchProbe:(BOOL)dispatchProbe
                                                        x:(CGFloat)x
                                                        y:(CGFloat)y;

@property (nonatomic, readonly, copy) NSString *backendName;
@property (nonatomic, readonly, copy) NSString *backendDetail;
@property (nonatomic, readonly, assign, getter=isTrulyRealtime) BOOL trulyRealtime;
@property (nonatomic, readonly, assign, getter=isTouchActive) BOOL touchActive;

@end

@interface FBRealtimeTouchInjector ()
@property (nonatomic, strong) dispatch_queue_t hidQueue;
@property (nonatomic, assign) void *ioKitHandle;
@property (nonatomic, strong) id ioHIDClient;
@property (nonatomic, assign) FBRealtimeTouchIOHIDCreateDigitizerEvent ioCreateParent;
@property (nonatomic, assign) FBRealtimeTouchIOHIDCreateDigitizerFingerEvent ioCreateFinger;
@property (nonatomic, assign) FBRealtimeTouchIOHIDCreateDigitizerFingerEventWithQuality ioCreateFingerWithQuality;
@property (nonatomic, assign) FBRealtimeTouchIOHIDSystemClientCreate ioCreateClient;
@property (nonatomic, assign) FBRealtimeTouchIOHIDSystemClientDispatchEvent ioDispatch;
@property (nonatomic, assign) FBRealtimeTouchIOHIDAppendEvent ioAppend;
@property (nonatomic, assign) FBRealtimeTouchIOHIDSetIntegerValue ioSetInteger;
@property (nonatomic, assign) FBRealtimeTouchIOHIDSetFloatValue ioSetFloat;
@property (nonatomic, assign) FBRealtimeTouchIOHIDSetSenderID ioSetSenderID;
@property (nonatomic, copy) NSArray<NSString *> *missingSymbols;
@property (nonatomic, copy) NSString *backendName;
@property (nonatomic, copy) NSString *backendDetail;
@property (nonatomic, assign, getter=isTrulyRealtime) BOOL trulyRealtime;
@property (nonatomic, assign, getter=isTouchActive) BOOL touchActive;
@property (nonatomic, assign) NSUInteger activePointerId;
@property (nonatomic, assign) uint64_t lastSequence;
@property (nonatomic, assign) CGFloat lastX;
@property (nonatomic, assign) CGFloat lastY;
@property (nonatomic, assign) BOOL moveDrainScheduled;
@property (nonatomic, assign) BOOL hasPendingMove;
@property (nonatomic, assign) NSUInteger pendingPointerId;
@property (nonatomic, assign) uint64_t pendingSequence;
@property (nonatomic, assign) CGFloat pendingX;
@property (nonatomic, assign) CGFloat pendingY;
@property (nonatomic, strong) NSNumber *pendingClientTimestamp;
@property (nonatomic, assign) NSUInteger pendingMoveCount;
@property (nonatomic, assign) BOOL hasClientTimestampBase;
@property (nonatomic, assign) double clientTimestampBaseMs;
@property (nonatomic, assign) uint64_t hidTimestampBase;
@property (nonatomic, assign) uint64_t lastHIDTimestamp;
@property (nonatomic, assign) double lastHIDDispatchWallTimestampMs;
@property (nonatomic, assign) uint64_t pendingHIDEnqueueTimestamp;
@property (nonatomic, assign) BOOL ioKitLoaded;
@property (nonatomic, assign) BOOL symbolsResolved;
@property (nonatomic, assign) BOOL clientCreated;
@end

@implementation FBRealtimeTouchInjector

+ (instancetype)sharedInjector
{
  static FBRealtimeTouchInjector *injector;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    injector = [[self alloc] initPrivate];
  });
  return injector;
}

- (instancetype)init
{
  return [FBRealtimeTouchInjector sharedInjector];
}

- (instancetype)initPrivate
{
  self = [super init];
  if (self) {
    _hidQueue = dispatch_queue_create("com.idbbagent.hid", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_hidQueue, FBRealtimeTouchQueueSpecificKey, FBRealtimeTouchQueueSpecificKey, NULL);
    _backendName = @"iohid";
    _backendDetail = @"IOHID digitizer event injector";
    [self loadIOHIDBackendLocked];
  }
  return self;
}

- (void)dealloc
{
  if (_ioHIDClient != NULL) {
    _ioHIDClient = nil;
  }
  if (_ioKitHandle != NULL) {
    dlclose(_ioKitHandle);
    _ioKitHandle = NULL;
  }
}

- (void)performSynchronouslyOnHIDQueue:(dispatch_block_t)block
{
  if (dispatch_get_specific(FBRealtimeTouchQueueSpecificKey) != NULL) {
    block();
    return;
  }
  dispatch_sync(self.hidQueue, block);
}

- (void)resetClientTimestampBase
{
  self.hasClientTimestampBase = NO;
  self.clientTimestampBaseMs = 0.0;
  self.hidTimestampBase = 0;
}

- (uint64_t)hidTimestampForPhase:(NSString *)phase clientTimestamp:(nullable NSNumber *)clientTimestamp
{
  uint64_t now = mach_absolute_time();
  double clientMs = clientTimestamp != nil ? clientTimestamp.doubleValue : NAN;
  if (!isfinite(clientMs)) {
    self.lastHIDTimestamp = now;
    return now;
  }

  if (![phase isEqualToString:@"move"] && !self.hasClientTimestampBase) {
    self.hasClientTimestampBase = YES;
    self.clientTimestampBaseMs = clientMs;
    self.hidTimestampBase = now;
    self.lastHIDTimestamp = now;
    return now;
  }

  if (!self.hasClientTimestampBase) {
    self.hasClientTimestampBase = YES;
    self.clientTimestampBaseMs = clientMs;
    self.hidTimestampBase = now;
  }

  double deltaMs = clientMs - self.clientTimestampBaseMs;
  if (!isfinite(deltaMs) || deltaMs < 0.0) {
    deltaMs = 0.0;
  }
  double mapped = (double)self.hidTimestampBase + (deltaMs * FBRealtimeTouchMachTicksPerMillisecond());
  uint64_t resolved = (uint64_t)llround(mapped);
  if (resolved <= self.lastHIDTimestamp) {
    resolved = self.lastHIDTimestamp + 1;
  }
  self.lastHIDTimestamp = resolved;
  return resolved;
}

- (BOOL)loadIOHIDBackendLocked
{
  self.ioKitLoaded = NO;
  self.symbolsResolved = NO;
  self.clientCreated = NO;
  self.trulyRealtime = NO;
  self.missingSymbols = @[];

  if (self.ioKitHandle != NULL) {
    dlclose(self.ioKitHandle);
    self.ioKitHandle = NULL;
  }
  if (self.ioHIDClient != nil) {
    self.ioHIDClient = nil;
  }

  NSArray<NSString *> *paths = @[
    @"/System/Library/Frameworks/IOKit.framework/IOKit",
    @"/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
  ];
  NSString *lastError = nil;
  for (NSString *path in paths) {
    self.ioKitHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (self.ioKitHandle != NULL) {
      self.ioKitLoaded = YES;
      break;
    }
    const char *error = dlerror();
    if (error != NULL) {
      lastError = [NSString stringWithFormat:@"%s", error];
    }
  }

  if (!self.ioKitLoaded) {
    self.backendDetail = [NSString stringWithFormat:@"IOKit unavailable%@", lastError.length > 0 ? [NSString stringWithFormat:@" (%@)", lastError] : @""];
    self.missingSymbols = @[
      @"IOHIDEventCreateDigitizerEvent",
      @"IOHIDEventCreateDigitizerFingerEvent",
      @"IOHIDEventSystemClientCreate",
      @"IOHIDEventSystemClientDispatchEvent",
      @"IOHIDEventAppendEvent",
    ];
    return NO;
  }

#define FBRT_DLSYM(target, symbol) target = (typeof(target))dlsym(self.ioKitHandle, symbol)
  FBRT_DLSYM(self.ioCreateParent, "IOHIDEventCreateDigitizerEvent");
  FBRT_DLSYM(self.ioCreateFinger, "IOHIDEventCreateDigitizerFingerEvent");
  FBRT_DLSYM(self.ioCreateFingerWithQuality, "IOHIDEventCreateDigitizerFingerEventWithQuality");
  FBRT_DLSYM(self.ioCreateClient, "IOHIDEventSystemClientCreate");
  FBRT_DLSYM(self.ioDispatch, "IOHIDEventSystemClientDispatchEvent");
  FBRT_DLSYM(self.ioAppend, "IOHIDEventAppendEvent");
  FBRT_DLSYM(self.ioSetInteger, "IOHIDEventSetIntegerValue");
  FBRT_DLSYM(self.ioSetFloat, "IOHIDEventSetFloatValue");
  FBRT_DLSYM(self.ioSetSenderID, "IOHIDEventSetSenderID");
#undef FBRT_DLSYM

  self.missingSymbols = FBRealtimeTouchMissingSymbols(self.ioCreateParent,
                                                      self.ioCreateFinger,
                                                      self.ioCreateClient,
                                                      self.ioDispatch,
                                                      self.ioAppend);
  self.symbolsResolved = (self.missingSymbols.count == 0);
  if (!self.symbolsResolved) {
    self.backendDetail = [NSString stringWithFormat:@"IOHID symbols missing: %@", [self.missingSymbols componentsJoinedByString:@", "]];
    return NO;
  }

  self.ioHIDClient = CFBridgingRelease(self.ioCreateClient(kCFAllocatorDefault));
  self.clientCreated = (self.ioHIDClient != nil);
  if (!self.clientCreated) {
    self.backendDetail = @"IOHIDEventSystemClientCreate returned nil";
    return NO;
  }

  self.backendDetail = @"IOHID persistent client ready";
  self.trulyRealtime = YES;
  [FBLogger log:@"Realtime touch injector ready: IOHID persistent client"];
  return YES;
}

- (BOOL)ensureIOHIDClientLocked:(NSError **)error
{
  if (self.ioKitHandle == NULL || !self.symbolsResolved || self.ioHIDClient == nil) {
    if (![self loadIOHIDBackendLocked]) {
      if (error) {
        *error = FBRealtimeTouchMakeError(10, self.backendDetail ?: @"IOHID realtime touch is unavailable");
      }
      return NO;
    }
  }
  return YES;
}

- (BOOL)dispatchIOHIDPhaseLocked:(NSString *)phase
                               x:(CGFloat)x
                               y:(CGFloat)y
                       pointerId:(NSUInteger)pointerId
                        sequence:(uint64_t)sequence
                      timestamp:(uint64_t)timestamp
               clientTimestamp:(nullable NSNumber *)clientTimestamp
                          error:(NSError **)error
{
  @try {
  XCUIApplication *app = FBRealtimeTouchApplicationForScreenSizing();

  double normalizedX = 0.0;
  double normalizedY = 0.0;
  CGSize screenSize = CGSizeZero;
  if (!FBRealtimeTouchNormalizePoint(app, x, y, &normalizedX, &normalizedY, &screenSize, error)) {
    return NO;
  }
  double clampedX = MIN(MAX(0.0, x), screenSize.width);
  double clampedY = MIN(MAX(0.0, y), screenSize.height);
  double eventX = normalizedX;
  double eventY = normalizedY;
  NSString *coordinateMode = NSProcessInfo.processInfo.environment[@"WDA_IOHID_COORD_MODE"];
  if (coordinateMode.length == 0) {
    coordinateMode = NSProcessInfo.processInfo.environment[@"WDA_IOHID_COORDINATE_MODE"];
  }
  NSString *normalizedCoordinateMode = coordinateMode.lowercaseString;
  if ([normalizedCoordinateMode isEqualToString:@"points"] || [normalizedCoordinateMode isEqualToString:@"point"]) {
    eventX = clampedX;
    eventY = clampedY;
  } else if ([normalizedCoordinateMode isEqualToString:@"pixels"] || [normalizedCoordinateMode isEqualToString:@"pixel"]) {
    CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 1.0;
    eventX = clampedX * scale;
    eventY = clampedY * scale;
  }

  if (![self ensureIOHIDClientLocked:error]) {
    return NO;
  }

  BOOL isMove = [phase isEqualToString:@"move"];
  BOOL isUp = [phase isEqualToString:@"up"] || [phase isEqualToString:@"cancel"];
  const uint32_t eventRange = FBRealtimeTouchIOHIDEventRange;
  const uint32_t eventTouch = FBRealtimeTouchIOHIDEventTouch;
  const uint32_t eventPosition = FBRealtimeTouchIOHIDEventPosition;
  const uint32_t eventIdentity = FBRealtimeTouchIOHIDEventIdentity;
  uint32_t parentEventMask = eventRange | eventTouch | eventIdentity;
  if (isMove) {
    parentEventMask = eventPosition;
  } else if (isUp) {
    parentEventMask |= eventPosition;
  }
  uint32_t childEventMask = isMove ? eventPosition : (eventRange | eventTouch);
  uint32_t handType = 0x23;
  NSString *configuredHandType = NSProcessInfo.processInfo.environment[@"WDA_IOHID_HAND_TYPE"];
  if (configuredHandType.length > 0) {
    handType = (uint32_t)strtoul(configuredHandType.UTF8String, NULL, 0);
  }
  uint32_t index = 1U << 22;
  NSString *configuredParentIndex = NSProcessInfo.processInfo.environment[@"WDA_IOHID_PARENT_INDEX"];
  if (configuredParentIndex.length > 0) {
    index = (uint32_t)strtoul(configuredParentIndex.UTF8String, NULL, 0);
  }
  uint32_t identity = 1;
  NSString *configuredParentIdentity = NSProcessInfo.processInfo.environment[@"WDA_IOHID_PARENT_IDENTITY"];
  if (configuredParentIdentity.length > 0) {
    identity = (uint32_t)strtoul(configuredParentIdentity.UTF8String, NULL, 0);
  }
  uint32_t fingerIndex = (uint32_t)MAX((NSUInteger)3, pointerId);
  NSString *configuredFingerIndex = NSProcessInfo.processInfo.environment[@"WDA_IOHID_FINGER_INDEX"];
  if (configuredFingerIndex.length > 0) {
    fingerIndex = (uint32_t)strtoul(configuredFingerIndex.UTF8String, NULL, 0);
  }
  uint32_t fingerIdentity = 2;
  NSString *configuredFingerIdentity = NSProcessInfo.processInfo.environment[@"WDA_IOHID_FINGER_IDENTITY"];
  if (configuredFingerIdentity.length > 0) {
    fingerIdentity = (uint32_t)strtoul(configuredFingerIdentity.UTF8String, NULL, 0);
  }
  Boolean touching = isUp ? false : true;
  Boolean inRange = touching;
  FBRealtimeTouchIOHIDFloat majorRadius = 5.0;
  FBRealtimeTouchIOHIDFloat minorRadius = 5.0;
  FBRealtimeTouchIOHIDFloat quality = 1.0;
  FBRealtimeTouchIOHIDFloat density = 1.0;
  FBRealtimeTouchIOHIDFloat irregularity = 1.0;
  BOOL useFingerQuality = NO;
  NSString *configuredUseFingerQuality = NSProcessInfo.processInfo.environment[@"WDA_IOHID_USE_FINGER_QUALITY"];
  if (configuredUseFingerQuality.length > 0) {
    NSString *normalizedUseFingerQuality = configuredUseFingerQuality.lowercaseString;
    useFingerQuality = [normalizedUseFingerQuality isEqualToString:@"1"]
      || [normalizedUseFingerQuality isEqualToString:@"true"]
      || [normalizedUseFingerQuality isEqualToString:@"yes"]
      || [normalizedUseFingerQuality isEqualToString:@"on"];
  }
  NSString *configuredMajorRadius = NSProcessInfo.processInfo.environment[@"WDA_IOHID_MAJOR_RADIUS"];
  if (configuredMajorRadius.length > 0) {
    majorRadius = (FBRealtimeTouchIOHIDFloat)strtod(configuredMajorRadius.UTF8String, NULL);
  }
  NSString *configuredMinorRadius = NSProcessInfo.processInfo.environment[@"WDA_IOHID_MINOR_RADIUS"];
  if (configuredMinorRadius.length > 0) {
    minorRadius = (FBRealtimeTouchIOHIDFloat)strtod(configuredMinorRadius.UTF8String, NULL);
  }
  NSString *configuredQuality = NSProcessInfo.processInfo.environment[@"WDA_IOHID_QUALITY"];
  if (configuredQuality.length > 0) {
    quality = (FBRealtimeTouchIOHIDFloat)strtod(configuredQuality.UTF8String, NULL);
  }
  NSString *configuredDensity = NSProcessInfo.processInfo.environment[@"WDA_IOHID_DENSITY"];
  if (configuredDensity.length > 0) {
    density = (FBRealtimeTouchIOHIDFloat)strtod(configuredDensity.UTF8String, NULL);
  }
  NSString *configuredIrregularity = NSProcessInfo.processInfo.environment[@"WDA_IOHID_IRREGULARITY"];
  if (configuredIrregularity.length > 0) {
    irregularity = (FBRealtimeTouchIOHIDFloat)strtod(configuredIrregularity.UTF8String, NULL);
  }

  FBRealtimeTouchIOHIDEventRef parent = self.ioCreateParent(kCFAllocatorDefault,
                                                            timestamp,
                                                            handType,
                                                            index,
                                                            identity,
                                                            parentEventMask,
                                                            0,
                                                            eventX,
                                                            eventY,
                                                            0.0,
                                                            0.0,
                                                            0.0,
                                                            false,
                                                            touching,
                                                            0);
  FBRealtimeTouchIOHIDEventRef child = NULL;
  if (useFingerQuality && self.ioCreateFingerWithQuality != NULL) {
    child = self.ioCreateFingerWithQuality(kCFAllocatorDefault,
                                           timestamp,
                                           fingerIndex,
                                           fingerIdentity,
                                           childEventMask,
                                           eventX,
                                           eventY,
                                           0.0,
                                           0.0,
                                           0.0,
                                           minorRadius,
                                           majorRadius,
                                           quality,
                                           density,
                                           irregularity,
                                           inRange,
                                           touching,
                                           0);
  } else {
    child = self.ioCreateFinger(kCFAllocatorDefault,
                                timestamp,
                                fingerIndex,
                                fingerIdentity,
                                childEventMask,
                                eventX,
                                eventY,
                                0.0,
                                0.0,
                                0.0,
                                inRange,
                                touching,
                                0);
  }
  if (parent == NULL || child == NULL) {
    if (parent != NULL) {
      CFRelease(parent);
    }
    if (child != NULL) {
      CFRelease(child);
    }
    if (error) {
      *error = FBRealtimeTouchMakeError(12, @"IOHID could not create a digitizer event");
    }
    return NO;
  }

  if (self.ioSetInteger != NULL) {
    self.ioSetInteger(parent, FBRealtimeTouchIOHIDFieldIsBuiltIn, 1);
    self.ioSetInteger(parent, FBRealtimeTouchIOHIDFieldDigitizerIsDisplayIntegrated, 1);
    self.ioSetInteger(child, FBRealtimeTouchIOHIDFieldDigitizerIsDisplayIntegrated, 1);
  }
  if (self.ioSetFloat != NULL && (!useFingerQuality || self.ioCreateFingerWithQuality == NULL)) {
    self.ioSetFloat(child, FBRealtimeTouchIOHIDFieldDigitizerMajorRadius, majorRadius);
    self.ioSetFloat(child, FBRealtimeTouchIOHIDFieldDigitizerMinorRadius, minorRadius);
  }
  NSString *configuredSenderID = NSProcessInfo.processInfo.environment[@"WDA_IOHID_SENDER_ID"];
  if (self.ioSetSenderID != NULL) {
    uint64_t senderID = 0x8000000817319375ULL;
    if (configuredSenderID.length > 0) {
      senderID = strtoull(configuredSenderID.UTF8String, NULL, 0);
    }
    self.ioSetSenderID(parent, senderID);
  }

  double hidDispatchWallTimestampMs = FBRealtimeTouchWallClockMs();
  double previousDispatchWallTimestampMs = self.lastHIDDispatchWallTimestampMs;
  double hidDispatchDeltaMs = previousDispatchWallTimestampMs > 0.0
    ? hidDispatchWallTimestampMs - previousDispatchWallTimestampMs
    : 0.0;
  self.lastHIDDispatchWallTimestampMs = hidDispatchWallTimestampMs;

  self.ioAppend(parent, child);
  self.ioDispatch((FBRealtimeTouchIOHIDEventSystemClientRef)(__bridge CFTypeRef)self.ioHIDClient, parent);
  FBRealtimeTouchLog(@"hid-dispatch", phase, @{
    @"seq": @(sequence),
    @"pointerId": @(pointerId),
    @"x": @((double)x),
    @"y": @((double)y),
    @"clientTs": clientTimestamp ?: @"-",
    @"hidDispatchTs": @(hidDispatchWallTimestampMs),
    @"hidDispatchDeltaMs": @(hidDispatchDeltaMs),
    @"hidEventMachTs": @(timestamp),
    @"pendingMoveCount": @(self.pendingMoveCount),
  });
  CFRelease(child);
  CFRelease(parent);
  return YES;
  } @catch (NSException *exception) {
    if (error) {
      *error = FBRealtimeTouchMakeError(13, [NSString stringWithFormat:@"Realtime touch failed: %@", exception.reason ?: exception.name]);
    }
    [FBLogger logFmt:@"Realtime touch exception on phase %@: %@", phase ?: @"?", exception.reason ?: exception.name];
    return NO;
  }
}

- (BOOL)touchDownAtX:(CGFloat)x
                   y:(CGFloat)y
           pointerId:(NSUInteger)pointerId
            sequence:(NSNumber *)sequence
     clientTimestamp:(nullable NSNumber *)clientTimestamp
               error:(NSError **)error
{
  __block BOOL success = NO;
  __block NSError *dispatchError = nil;
  [self performSynchronouslyOnHIDQueue:^{
    if (self.touchActive) {
      [self cancelActiveTouchLocked];
    }
    self.hasPendingMove = NO;
    self.moveDrainScheduled = NO;
    self.pendingMoveCount = 0;
    self.pendingClientTimestamp = nil;
    self.pendingHIDEnqueueTimestamp = 0;
    [self resetClientTimestampBase];
    uint64_t hidEnqueueTimestamp = mach_absolute_time();
    uint64_t hidTimestamp = [self hidTimestampForPhase:@"down" clientTimestamp:clientTimestamp];
    FBRealtimeTouchLog(@"hid-enqueue", @"down", @{
      @"seq": sequence ?: @(0),
      @"pointerId": @(MAX((NSUInteger)1, pointerId)),
      @"x": @(x),
      @"y": @(y),
      @"clientTs": clientTimestamp ?: @"-",
      @"hidEnqueueTs": @(hidEnqueueTimestamp),
      @"pendingMoveCount": @(self.pendingMoveCount),
    });
    success = [self dispatchIOHIDPhaseLocked:@"down"
                                           x:x
                                           y:y
                                   pointerId:pointerId
                                     sequence:sequence != nil ? sequence.unsignedLongLongValue : 0
                                    timestamp:hidTimestamp
                             clientTimestamp:clientTimestamp
                                        error:&dispatchError];
    if (success) {
      self.touchActive = YES;
      self.activePointerId = MAX((NSUInteger)1, pointerId);
      self.lastSequence = sequence.unsignedLongLongValue;
      self.lastX = x;
      self.lastY = y;
    }
  }];
  if (!success && error != NULL) {
    *error = dispatchError;
  }
  return success;
}

- (BOOL)touchMoveAtX:(CGFloat)x
                   y:(CGFloat)y
           pointerId:(NSUInteger)pointerId
            sequence:(NSNumber *)sequence
     clientTimestamp:(nullable NSNumber *)clientTimestamp
               error:(NSError **)error
{
  if (!FBRealtimeTouchIsFiniteCoordinate(x) || !FBRealtimeTouchIsFiniteCoordinate(y)) {
    if (error) {
      *error = FBRealtimeTouchMakeError(1, @"Touch coordinates must be finite, non-negative numbers");
    }
    return NO;
  }

  __block BOOL accepted = YES;
  BOOL shouldScheduleDrain = NO;
  @synchronized (self) {
    if (!self.touchActive) {
      self.hasPendingMove = NO;
      self.moveDrainScheduled = NO;
      self.pendingMoveCount = 0;
      self.pendingClientTimestamp = nil;
      self.pendingHIDEnqueueTimestamp = 0;
      accepted = YES;
      return accepted;
    }
    uint64_t sequenceValue = sequence != nil ? sequence.unsignedLongLongValue : self.lastSequence + 1;
    if (sequence != nil && sequenceValue < self.lastSequence) {
      accepted = YES;
      return accepted;
    }
    self.pendingPointerId = pointerId == 0 ? self.activePointerId : MAX((NSUInteger)1, pointerId);
    if (self.pendingPointerId == 0) {
      self.pendingPointerId = 1;
    }
    self.pendingSequence = sequenceValue;
    self.pendingX = x;
    self.pendingY = y;
    self.hasPendingMove = YES;
    self.pendingClientTimestamp = clientTimestamp;
    self.pendingHIDEnqueueTimestamp = mach_absolute_time();
    self.pendingMoveCount = self.pendingMoveCount + 1;
    if (!self.moveDrainScheduled) {
      self.moveDrainScheduled = YES;
      shouldScheduleDrain = YES;
    }
  }

  if (FBRealtimeTouchDebugEnabled()) {
    FBRealtimeTouchLog(@"hid-enqueue", @"move", @{
      @"seq": @(sequence != nil ? sequence.unsignedLongLongValue : self.pendingSequence),
      @"pointerId": @(self.pendingPointerId),
      @"x": @(x),
      @"y": @(y),
      @"clientTs": clientTimestamp ?: @"-",
      @"hidEnqueueTs": @(self.pendingHIDEnqueueTimestamp),
      @"pendingMoveCount": @(self.pendingMoveCount),
    });
  }

  if (shouldScheduleDrain) {
    dispatch_async(self.hidQueue, ^{
      [self drainPendingMoveLocked];
    });
  }
  return accepted;
}

- (BOOL)touchUpAtX:(CGFloat)x
                 y:(CGFloat)y
         pointerId:(NSUInteger)pointerId
          sequence:(NSNumber *)sequence
   clientTimestamp:(nullable NSNumber *)clientTimestamp
             error:(NSError **)error
{
  __block BOOL success = YES;
  __block NSError *dispatchError = nil;
  [self performSynchronouslyOnHIDQueue:^{
    if (!self.touchActive) {
      self.hasPendingMove = NO;
      self.moveDrainScheduled = NO;
      self.pendingMoveCount = 0;
      self.pendingClientTimestamp = nil;
      self.pendingHIDEnqueueTimestamp = 0;
      success = YES;
      return;
    }
    NSUInteger resolvedPointerId = pointerId == 0 ? self.activePointerId : MAX((NSUInteger)1, pointerId);
    BOOL hasFinalPendingMove = NO;
    NSUInteger finalMovePointerId = 0;
    CGFloat finalMoveX = 0;
    CGFloat finalMoveY = 0;
    uint64_t finalMoveSequence = 0;
    NSNumber *finalMoveClientTimestamp = nil;
    NSUInteger finalMoveCount = 0;
    uint64_t finalMoveEnqueueTimestamp = 0;
    @synchronized (self) {
      if (self.hasPendingMove) {
        hasFinalPendingMove = YES;
        finalMovePointerId = self.pendingPointerId == 0 ? self.activePointerId : self.pendingPointerId;
        finalMoveX = self.pendingX;
        finalMoveY = self.pendingY;
        finalMoveSequence = self.pendingSequence;
        finalMoveClientTimestamp = self.pendingClientTimestamp;
        finalMoveCount = self.pendingMoveCount;
        finalMoveEnqueueTimestamp = self.pendingHIDEnqueueTimestamp;
        self.hasPendingMove = NO;
        self.pendingMoveCount = 0;
        self.pendingClientTimestamp = nil;
        self.pendingHIDEnqueueTimestamp = 0;
      }
    }
    if (hasFinalPendingMove) {
      uint64_t finalMoveHIDTimestamp = [self hidTimestampForPhase:@"move" clientTimestamp:finalMoveClientTimestamp];
      FBRealtimeTouchLog(@"hid-dispatch-ready", @"move", @{
        @"seq": @(finalMoveSequence),
        @"pointerId": @(finalMovePointerId),
        @"x": @(finalMoveX),
        @"y": @(finalMoveY),
        @"clientTs": finalMoveClientTimestamp ?: @"-",
        @"hidEnqueueTs": @(finalMoveEnqueueTimestamp),
        @"queueDepth": @(finalMoveCount),
        @"barrier": @"up",
      });
      success = [self dispatchIOHIDPhaseLocked:@"move"
                                             x:finalMoveX
                                             y:finalMoveY
                                     pointerId:finalMovePointerId
                                       sequence:finalMoveSequence
                                      timestamp:finalMoveHIDTimestamp
                               clientTimestamp:finalMoveClientTimestamp
                                          error:&dispatchError];
      if (!success) {
        return;
      }
      self.activePointerId = finalMovePointerId;
      self.lastSequence = finalMoveSequence;
      self.lastX = finalMoveX;
      self.lastY = finalMoveY;
    }
    uint64_t hidEnqueueTimestamp = mach_absolute_time();
    uint64_t hidTimestamp = [self hidTimestampForPhase:@"up" clientTimestamp:clientTimestamp];
    FBRealtimeTouchLog(@"hid-enqueue", @"up", @{
      @"seq": sequence ?: @(0),
      @"pointerId": @(resolvedPointerId),
      @"x": @(x),
      @"y": @(y),
      @"clientTs": clientTimestamp ?: @"-",
      @"hidEnqueueTs": @(hidEnqueueTimestamp),
      @"pendingMoveCount": @(self.pendingMoveCount),
    });
    self.hasPendingMove = NO;
    self.moveDrainScheduled = NO;
    self.pendingMoveCount = 0;
    self.pendingHIDEnqueueTimestamp = 0;
    success = [self dispatchIOHIDPhaseLocked:@"up"
                                           x:x
                                           y:y
                                   pointerId:resolvedPointerId
                                     sequence:sequence != nil ? sequence.unsignedLongLongValue : 0
                                    timestamp:hidTimestamp
                             clientTimestamp:clientTimestamp
                                        error:&dispatchError];
    self.touchActive = NO;
    self.activePointerId = 0;
    self.lastSequence = sequence != nil ? sequence.unsignedLongLongValue : self.lastSequence;
    self.lastX = x;
    self.lastY = y;
    [self resetClientTimestampBase];
  }];
  if (!success && error != NULL) {
    *error = dispatchError;
  }
  return success;
}

- (void)cancelActiveTouch
{
  [self performSynchronouslyOnHIDQueue:^{
    [self cancelActiveTouchLocked];
  }];
}

- (void)cancelActiveTouchLocked
{
  if (!self.touchActive) {
    self.hasPendingMove = NO;
    self.moveDrainScheduled = NO;
    self.pendingMoveCount = 0;
    self.pendingClientTimestamp = nil;
    self.pendingHIDEnqueueTimestamp = 0;
    return;
  }
  self.hasPendingMove = NO;
  self.moveDrainScheduled = NO;
  self.pendingMoveCount = 0;
  self.pendingHIDEnqueueTimestamp = 0;
  [self resetClientTimestampBase];
  NSError *ignoredError = nil;
  [self dispatchIOHIDPhaseLocked:@"cancel"
                               x:self.lastX
                               y:self.lastY
                       pointerId:self.activePointerId
                         sequence:self.lastSequence
                        timestamp:mach_absolute_time()
                 clientTimestamp:self.pendingClientTimestamp
                            error:&ignoredError];
  self.touchActive = NO;
  self.activePointerId = 0;
}

- (void)drainPendingMoveLocked
{
  while (YES) {
    NSUInteger pointerId = 0;
    CGFloat x = 0;
    CGFloat y = 0;
    uint64_t sequence = 0;
    NSNumber *clientTimestamp = nil;
    NSUInteger batchMoveCount = 0;
    uint64_t batchEnqueueTimestamp = 0;
    @synchronized (self) {
      if (!self.touchActive || !self.hasPendingMove) {
        self.moveDrainScheduled = NO;
        return;
      }
      pointerId = self.pendingPointerId == 0 ? self.activePointerId : self.pendingPointerId;
      x = self.pendingX;
      y = self.pendingY;
      sequence = self.pendingSequence;
      clientTimestamp = self.pendingClientTimestamp;
      batchMoveCount = self.pendingMoveCount;
      batchEnqueueTimestamp = self.pendingHIDEnqueueTimestamp;
      self.hasPendingMove = NO;
      self.pendingMoveCount = 0;
      self.pendingClientTimestamp = nil;
      self.pendingHIDEnqueueTimestamp = 0;
    }

    NSError *error = nil;
    uint64_t hidTimestamp = [self hidTimestampForPhase:@"move" clientTimestamp:clientTimestamp];
    FBRealtimeTouchLog(@"hid-dispatch-ready", @"move", @{
      @"seq": @(sequence),
      @"pointerId": @(pointerId),
      @"x": @(x),
      @"y": @(y),
      @"clientTs": clientTimestamp ?: @"-",
      @"hidEnqueueTs": @(batchEnqueueTimestamp),
      @"queueDepth": @(batchMoveCount),
    });
    if (![self dispatchIOHIDPhaseLocked:@"move"
                                      x:x
                                      y:y
                              pointerId:pointerId
                                sequence:sequence
                               timestamp:hidTimestamp
                        clientTimestamp:clientTimestamp
                                   error:&error]) {
      if (error != nil) {
        [FBLogger logFmt:@"Realtime touch move failed: %@", error.localizedDescription];
      }
      break;
    }

    @synchronized (self) {
      self.activePointerId = pointerId;
      self.lastSequence = sequence;
      self.lastX = x;
      self.lastY = y;
    }
  }

  @synchronized (self) {
    self.moveDrainScheduled = NO;
    if (self.touchActive && self.hasPendingMove) {
      self.moveDrainScheduled = YES;
      dispatch_async(self.hidQueue, ^{
        [self drainPendingMoveLocked];
      });
    }
  }
}

- (NSDictionary<NSString *, id> *)statusWithDispatchProbe:(BOOL)dispatchProbe
                                                        x:(CGFloat)x
                                                        y:(CGFloat)y
{
  __block NSDictionary<NSString *, id> *status = nil;
  [self performSynchronouslyOnHIDQueue:^{
    XCUIApplication *app = FBRealtimeTouchApplicationForScreenSizing();
    CGSize screenSize = FBRealtimeTouchScreenSizeForApplication(app);
    BOOL dispatchAttempted = NO;
    BOOL dispatchSucceeded = NO;
    if (dispatchProbe && !self.touchActive) {
      dispatchAttempted = YES;
      NSError *probeError = nil;
      dispatchSucceeded = [self dispatchIOHIDPhaseLocked:@"down"
                                                     x:x
                                                     y:y
                                             pointerId:1
                                               sequence:0
                                              timestamp:mach_absolute_time()
                                       clientTimestamp:nil
                                                  error:&probeError];
      if (dispatchSucceeded) {
        NSError *releaseError = nil;
        dispatchSucceeded = [self dispatchIOHIDPhaseLocked:@"up"
                                                       x:x
                                                       y:y
                                               pointerId:1
                                                 sequence:1
                                                timestamp:mach_absolute_time()
                                         clientTimestamp:nil
                                                    error:&releaseError];
        if (!dispatchSucceeded && probeError == nil) {
          probeError = releaseError;
        }
      }
      if (!dispatchSucceeded && probeError != nil) {
        self.backendDetail = probeError.localizedDescription ?: self.backendDetail;
      }
    }

    status = @{
      @"backend": self.backendName ?: @"iohid",
      @"backendDetail": self.backendDetail ?: @"",
      @"trulyRealtime": @(self.trulyRealtime),
      @"ioKitLoaded": @(self.ioKitLoaded),
      @"symbolsResolved": @(self.symbolsResolved),
      @"missingSymbols": self.missingSymbols ?: @[],
      @"clientCreated": @(self.clientCreated),
      @"touchActive": @(self.touchActive),
      @"activePointerId": @(self.activePointerId),
      @"lastSequence": @(self.lastSequence),
      @"lastPoint": @[@(self.lastX), @(self.lastY)],
      @"pendingMoveCount": @(self.pendingMoveCount),
      @"screenWidth": @(screenSize.width),
      @"screenHeight": @(screenSize.height),
      @"bundleId": NSBundle.mainBundle.bundleIdentifier ?: @"",
      @"build": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"",
      @"dispatchAttempted": @(dispatchAttempted),
      @"dispatchSucceeded": @(dispatchSucceeded),
      @"entitlements": @{
        @"com.apple.hid.manager.user-access-device": @(FBRealtimeTouchEntitlementEnabled(@"com.apple.hid.manager.user-access-device")),
        @"com.apple.private.hid.client.event-dispatch": @(FBRealtimeTouchEntitlementEnabled(@"com.apple.private.hid.client.event-dispatch")),
        @"com.apple.security.exception.iokit-user-client-class": FBRealtimeTouchCopyEntitlementValue(@"com.apple.security.exception.iokit-user-client-class") ?: NSNull.null,
      },
    };
  }];
  return status ?: @{};
}

@end

#if TARGET_OS_TV
NSDictionary<NSString *, NSNumber *> *fb_availableButtonNames(void) {
  static dispatch_once_t onceToken;
  static NSDictionary *result;
  dispatch_once(&onceToken, ^{
    NSMutableDictionary *buttons = [NSMutableDictionary dictionary];
    // https://developer.apple.com/design/human-interface-guidelines/remotes
    buttons[@"up"] = @(XCUIRemoteButtonUp);                     // 0
    buttons[@"down"] = @(XCUIRemoteButtonDown);                 // 1
    buttons[@"left"] = @(XCUIRemoteButtonLeft);                 // 2
    buttons[@"right"] = @(XCUIRemoteButtonRight);               // 3
    buttons[@"select"] = @(XCUIRemoteButtonSelect);             // 4
    buttons[@"menu"] = @(XCUIRemoteButtonMenu);                 // 5
    buttons[@"playpause"] = @(XCUIRemoteButtonPlayPause);       // 6
    buttons[@"home"] = @(XCUIRemoteButtonHome);                 // 7
#if __clang_major__ >= 15 // Xcode 15+
    buttons[@"pageup"] = @(XCUIRemoteButtonPageUp);             // 9
    buttons[@"pagedown"] = @(XCUIRemoteButtonPageDown);         // 10
    buttons[@"guide"] = @(XCUIRemoteButtonGuide);               // 11
#endif
#if __clang_major__ >= 17 // likely Xcode 16.3+
    if (@available(tvOS 18.1, *)) {
      buttons[@"fourcolors"] = @(XCUIRemoteButtonFourColors);   // 12
      buttons[@"onetwothree"] = @(XCUIRemoteButtonOneTwoThree); // 13
      buttons[@"tvprovider"] = @(XCUIRemoteButtonTVProvider);   // 14
    }
#endif
    result = [buttons copy];
  });
  return result;
}
#else
NSDictionary<NSString *, NSNumber *> *fb_availableButtonNames(void) {
  static dispatch_once_t onceToken;
  static NSDictionary *result;
  dispatch_once(&onceToken, ^{
    NSMutableDictionary *buttons = [NSMutableDictionary dictionary];
    buttons[@"home"] = @(XCUIDeviceButtonHome);             // 1
#if !TARGET_OS_SIMULATOR
    buttons[@"volumeup"] = @(XCUIDeviceButtonVolumeUp);     // 2
    buttons[@"volumedown"] = @(XCUIDeviceButtonVolumeDown); // 3
#endif
    if (@available(iOS 16.0, *)) {
#if __clang_major__ >= 15 // likely Xcode 15+
      if ([XCUIDevice.sharedDevice hasHardwareButton:XCUIDeviceButtonAction]) {
        buttons[@"action"] = @(XCUIDeviceButtonAction);     // 4
      }
#endif
#if (!TARGET_OS_SIMULATOR && __clang_major__ >= 16) // likely Xcode 16+
      if ([XCUIDevice.sharedDevice hasHardwareButton:XCUIDeviceButtonCamera]) {
        buttons[@"camera"] = @(XCUIDeviceButtonCamera);
      }
#endif
    }
    result = [buttons copy];
  });
  return result;
}
#endif

@implementation XCUIDevice (FBHelpers)

static bool fb_isLocked;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"

+ (void)load
{
  [self fb_registerAppforDetectLockState];
}

#pragma clang diagnostic pop

+ (void)fb_registerAppforDetectLockState
{
  int notify_token;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wstrict-prototypes"
  notify_register_dispatch("com.apple.springboard.lockstate", &notify_token, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(int token) {
    uint64_t state = UINT64_MAX;
    notify_get_state(token, &state);
    fb_isLocked = state != 0;
  });
#pragma clang diagnostic pop
}

- (BOOL)fb_goToHomescreenWithError:(NSError **)error
{
  return [XCUIApplication fb_switchToSystemApplicationWithError:error];
}

- (BOOL)fb_lockScreen:(NSError **)error
{
  if (fb_isLocked) {
    return YES;
  }
  [self pressLockButton];
  return [[[[FBRunLoopSpinner new]
            timeout:FBScreenLockTimeout]
           timeoutErrorMessage:@"Timed out while waiting until the screen gets locked"]
          spinUntilTrue:^BOOL{
            return fb_isLocked;
          } error:error];
}

- (BOOL)fb_isScreenLocked
{
  return fb_isLocked;
}

- (BOOL)fb_unlockScreen:(NSError **)error
{
  if (!fb_isLocked) {
    return YES;
  }
  [self pressButton:XCUIDeviceButtonHome];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBHomeButtonCoolOffTime]];
#if !TARGET_OS_TV
  [self pressButton:XCUIDeviceButtonHome];
#else
  [self pressButton:XCUIDeviceButtonHome];
#endif
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBHomeButtonCoolOffTime]];
  return [[[[FBRunLoopSpinner new]
            timeout:FBScreenLockTimeout]
           timeoutErrorMessage:@"Timed out while waiting until the screen gets unlocked"]
          spinUntilTrue:^BOOL{
            return !fb_isLocked;
          } error:error];
}

- (NSData *)fb_screenshotWithError:(NSError*__autoreleasing*)error
{
  return [FBScreenshot takeInOriginalResolutionWithQuality:FBConfiguration.screenshotQuality
                                                     error:error];
}

- (NSData *)fb_screenshotWithError:(NSError * _Nullable __autoreleasing *)error
                               rect:(CGRect)rect
                              scale:(NSNumber *)scale
                              error:(NSError * _Nullable __autoreleasing *)transformError
{
  NSData *rawScreenshot = [self fb_screenshotWithError:error];
  if (nil == rawScreenshot) {
    return nil;
  }
  UIImage *image = [UIImage imageWithData:rawScreenshot];
  if (nil == image) {
    [[[FBErrorBuilder builder]
      withDescription:@"Cannot decode screenshot data into UIImage"]
     buildError:transformError];
    return nil;
  }

  UIImage *processedImage = image;
  CGRect normalizedRect = CGRectStandardize(rect);
  if (!CGRectEqualToRect(normalizedRect, CGRectZero)) {
    CGRect sourceBounds = CGRectMake(0, 0, image.size.width, image.size.height);
    CGRect croppedRect = CGRectIntersection(sourceBounds, normalizedRect);
    if (CGRectIsEmpty(croppedRect)) {
      [[[FBErrorBuilder builder]
        withDescriptionFormat:@"Cannot crop screenshot with rect %@", NSStringFromCGRect(rect)]
       buildError:transformError];
      return nil;
    }
    CGRect pixelRect = CGRectMake(croppedRect.origin.x * image.scale,
                                  croppedRect.origin.y * image.scale,
                                  croppedRect.size.width * image.scale,
                                  croppedRect.size.height * image.scale);
    CGImageRef croppedCgImage = CGImageCreateWithImageInRect(image.CGImage, pixelRect);
    if (nil == croppedCgImage) {
      [[[FBErrorBuilder builder]
        withDescription:@"Cannot create cropped screenshot image"]
       buildError:transformError];
      return nil;
    }
    processedImage = [UIImage imageWithCGImage:croppedCgImage
                                         scale:image.scale
                                   orientation:image.imageOrientation];
    CGImageRelease(croppedCgImage);
  }

  CGFloat requestedScale = scale ? (CGFloat)scale.doubleValue : 1.0;
  if (requestedScale > 0.0 && requestedScale < 1.0) {
    CGSize scaledSize = CGSizeMake(MAX(1.0, floor(processedImage.size.width * requestedScale)),
                                   MAX(1.0, floor(processedImage.size.height * requestedScale)));
    UIGraphicsBeginImageContextWithOptions(scaledSize, NO, processedImage.scale);
    [processedImage drawInRect:(CGRect){CGPointZero, scaledSize}];
    UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (nil == scaledImage) {
      [[[FBErrorBuilder builder]
        withDescription:@"Cannot resize screenshot image"]
       buildError:transformError];
      return nil;
    }
    processedImage = scaledImage;
  }

  NSData *resultData = UIImagePNGRepresentation(processedImage);
  if (nil == resultData) {
    [[[FBErrorBuilder builder]
      withDescription:@"Cannot encode screenshot image as PNG"]
     buildError:transformError];
    return nil;
  }
  return resultData;
}

- (BOOL)fb_fingerTouchShouldMatch:(BOOL)shouldMatch
{
  const char *name;
  if (shouldMatch) {
    name = "com.apple.BiometricKit_Sim.fingerTouch.match";
  } else {
    name = "com.apple.BiometricKit_Sim.fingerTouch.nomatch";
  }
  return notify_post(name) == NOTIFY_STATUS_OK;
}

- (NSString *)fb_wifiIPAddress
{
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = getifaddrs(&interfaces);
  if (success != 0) {
    freeifaddrs(interfaces);
    return nil;
  }

  NSString *address = nil;
  temp_addr = interfaces;
  while(temp_addr != NULL) {
    if(temp_addr->ifa_addr->sa_family != AF_INET) {
      temp_addr = temp_addr->ifa_next;
      continue;
    }
    NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
    if(![interfaceName isEqualToString:@"en0"]) {
      temp_addr = temp_addr->ifa_next;
      continue;
    }
    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
    break;
  }
  freeifaddrs(interfaces);
  return address;
}

- (NSString *)fb_acturalWifiIPAddress
{
  return [self fb_wifiIPAddress];
}

- (BOOL)fb_openUrl:(NSString *)url error:(NSError **)error
{
  NSURL *parsedUrl = [NSURL URLWithString:url];
  if (nil == parsedUrl) {
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"'%@' is not a valid URL", url]
            buildError:error];
  }

  NSError *err;
  if ([FBXCTestDaemonsProxy openDefaultApplicationForURL:parsedUrl error:&err]) {
    return YES;
  }
  if (![err.description containsString:@"does not support"]) {
    if (error) {
      *error = err;
    }
    return NO;
  }

  id siriService = [self valueForKey:@"siriService"];
  if (nil != siriService) {
    return [self fb_activateSiriVoiceRecognitionWithText:[NSString stringWithFormat:@"Open {%@}", url] error:error];
  }

  NSString *description = [NSString stringWithFormat:@"Cannot open '%@' with the default application assigned for it. Consider upgrading to Xcode 14.3+/iOS 16.4+", url];
  return [[[FBErrorBuilder builder]
           withDescriptionFormat:@"%@", description]
          buildError:error];
}

- (BOOL)fb_openUrl:(NSString *)url withApplication:(NSString *)bundleId error:(NSError **)error
{
  NSURL *parsedUrl = [NSURL URLWithString:url];
  if (nil == parsedUrl) {
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"'%@' is not a valid URL", url]
            buildError:error];
  }

  return [FBXCTestDaemonsProxy openURL:parsedUrl usingApplication:bundleId error:error];
}

- (BOOL)fb_activateSiriVoiceRecognitionWithText:(NSString *)text error:(NSError **)error
{
  id siriService = [self valueForKey:@"siriService"];
  if (nil == siriService) {
    return [[[FBErrorBuilder builder]
             withDescription:@"Siri service is not available on the device under test"]
            buildError:error];
  }
  SEL selector = NSSelectorFromString(@"activateWithVoiceRecognitionText:");
  NSMethodSignature *signature = [siriService methodSignatureForSelector:selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
  [invocation setSelector:selector];
  [invocation setArgument:&text atIndex:2];
  @try {
    [invocation invokeWithTarget:siriService];
    return YES;
  } @catch (NSException *e) {
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"%@", e.reason]
            buildError:error];
  }
}

- (BOOL)fb_hasButton:(NSString *)buttonName
{
  return fb_availableButtonNames()[buttonName.lowercaseString] != nil;
}

- (BOOL)fb_pressButton:(NSString *)buttonName
           forDuration:(nullable NSNumber *)duration
                 error:(NSError **)error
{
#if !TARGET_OS_TV
  return [self fb_pressButton:buttonName error:error];
#else

  NSDictionary<NSString *, NSNumber *> *availableButtons = fb_availableButtonNames();
  NSNumber *buttonValue = availableButtons[buttonName.lowercaseString];
  
  if (!buttonValue) {
    NSArray *sortedKeys = [availableButtons.allKeys sortedArrayUsingSelector:@selector(compare:)];
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"The button '%@' is not supported. The device under test only supports the following buttons: %@", buttonName, sortedKeys]
            buildError:error];
  }
  if (duration) {
    // https://developer.apple.com/documentation/xcuiautomation/xcuiremote/press(_:forduration:)
    [[XCUIRemote sharedRemote] pressButton:(XCUIRemoteButton)[buttonValue unsignedIntegerValue] forDuration:duration.doubleValue];
  } else {
    // https://developer.apple.com/documentation/xcuiautomation/xcuiremote/press(_:)
    [[XCUIRemote sharedRemote] pressButton:(XCUIRemoteButton)[buttonValue unsignedIntegerValue]];
  }
  return YES;
#endif
}

#if !TARGET_OS_TV
- (BOOL)fb_pressButton:(NSString *)buttonName
                 error:(NSError **)error
{
  NSDictionary<NSString *, NSNumber *> *availableButtons = fb_availableButtonNames();
  NSNumber *buttonValue = availableButtons[buttonName.lowercaseString];
  
  if (!buttonValue) {
    NSArray *sortedKeys = [availableButtons.allKeys sortedArrayUsingSelector:@selector(compare:)];
    return [[[FBErrorBuilder builder]
             withDescriptionFormat:@"The button '%@' is not supported. The device under test only supports the following buttons: %@", buttonName, sortedKeys]
            buildError:error];
  }
  [self pressButton:(XCUIDeviceButton)[buttonValue unsignedIntegerValue]];
  return YES;
}
#endif

- (BOOL)fb_performIOHIDEventWithPage:(unsigned int)page
                               usage:(unsigned int)usage
                            duration:(NSTimeInterval)duration
                               error:(NSError **)error
{
  id<FBXCDeviceEvent> event = FBCreateXCDeviceEvent(page, usage, duration, error);
  return nil == event ? NO : [self performDeviceEvent:event error:error];
}

- (BOOL)fb_setAppearance:(FBUIInterfaceAppearance)appearance error:(NSError **)error
{
  SEL selector = NSSelectorFromString(@"setAppearanceMode:");
  if (nil != selector && [self respondsToSelector:selector]) {
    NSMethodSignature *signature = [self methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:selector];
    [invocation setTarget:self];
    [invocation setArgument:&appearance atIndex:2];
    [invocation invoke];
    return YES;
  }

#if __clang_major__ >= 15 || (__clang_major__ >= 14 && __clang_minor__ >= 0 && __clang_patchlevel__ >= 3)
  // Xcode 14.3.1 can build these values.
  // For iOS 17+
  if ([self respondsToSelector:NSSelectorFromString(@"appearance")]) {
    self.appearance = (XCUIDeviceAppearance) appearance;
    return YES;
  }
#endif

  return [[[FBErrorBuilder builder]
           withDescriptionFormat:@"Current Xcode SDK does not support appearance changing"]
          buildError:error];
}

- (NSNumber *)fb_getAppearance
{
#if __clang_major__ >= 15 || (__clang_major__ >= 14 && __clang_minor__ >= 0 && __clang_patchlevel__ >= 3)
  // Xcode 14.3.1 can build these values.
  // For iOS 17+
  if ([self respondsToSelector:NSSelectorFromString(@"appearance")]) {
    return [NSNumber numberWithLongLong:[self appearance]];
  }
#endif

  return [self respondsToSelector:@selector(appearanceMode)]
  ? [NSNumber numberWithLongLong:[self appearanceMode]]
  : nil;
}

- (BOOL)fb_synthTapWithX:(CGFloat)x
                       y:(CGFloat)y
                duration:(nullable NSNumber *)duration
{
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  if (nil == app) {
    return NO;
  }
  @try {
    XCUICoordinate *start = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    XCUICoordinate *target = [start coordinateWithOffset:CGVectorMake(x, y)];
    if (nil != duration && duration.doubleValue > 0) {
      [target pressForDuration:duration.doubleValue];
    } else {
      [target tap];
    }
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

- (BOOL)fb_synthSwipe:(CGFloat)fromX
                fromY:(CGFloat)fromY
                  toX:(CGFloat)toX
                  toY:(CGFloat)toY
                delay:(nullable NSNumber *)delay
{
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  if (nil == app) {
    return NO;
  }
  @try {
    NSTimeInterval duration = MAX(0.01, nil == delay ? 0.03 : delay.doubleValue);
    return [self fb_qx9:@[
      @[@(fromX), @(fromY), @0],
      @[@(toX), @(toY), @(duration)],
    ]];
  } @catch (__unused NSException *e) {
    return NO;
  }
}

- (BOOL)fb_qx9:(NSArray *)pointArray
{
  if (pointArray.count < 2) {
    return NO;
  }
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  if (nil == app) {
    return NO;
  }
  @try {
    NSMutableArray<NSDictionary<NSString *, id> *> *normalizedPoints = [NSMutableArray arrayWithCapacity:pointArray.count];
    BOOL hasTimestamp = NO;
    for (id rawPoint in pointArray) {
      CGFloat x = 0.0;
      CGFloat y = 0.0;
      NSNumber *timestamp = nil;
      if (!FBExtractCoordinatePoint(rawPoint, &x, &y, &timestamp)) {
        return NO;
      }
      if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0) {
        return NO;
      }
      if (nil != timestamp && (!isfinite(timestamp.doubleValue) || timestamp.doubleValue < 0)) {
        return NO;
      }
      if (nil != timestamp) {
        hasTimestamp = YES;
      }
      [normalizedPoints addObject:@{
        @"x": @(x),
        @"y": @(y),
        @"t": timestamp ?: NSNull.null,
      }];
    }
    if (normalizedPoints.count < 2) {
      return NO;
    }

    if (hasTimestamp) {
      normalizedPoints = [FBThrottlePointArrayForInjection(normalizedPoints) mutableCopy];
      XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc]
                                               initWithName:@"Event"
                                               interfaceOrientation:app.interfaceOrientation];
      FBPointArrayScreenTransform transform = FBPointArrayScreenTransformMakeForApplication(app);
      CGPoint firstPoint = FBPointArrayScreenPoint(transform,
                                                   [normalizedPoints.firstObject[@"x"] doubleValue],
                                                   [normalizedPoints.firstObject[@"y"] doubleValue]);
      XCPointerEventPath *eventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:firstPoint offset:0];
      NSTimeInterval previousOffset = 0.0;
      for (NSUInteger idx = 1; idx < normalizedPoints.count; idx++) {
        NSDictionary<NSString *, id> *point = normalizedPoints[idx];
        NSNumber *rawTimestamp = [point[@"t"] isKindOfClass:NSNumber.class] ? point[@"t"] : nil;
        NSTimeInterval offset = previousOffset + 0.01;
        if (nil != rawTimestamp) {
          NSTimeInterval parsedTimestamp = rawTimestamp.doubleValue;
          if (parsedTimestamp > 10.0) {
            // Accept either seconds (0.105) or milliseconds (105).
            parsedTimestamp = parsedTimestamp / 1000.0;
          }
          offset = MAX(offset, parsedTimestamp);
        }
        [eventPath moveToPoint:FBPointArrayScreenPoint(transform,
                                                       [point[@"x"] doubleValue],
                                                       [point[@"y"] doubleValue])
                      atOffset:offset];
        previousOffset = offset;
      }
      [eventPath liftUpAtOffset:(previousOffset + 0.01)];
      [eventRecord addPointerEventPath:eventPath];
      NSError *error;
      return [FBXCTestDaemonsProxy synthesizeEventWithRecord:eventRecord error:&error];
    }

    XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    for (NSUInteger idx = 0; idx + 1 < normalizedPoints.count; idx++) {
      NSDictionary<NSString *, id> *fromPoint = normalizedPoints[idx];
      NSDictionary<NSString *, id> *toPoint = normalizedPoints[idx + 1];
      XCUICoordinate *start = [origin coordinateWithOffset:CGVectorMake([fromPoint[@"x"] doubleValue],
                                                                         [fromPoint[@"y"] doubleValue])];
      XCUICoordinate *end = [origin coordinateWithOffset:CGVectorMake([toPoint[@"x"] doubleValue],
                                                                       [toPoint[@"y"] doubleValue])];
      [start pressForDuration:0.01 thenDragToCoordinate:end];
    }
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

- (BOOL)fb_realtimeTouchDownAtX:(CGFloat)x
                              y:(CGFloat)y
                      pointerId:(NSUInteger)pointerId
                        sequence:(NSNumber *)sequence
                 clientTimestamp:(NSNumber *)clientTimestamp
                           error:(NSError **)error
{
  return [FBRealtimeTouchInjector.sharedInjector touchDownAtX:x
                                                            y:y
                                                    pointerId:pointerId
                                                     sequence:sequence
                                              clientTimestamp:clientTimestamp
                                                        error:error];
}

- (BOOL)fb_realtimeTouchMoveAtX:(CGFloat)x
                              y:(CGFloat)y
                      pointerId:(NSUInteger)pointerId
                        sequence:(NSNumber *)sequence
                 clientTimestamp:(NSNumber *)clientTimestamp
                           error:(NSError **)error
{
  return [FBRealtimeTouchInjector.sharedInjector touchMoveAtX:x
                                                            y:y
                                                    pointerId:pointerId
                                                     sequence:sequence
                                              clientTimestamp:clientTimestamp
                                                        error:error];
}

- (BOOL)fb_realtimeTouchUpAtX:(CGFloat)x
                            y:(CGFloat)y
                    pointerId:(NSUInteger)pointerId
                      sequence:(NSNumber *)sequence
               clientTimestamp:(NSNumber *)clientTimestamp
                         error:(NSError **)error
{
  return [FBRealtimeTouchInjector.sharedInjector touchUpAtX:x
                                                          y:y
                                                  pointerId:pointerId
                                                   sequence:sequence
                                            clientTimestamp:clientTimestamp
                                                      error:error];
}

- (void)fb_realtimeTouchCancel
{
  [FBRealtimeTouchInjector.sharedInjector cancelActiveTouch];
}

- (NSDictionary<NSString *, id> *)fb_realtimeHIDStatusWithDispatchProbe:(BOOL)dispatchProbe
                                                                      x:(CGFloat)x
                                                                      y:(CGFloat)y
{
  return [FBRealtimeTouchInjector.sharedInjector statusWithDispatchProbe:dispatchProbe x:x y:y];
}

#if !TARGET_OS_TV
- (BOOL)fb_setSimulatedLocation:(CLLocation *)location error:(NSError **)error
{
  return [FBXCTestDaemonsProxy setSimulatedLocation:location error:error];
}

- (nullable CLLocation *)fb_getSimulatedLocation:(NSError **)error
{
  return [FBXCTestDaemonsProxy getSimulatedLocation:error];
}

- (BOOL)fb_clearSimulatedLocation:(NSError **)error
{
  return [FBXCTestDaemonsProxy clearSimulatedLocation:error];
}
#endif

@end
