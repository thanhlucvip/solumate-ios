/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIDevice+FBHelpers.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#import <math.h>
#import <UIKit/UIKit.h>
#include <notify.h>
#import <objc/runtime.h>

#import "FBErrorBuilder.h"
#import "FBImageUtils.h"
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
          buildError:error];;
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
