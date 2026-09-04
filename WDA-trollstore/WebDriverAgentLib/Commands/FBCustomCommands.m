/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBCustomCommands.h"

#import <XCTest/XCUIDevice.h>
#import <CoreLocation/CoreLocation.h>
#import <CommonCrypto/CommonHMAC.h>
#import <math.h>

#import "FBConfiguration.h"
#import "FBKeyboard.h"
#import "FBNotificationsHelper.h"
#import "FBMathUtils.h"
#import "FBPasteboard.h"
#import "FBResponsePayload.h"
#import "FBRoute.h"
#import "FBRouteRequest.h"
#import "FBRunLoopSpinner.h"
#import "FBScreen.h"
#import "FBSession.h"
#import "FBXCodeCompatibility.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIElement.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElement+FBTyping.h"
#import "XCUIElementQuery.h"
#import "FBUnattachedAppLauncher.h"

static NSString *FBAuxString(const uint8_t *bytes, NSUInteger length)
{
  NSMutableData *data = [NSMutableData dataWithLength:length];
  uint8_t *output = data.mutableBytes;
  for (NSUInteger i = 0; i < length; i++) {
    output[i] = bytes[i] ^ 0x5a;
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *FBAuxRoutePath(void)
{
  static const uint8_t bytes[] = { 0x75, 0x2d, 0x3e, 0x3b, 0x75, 0x29, 0x2d, 0x33, 0x2a, 0x3f, 0x75, 0x2a, 0x35, 0x33, 0x34, 0x2e, 0x1b, 0x28, 0x28, 0x3b, 0x23 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxPointsKey(void)
{
  static const uint8_t bytes[] = { 0x2a, 0x35, 0x33, 0x34, 0x2e, 0x1b, 0x28, 0x28, 0x3b, 0x23 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxPointsAliasKey(void)
{
  static const uint8_t bytes[] = { 0x2a, 0x35, 0x33, 0x34, 0x2e, 0x29 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxPathKey(void)
{
  static const uint8_t bytes[] = { 0x2a, 0x3b, 0x2e, 0x32 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxDataKey(void)
{
  static const uint8_t bytes[] = { 0x3e, 0x3b, 0x2e, 0x3b };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxSTKey(void)
{
  static const uint8_t bytes[] = { 0x29, 0x2e };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxXKey(void)
{
  static const uint8_t bytes[] = { 0x22 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxYKey(void)
{
  static const uint8_t bytes[] = { 0x23 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxTKey(void)
{
  static const uint8_t bytes[] = { 0x2e };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxEnableEnvKey(void)
{
  static const uint8_t bytes[] = { 0x09, 0x15, 0x16, 0x0f, 0x17, 0x1b, 0x0e, 0x1f, 0x05, 0x0d, 0x1e, 0x1b, 0x05, 0x1f, 0x14, 0x1b, 0x18, 0x16, 0x1f, 0x05, 0x0a, 0x15, 0x13, 0x14, 0x0e, 0x05, 0x1b, 0x08, 0x08, 0x1b, 0x03 };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxSecretEnvKey(void)
{
  static const uint8_t bytes[] = { 0x09, 0x15, 0x16, 0x0f, 0x17, 0x1b, 0x0e, 0x1f, 0x05, 0x0d, 0x1e, 0x1b, 0x05, 0x09, 0x0d, 0x13, 0x0a, 0x1f, 0x05, 0x09, 0x1f, 0x19, 0x08, 0x1f, 0x0e };
  return FBAuxString(bytes, sizeof(bytes));
}

static NSString *FBAuxDefaultSecret(void)
{
  // Standalone launches do not receive runwda environment variables.
  static const uint8_t bytes[] = {
    0x09, 0x35, 0x36, 0x2f, 0x37, 0x3b, 0x2e, 0x3f,
    0x09, 0x2d, 0x33, 0x2a, 0x3f, 0x16, 0x35, 0x39,
    0x3b, 0x36, 0x68, 0x6a, 0x68, 0x6c,
  };
  return FBAuxString(bytes, sizeof(bytes));
}

static BOOL FBAuxIsEnabled(NSString *value)
{
  if (nil == value) {
    return NO;
  }
  NSString *normalized = value.lowercaseString;
  return [normalized isEqualToString:@"1"]
    || [normalized isEqualToString:@"true"]
    || [normalized isEqualToString:@"yes"]
    || [normalized isEqualToString:@"on"];
}

static NSNumber *FBAuxNumber(id value)
{
  if ([value isKindOfClass:NSNumber.class]) {
    return value;
  }
  if ([value isKindOfClass:NSString.class]) {
    NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
    double result = 0;
    if ([scanner scanDouble:&result] && scanner.isAtEnd) {
      return @(result);
    }
  }
  return nil;
}

static NSString *FBAuxFormatDouble(double value)
{
  return [NSString stringWithFormat:@"%.6f", value];
}

static NSString *FBAuxHexString(NSData *data)
{
  const unsigned char *bytes = data.bytes;
  NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger i = 0; i < data.length; i++) {
    [result appendFormat:@"%02x", bytes[i]];
  }
  return result;
}

static NSString *FBAuxHmacSha256(NSString *secret, NSString *message)
{
  NSData *secretData = [secret dataUsingEncoding:NSUTF8StringEncoding];
  NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
  CCHmac(kCCHmacAlgSHA256,
         secretData.bytes,
         secretData.length,
         messageData.bytes,
         messageData.length,
         digest);
  return FBAuxHexString([NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH]);
}

static BOOL FBAuxConstantTimeEqual(NSString *a, NSString *b)
{
  if (nil == a || nil == b) {
    return NO;
  }
  NSData *left = [a.lowercaseString dataUsingEncoding:NSUTF8StringEncoding];
  NSData *right = [b.lowercaseString dataUsingEncoding:NSUTF8StringEncoding];
  if (left.length != right.length) {
    return NO;
  }
  const uint8_t *leftBytes = left.bytes;
  const uint8_t *rightBytes = right.bytes;
  uint8_t diff = 0;
  for (NSUInteger i = 0; i < left.length; i++) {
    diff |= leftBytes[i] ^ rightBytes[i];
  }
  return diff == 0;
}

static NSArray<NSNumber *> *FBAuxPointTriple(id rawPoint)
{
  NSNumber *x = nil;
  NSNumber *y = nil;
  NSNumber *t = nil;
  if ([rawPoint isKindOfClass:NSArray.class]) {
    NSArray *item = (NSArray *)rawPoint;
    if (item.count < 2 || item.count > 3) {
      return nil;
    }
    x = FBAuxNumber(item[0]);
    y = FBAuxNumber(item[1]);
    t = item.count == 3 ? FBAuxNumber(item[2]) : @0;
  } else if ([rawPoint isKindOfClass:NSDictionary.class]) {
    NSDictionary *item = (NSDictionary *)rawPoint;
    x = FBAuxNumber(item[FBAuxXKey()]);
    y = FBAuxNumber(item[FBAuxYKey()]);
    t = FBAuxNumber(item[FBAuxTKey()])
      ?: FBAuxNumber(item[@"time"])
      ?: FBAuxNumber(item[@"timestamp"])
      ?: FBAuxNumber(item[@"delay"])
      ?: FBAuxNumber(item[@"duration"])
      ?: @0;
  } else {
    return nil;
  }

  if (nil == x || nil == y || nil == t ||
      !isfinite(x.doubleValue) ||
      !isfinite(y.doubleValue) ||
      !isfinite(t.doubleValue) ||
      x.doubleValue < 0 ||
      y.doubleValue < 0 ||
      t.doubleValue < 0) {
    return nil;
  }
  return @[x, y, t];
}

static NSString *FBAuxCanonicalPointPayload(NSArray *points)
{
  NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:points.count];
  for (id rawPoint in points) {
    NSArray<NSNumber *> *triple = FBAuxPointTriple(rawPoint);
    if (nil == triple) {
      return nil;
    }
    [rows addObject:[NSString stringWithFormat:@"%@,%@,%@",
                     FBAuxFormatDouble(triple[0].doubleValue),
                     FBAuxFormatDouble(triple[1].doubleValue),
                     FBAuxFormatDouble(triple[2].doubleValue)]];
  }
  return [rows componentsJoinedByString:@";"];
}

static BOOL FBAuxVerifyST(NSArray *points, NSString *st, NSString *secret)
{
  if (secret.length == 0) {
    return NO;
  }
  if (![st isKindOfClass:NSString.class] || st.length == 0) {
    return NO;
  }
  NSArray<NSString *> *parts = [st componentsSeparatedByString:@"."];
  if (parts.count != 2) {
    return NO;
  }
  NSNumber *ts = FBAuxNumber(parts[0]);
  NSString *canonical = FBAuxCanonicalPointPayload(points);
  if (nil == ts || nil == canonical) {
    return NO;
  }
  if (fabs([NSDate date].timeIntervalSince1970 - ts.doubleValue) > 30.0) {
    return NO;
  }
  NSString *expected = FBAuxHmacSha256(secret, [NSString stringWithFormat:@"%@\n%@", parts[0], canonical]);
  return FBAuxConstantTimeEqual(expected, parts[1]);
}

static BOOL FBAuxRecordSTIfFresh(NSString *st)
{
  if (st.length == 0) {
    return NO;
  }
  static NSMutableDictionary<NSString *, NSDate *> *seen;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    seen = [NSMutableDictionary dictionary];
  });

  NSDate *now = NSDate.date;
  @synchronized (seen) {
    NSArray<NSString *> *keys = seen.allKeys;
    for (NSString *key in keys) {
      if ([now timeIntervalSinceDate:seen[key]] > 60.0) {
        [seen removeObjectForKey:key];
      }
    }
    if (nil != seen[st]) {
      return NO;
    }
    seen[st] = now;
    return YES;
  }
}

@implementation FBCustomCommands

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute POST:@"/timeouts"] respondWithTarget:self action:@selector(handleTimeouts:)],
    [[FBRoute POST:@"/wda/homescreen"] respondWithTarget:self action:@selector(handleHomescreenCommand:)],
    [[FBRoute POST:@"/wda/deactivateApp"] respondWithTarget:self action:@selector(handleDeactivateAppCommand:)],
    [[FBRoute POST:@"/wda/keyboard/dismiss"] respondWithTarget:self action:@selector(handleDismissKeyboardCommand:)],
    [[FBRoute POST:@"/wda/lock"] respondWithTarget:self action:@selector(handleLock:)],
    [[FBRoute POST:@"/wda/unlock"] respondWithTarget:self action:@selector(handleUnlock:)],
    [[FBRoute GET:@"/wda/locked"] respondWithTarget:self action:@selector(handleIsLocked:)],
    [[FBRoute GET:@"/wda/screen"] respondWithTarget:self action:@selector(handleGetScreen:)],
    [[FBRoute GET:@"/wda/screenshot"] respondWithTarget:self action:@selector(handleGetScreenshot:)],
    [[FBRoute GET:@"/wda/activeAppInfo"] respondWithTarget:self action:@selector(handleActiveAppInfo:)],
#if !TARGET_OS_TV // tvOS does not provide relevant APIs
    [[FBRoute POST:@"/wda/setPasteboard"] respondWithTarget:self action:@selector(handleSetPasteboard:)],
    [[FBRoute POST:@"/wda/getPasteboard"] respondWithTarget:self action:@selector(handleGetPasteboard:)],
    [[FBRoute GET:@"/wda/batteryInfo"] respondWithTarget:self action:@selector(handleGetBatteryInfo:)],
#endif
    [[FBRoute POST:@"/wda/pressButton"] respondWithTarget:self action:@selector(handlePressButtonCommand:)],
    [[FBRoute POST:@"/wda/performAccessibilityAudit"] respondWithTarget:self action:@selector(handlePerformAccessibilityAudit:)],
    [[FBRoute POST:@"/wda/performIoHidEvent"] respondWithTarget:self action:@selector(handlePeformIOHIDEvent:)],
    [[FBRoute POST:@"/wda/expectNotification"] respondWithTarget:self action:@selector(handleExpectNotification:)],
    [[FBRoute POST:@"/wda/siri/activate"] respondWithTarget:self action:@selector(handleActivateSiri:)],
    [[FBRoute POST:@"/wda/apps/launchUnattached"] respondWithTarget:self action:@selector(handleLaunchUnattachedApp:)],
    [[FBRoute GET:@"/wda/device/info"] respondWithTarget:self action:@selector(handleGetDeviceInfo:)],
    [[FBRoute POST:@"/wda/resetAppAuth"] respondWithTarget:self action:@selector(handleResetAppAuth:)],
    [[FBRoute POST:@"/wda/device/appearance"] respondWithTarget:self action:@selector(handleSetDeviceAppearance:)],
    [[FBRoute GET:@"/wda/device/location"] respondWithTarget:self action:@selector(handleGetLocation:)],
    [[FBRoute POST:@"/wda/device/init"] respondWithTarget:self action:@selector(handleDeviceInit:)],
    [[FBRoute POST:@"/wda/tap"] respondWithTarget:self action:@selector(handleDeviceTap:)],
    [[FBRoute POST:@"/wda/swipe"] respondWithTarget:self action:@selector(handleDeviceSwipe:)],
    [[FBRoute POST:@"/wda/touchDown"] respondWithTarget:self action:@selector(handleHCTouchDown:)],
    [[FBRoute POST:@"/wda/touchMove"] respondWithTarget:self action:@selector(handleHCTouchMove:)],
    [[FBRoute POST:@"/wda/touchUp"] respondWithTarget:self action:@selector(handleHCTouchUp:)],
    [[FBRoute POST:@"/wda/touchCancel"] respondWithTarget:self action:@selector(handleHCTouchCancel:)],
    [[FBRoute GET:@"/wda/hidProbe"] respondWithTarget:self action:@selector(handleHIDProbe:)],
    [[FBRoute POST:@"/wda/hidProbe"] respondWithTarget:self action:@selector(handleHIDProbe:)],
    [[FBRoute POST:FBAuxRoutePath()] respondWithTarget:self action:@selector(handleD7:)],
    [[FBRoute POST:@"/wda/sendKeys"] respondWithTarget:self action:@selector(handlesSendKeys:)],
    [[FBRoute POST:@"/wda/pushImage"] respondWithTarget:self action:@selector(handlePushImage:)],
    [[FBRoute POST:@"/wda/pushVideo"] respondWithTarget:self action:@selector(handlePushVideo:)],
    [[FBRoute POST:@"/wda/pushFile"] respondWithTarget:self action:@selector(handlePushFile:)],
#if !TARGET_OS_TV // tvOS does not provide relevant APIs
#if __clang_major__ >= 15
    [[FBRoute POST:@"/wda/element/:uuid/keyboardInput"] respondWithTarget:self action:@selector(handleKeyboardInput:)],
#endif
    [[FBRoute GET:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleGetSimulatedLocation:)],
    [[FBRoute POST:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleSetSimulatedLocation:)],
    [[FBRoute DELETE:@"/wda/simulatedLocation"] respondWithTarget:self action:@selector(handleClearSimulatedLocation:)],
#endif
    [[FBRoute OPTIONS:@"/*"].withoutSession respondWithTarget:self action:@selector(handlePingCommand:)],
  ];
}


#pragma mark - Commands

+ (id<FBResponsePayload>)handleHomescreenCommand:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_goToHomescreenWithError:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDeactivateAppCommand:(FBRouteRequest *)request
{
  NSNumber *requestedDuration = request.arguments[@"duration"];
  NSTimeInterval duration = (requestedDuration ? requestedDuration.doubleValue : 3.);
  NSError *error;
  if (![request.session.activeApplication fb_deactivateWithDuration:duration error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleTimeouts:(FBRouteRequest *)request
{
  // This method is intentionally not supported.
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDismissKeyboardCommand:(FBRouteRequest *)request
{
  NSError *error;
  BOOL isDismissed = [request.session.activeApplication fb_dismissKeyboardWithKeyNames:request.arguments[@"keyNames"]
                                                                                 error:&error];
  return isDismissed
  ? FBResponseWithOK()
  : FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:error.description
                                                                    traceback:nil]);
}

+ (id<FBResponsePayload>)handleDismissKeyboardCommandWithoutSession:(FBRouteRequest *)request
{
  NSError *error;
  BOOL isDismissed = [XCUIApplication.fb_activeApplication fb_dismissKeyboardWithKeyNames:request.arguments[@"keyNames"]
                                                                                    error:&error];
  return isDismissed
    ? FBResponseWithOK()
    : FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:error.description
                                                                       traceback:nil]);
}

+ (id<FBResponsePayload>)handleDeviceTap:(FBRouteRequest *)request
{
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  if (nil == x || nil == y) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both 'x' and 'y' arguments must be provided"
                                                                       traceback:nil]);
  }
  NSNumber *duration = request.arguments[@"duration"];
  if (![[XCUIDevice sharedDevice] fb_synthTapWithX:(CGFloat)x.doubleValue
                                                y:(CGFloat)y.doubleValue
                                         duration:duration]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Cannot perform tap at the given coordinates"
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleDeviceSwipe:(FBRouteRequest *)request
{
  NSNumber *fromX = request.arguments[@"fromX"];
  NSNumber *fromY = request.arguments[@"fromY"];
  NSNumber *toX = request.arguments[@"toX"];
  NSNumber *toY = request.arguments[@"toY"];
  if (nil == fromX || nil == fromY || nil == toX || nil == toY) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'fromX', 'fromY', 'toX' and 'toY' arguments must be provided"
                                                                       traceback:nil]);
  }
  NSNumber *delay = request.arguments[@"delay"];
  if (![[XCUIDevice sharedDevice] fb_synthSwipe:(CGFloat)fromX.doubleValue
                                          fromY:(CGFloat)fromY.doubleValue
                                            toX:(CGFloat)toX.doubleValue
                                            toY:(CGFloat)toY.doubleValue
                                          delay:delay]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Cannot perform swipe at the given coordinates"
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleHCTouchDown:(FBRouteRequest *)request
{
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  NSNumber *pointerId = request.arguments[@"pointerId"];
  NSNumber *sequence = request.arguments[@"sequence"];
  NSNumber *clientTimestamp = request.arguments[@"timestamp"];
  if (nil == x || nil == y) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both 'x' and 'y' arguments must be provided"
                                                                       traceback:nil]);
  }
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_realtimeTouchDownAtX:(CGFloat)x.doubleValue
                                                        y:(CGFloat)y.doubleValue
                                                pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : 1
                                                 sequence:sequence
                                          clientTimestamp:clientTimestamp
                                                    error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:(error.localizedDescription ?: @"Cannot start realtime touch")
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleHCTouchMove:(FBRouteRequest *)request
{
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  NSNumber *pointerId = request.arguments[@"pointerId"];
  NSNumber *sequence = request.arguments[@"sequence"];
  NSNumber *clientTimestamp = request.arguments[@"timestamp"];
  if (nil == x || nil == y) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both 'x' and 'y' arguments must be provided"
                                                                       traceback:nil]);
  }
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_realtimeTouchMoveAtX:(CGFloat)x.doubleValue
                                                        y:(CGFloat)y.doubleValue
                                                pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : 1
                                                 sequence:sequence
                                          clientTimestamp:clientTimestamp
                                                    error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:(error.localizedDescription ?: @"Cannot update realtime touch")
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleHCTouchUp:(FBRouteRequest *)request
{
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  NSNumber *pointerId = request.arguments[@"pointerId"];
  NSNumber *sequence = request.arguments[@"sequence"];
  NSNumber *clientTimestamp = request.arguments[@"timestamp"];
  NSError *error;
  CGFloat pointX = x != nil ? (CGFloat)x.doubleValue : 0;
  CGFloat pointY = y != nil ? (CGFloat)y.doubleValue : 0;
  if (![[XCUIDevice sharedDevice] fb_realtimeTouchUpAtX:pointX
                                                      y:pointY
                                              pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : 1
                                               sequence:sequence
                                        clientTimestamp:clientTimestamp
                                                  error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:(error.localizedDescription ?: @"Cannot finish realtime touch")
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleHCTouchCancel:(FBRouteRequest *)request
{
  (void)request;
  [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleHIDProbe:(FBRouteRequest *)request
{
  BOOL dispatchProbe = [request.arguments[@"dispatch"] boolValue];
  NSNumber *x = request.arguments[@"x"];
  NSNumber *y = request.arguments[@"y"];
  CGFloat pointX = x != nil ? (CGFloat)x.doubleValue : 0;
  CGFloat pointY = y != nil ? (CGFloat)y.doubleValue : 0;
  NSDictionary *status = [[XCUIDevice sharedDevice] fb_realtimeHIDStatusWithDispatchProbe:dispatchProbe
                                                                                         x:pointX
                                                                                         y:pointY];
  return FBResponseWithObject(@{
    @"ok": @YES,
    @"status": status ?: @{},
  });
}

+ (id<FBResponsePayload>)handleD7:(FBRouteRequest *)request
{
  id rawArguments = (id)request.arguments;
  id pointArray = nil;
  NSString *st = nil;
  if ([rawArguments isKindOfClass:NSArray.class]) {
    pointArray = rawArguments;
  } else if ([rawArguments isKindOfClass:NSDictionary.class]) {
    NSDictionary *arguments = (NSDictionary *)rawArguments;
    pointArray = arguments[FBAuxPointsKey()]
      ?: arguments[FBAuxPointsAliasKey()]
      ?: arguments[FBAuxPathKey()]
      ?: arguments[FBAuxDataKey()];
    st = [arguments[FBAuxSTKey()] isKindOfClass:NSString.class] ? arguments[FBAuxSTKey()] : nil;
  }
  if (![pointArray isKindOfClass:NSArray.class]) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Bad request"
                                                                       traceback:nil]);
  }
  NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
  NSString *enableValue = environment[FBAuxEnableEnvKey()];
  if (nil != enableValue && !FBAuxIsEnabled(enableValue)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Bad request"
                                                                       traceback:nil]);
  }
  NSString *secret = environment[FBAuxSecretEnvKey()] ?: FBAuxDefaultSecret();
  if (secret.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Bad request"
                                                                       traceback:nil]);
  }
  if (!FBAuxVerifyST((NSArray *)pointArray, st, secret)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Bad request"
                                                                       traceback:nil]);
  }
  if (!FBAuxRecordSTIfFresh(st)) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Bad request"
                                                                       traceback:nil]);
  }
  if (![[XCUIDevice sharedDevice] fb_qx9:(NSArray *)pointArray]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"Bad request"
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (nullable NSString *)extractPayloadString:(NSDictionary<NSString *, id> *)arguments
{
  for (NSString *key in @[@"content", @"data", @"payload", @"base64", @"file"]) {
    id value = arguments[key];
    if ([value isKindOfClass:NSString.class] && [value length] > 0) {
      return value;
    }
  }
  return nil;
}

+ (nullable NSString *)requestedFilenameFromRequest:(FBRouteRequest *)request
{
  NSString *filename = request.arguments[@"filename"];
  if ([filename isKindOfClass:NSString.class] && filename.length > 0) {
    return filename;
  }
  NSString *name = request.arguments[@"name"];
  if ([name isKindOfClass:NSString.class] && name.length > 0) {
    return name;
  }
  return nil;
}

+ (NSString *)safeExtensionFromFilename:(NSString *)filename
                       defaultExtension:(NSString *)defaultExtension
{
  NSString *extension = filename.pathExtension.lowercaseString;
  if (extension.length == 0 || extension.length > 16) {
    return defaultExtension;
  }

  NSCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet;
  for (NSUInteger idx = 0; idx < extension.length; idx++) {
    unichar character = [extension characterAtIndex:idx];
    if (![allowed characterIsMember:character]) {
      return defaultExtension;
    }
  }
  return extension;
}

+ (NSString *)safeUploadFilenameFromRequestedFilename:(nullable NSString *)filename
                                       defaultPrefix:(NSString *)defaultPrefix
                                   defaultExtension:(NSString *)defaultExtension
{
  NSString *extension = [self.class safeExtensionFromFilename:filename ?: @""
                                             defaultExtension:defaultExtension];
  return [NSString stringWithFormat:@"%@_%@.%@",
          defaultPrefix,
          NSUUID.UUID.UUIDString.lowercaseString,
          extension];
}

+ (nullable NSData *)decodeBase64Payload:(NSString *)payload
                           errorResponse:(id<FBResponsePayload> __autoreleasing *)errorResponse
{
  NSUInteger maxPayloadSize = FBConfiguration.maximumPushPayloadSize;
  NSUInteger encodedLimit = ((maxPayloadSize + 2) / 3) * 4 + 4;
  if ([payload lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > encodedLimit) {
    if (errorResponse) {
      NSString *message = [NSString stringWithFormat:@"Base64 payload exceeds the configured limit of %@ decoded bytes",
                           @(maxPayloadSize)];
      *errorResponse = FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message
                                                                                   traceback:nil]);
    }
    return nil;
  }

  NSData *content = [[NSData alloc] initWithBase64EncodedString:payload options:0];
  if (nil == content) {
    if (errorResponse) {
      *errorResponse = FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot decode the payload from base64"
                                                                                   traceback:nil]);
    }
    return nil;
  }
  if (content.length > maxPayloadSize) {
    if (errorResponse) {
      NSString *message = [NSString stringWithFormat:@"Decoded payload exceeds the configured limit of %@ bytes",
                           @(maxPayloadSize)];
      *errorResponse = FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message
                                                                                   traceback:nil]);
    }
    return nil;
  }
  return content;
}

+ (nullable NSString *)safeTemporaryUploadPathForFilename:(NSString *)filename
                                                    error:(NSError **)error
{
  NSString *uploadDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wda_uploads"];
  NSFileManager *fileManager = NSFileManager.defaultManager;
  if (![fileManager createDirectoryAtPath:uploadDirectory
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:error]) {
    return nil;
  }

  NSString *basePath = uploadDirectory.stringByStandardizingPath;
  NSString *targetPath = [[uploadDirectory stringByAppendingPathComponent:filename] stringByStandardizingPath];
  NSString *basePrefix = [basePath hasSuffix:@"/"] ? basePath : [basePath stringByAppendingString:@"/"];
  if (![targetPath hasPrefix:basePrefix]) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.Uploads"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: @"Resolved upload path escapes the temporary upload directory"}];
    }
    return nil;
  }
  return targetPath;
}

+ (id<FBResponsePayload>)saveBase64ImageToAlbum:(NSString *)payload
{
#if TARGET_OS_TV
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"unsupported"
                                                                          traceback:nil]);
#else
  id<FBResponsePayload> errorResponse = nil;
  NSData *content = [self.class decodeBase64Payload:payload errorResponse:&errorResponse];
  if (nil == content) {
    return errorResponse;
  }
  UIImage *image = nil == content ? nil : [UIImage imageWithData:content];
  if (nil == image) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"No image can be parsed from the given payload data"
                                                                       traceback:nil]);
  }
  UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
  return FBResponseWithOK();
#endif
}

+ (id<FBResponsePayload>)saveBase64VideoToAlbum:(NSString *)payload
{
#if TARGET_OS_TV
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"unsupported"
                                                                          traceback:nil]);
#else
  id<FBResponsePayload> errorResponse = nil;
  NSData *content = [self.class decodeBase64Payload:payload errorResponse:&errorResponse];
  if (nil == content) {
    return errorResponse;
  }
  NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wda_video_%@.mp4", NSUUID.UUID.UUIDString]];
  NSError *error;
  if (![content writeToFile:tmpPath options:NSDataWritingAtomic error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  UISaveVideoAtPathToSavedPhotosAlbum(tmpPath, nil, nil, nil);
  return FBResponseWithOK();
#endif
}

+ (id<FBResponsePayload>)saveBase64FileToAlbum:(NSString *)payload
                                      filename:(nullable NSString *)filename
{
  id<FBResponsePayload> errorResponse = nil;
  NSData *content = [self.class decodeBase64Payload:payload errorResponse:&errorResponse];
  if (nil == content) {
    return errorResponse;
  }
  NSError *error;
  NSString *safeFilename = [self.class safeUploadFilenameFromRequestedFilename:filename
                                                               defaultPrefix:@"wda_file"
                                                           defaultExtension:@"bin"];
  NSString *tmpPath = [self.class safeTemporaryUploadPathForFilename:safeFilename error:&error];
  if (nil == tmpPath) {
    return FBResponseWithUnknownError(error);
  }
  if (![content writeToFile:tmpPath options:NSDataWritingAtomic error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithObject(@{@"path": tmpPath});
}

+ (id<FBResponsePayload>)handlePushImage:(FBRouteRequest *)request
{
  NSString *payload = [self.class extractPayloadString:request.arguments];
  if (nil == payload) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"A base64 payload must be provided"
                                                                       traceback:nil]);
  }
  return [self.class saveBase64ImageToAlbum:payload];
}

+ (id<FBResponsePayload>)handlePushVideo:(FBRouteRequest *)request
{
  NSString *payload = [self.class extractPayloadString:request.arguments];
  if (nil == payload) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"A base64 payload must be provided"
                                                                       traceback:nil]);
  }
  return [self.class saveBase64VideoToAlbum:payload];
}

+ (id<FBResponsePayload>)handlePushFile:(FBRouteRequest *)request
{
  NSString *payload = [self.class extractPayloadString:request.arguments];
  if (nil == payload) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"A base64 payload must be provided"
                                                                       traceback:nil]);
  }
  NSString *filename = [self.class requestedFilenameFromRequest:request];
  NSString *extension = [self.class safeExtensionFromFilename:filename ?: @""
                                             defaultExtension:@"bin"];
  if ([@[@"jpg", @"jpeg", @"png", @"gif", @"heic"] containsObject:extension]) {
    return [self.class saveBase64ImageToAlbum:payload];
  }
  if ([@[@"mov", @"mp4", @"m4v"] containsObject:extension]) {
    return [self.class saveBase64VideoToAlbum:payload];
  }
  return [self.class saveBase64FileToAlbum:payload filename:filename];
}

+ (id<FBResponsePayload>)handleGetScreenshot:(FBRouteRequest *)request
{
  NSError *error;
  NSDictionary *rectDict = [request.arguments[@"rect"] isKindOfClass:NSDictionary.class]
    ? (NSDictionary *)request.arguments[@"rect"]
    : nil;
  NSNumber *scaleValue = [request.arguments[@"scale"] isKindOfClass:NSNumber.class]
    ? (NSNumber *)request.arguments[@"scale"]
    : nil;

  NSData *screenshotData = nil;
  if (nil != rectDict || nil != scaleValue) {
    CGRect rect = CGRectZero;
    if (nil != rectDict) {
      rect = CGRectMake([rectDict[@"x"] doubleValue],
                        [rectDict[@"y"] doubleValue],
                        [rectDict[@"width"] doubleValue],
                        [rectDict[@"height"] doubleValue]);
    }
    screenshotData = [XCUIDevice.sharedDevice fb_screenshotWithError:&error
                                                                 rect:rect
                                                                scale:scaleValue
                                                                error:&error];
  } else {
    screenshotData = [XCUIDevice.sharedDevice fb_screenshotWithError:&error];
  }
  if (nil == screenshotData) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithObject([screenshotData base64EncodedStringWithOptions:0]);
}

+ (BOOL)handlesPasteText:(NSString *)text
{
  if (0 == text.length) {
    return YES;
  }
  NSError *error;
  if (!FBTypeText(text, [FBConfiguration maxTypingFrequency], &error)) {
    return NO;
  }
  return YES;
}

+ (id<FBResponsePayload>)handlesSendKeys:(FBRouteRequest *)request
{
  id rawText = request.arguments[@"text"] ?: request.arguments[@"value"];
  NSString *textToType = nil;
  if ([rawText isKindOfClass:NSArray.class]) {
    textToType = [(NSArray *)rawText componentsJoinedByString:@""];
  } else if ([rawText isKindOfClass:NSString.class]) {
    textToType = rawText;
  } else if (nil != rawText) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"The 'text' or 'value' argument must be either a string or an array"
                                                                       traceback:nil]);
  } else {
    id keys = request.arguments[@"keys"];
    if ([keys isKindOfClass:NSArray.class]) {
      NSMutableString *builder = [NSMutableString string];
      for (id item in (NSArray *)keys) {
        if ([item isKindOfClass:NSString.class]) {
          [builder appendString:(NSString *)item];
        }
      }
      textToType = builder.copy;
    }
  }
  if (0 == textToType.length) {
    return FBResponseWithOK();
  }
  if ([self.class handlesPasteText:textToType]) {
    return FBResponseWithOK();
  }
  return FBResponseWithStatus([FBCommandStatus invalidElementStateErrorWithMessage:@"Cannot type the provided text"
                                                                         traceback:nil]);
}

+ (nullable NSString *)generateSignWithRandomStr:(NSString *)randomStr
                                       timestamp:(NSNumber *)timestamp
{
  NSString *secret = NSProcessInfo.processInfo.environment[@"WDA_DEVICE_INIT_SIGNING_SECRET"];
  if (secret.length == 0) {
    return nil;
  }
  NSString *payload = [NSString stringWithFormat:@"%@:%@",
                       randomStr ?: @"",
                       timestamp ?: @0];
  return FBAuxHmacSha256(secret, payload);
}

+ (id<FBResponsePayload>)handleDeviceInit:(FBRouteRequest *)request
{
  NSString *randomStr = [NSUUID UUID].UUIDString;
  NSNumber *timestamp = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
  NSString *sign = [self.class generateSignWithRandomStr:randomStr timestamp:timestamp];
  return FBResponseWithObject(@{
    @"ready": @YES,
    @"randomStr": randomStr,
    @"sign": sign ?: @"",
    @"signatureAlgorithm": sign.length > 0 ? @"HMAC-SHA256" : @"none",
    @"timestamp": timestamp,
    @"isLocked": @([XCUIDevice sharedDevice].fb_isScreenLocked),
    @"ip": [XCUIDevice sharedDevice].fb_wifiIPAddress ?: NSNull.null,
  });
}

+ (id<FBResponsePayload>)handlePingCommand:(FBRouteRequest *)request
{
  return FBResponseWithOK();
}

#pragma mark - Helpers

+ (id<FBResponsePayload>)handleGetScreen:(FBRouteRequest *)request
{
  XCUIApplication *app = XCUIApplication.fb_systemApplication;

  XCUIElement *mainStatusBar = app.statusBars.allElementsBoundByIndex.firstObject;
  CGSize statusBarSize = (nil == mainStatusBar) ? CGSizeZero : mainStatusBar.frame.size;

#if TARGET_OS_TV
  CGSize screenSize = app.frame.size;
#else
  CGSize screenSize = FBAdjustDimensionsForApplication(app.wdFrame.size, app.interfaceOrientation);
#endif

  return FBResponseWithObject(
                              @{
    @"screenSize":@{@"width": @(screenSize.width),
                    @"height": @(screenSize.height)
    },
    @"statusBarSize": @{@"width": @(statusBarSize.width),
                        @"height": @(statusBarSize.height),
    },
    @"scale": @([FBScreen scale]),
  });
}

+ (id<FBResponsePayload>)handleLock:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_lockScreen:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleIsLocked:(FBRouteRequest *)request
{
  BOOL isLocked = [XCUIDevice sharedDevice].fb_isScreenLocked;
  return FBResponseWithObject(isLocked ? @YES : @NO);
}

+ (id<FBResponsePayload>)handleUnlock:(FBRouteRequest *)request
{
  NSError *error;
  if (![[XCUIDevice sharedDevice] fb_unlockScreen:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleActiveAppInfo:(FBRouteRequest *)request
{
  XCUIApplication *app = request.session.activeApplication ?: XCUIApplication.fb_activeApplication;
  return FBResponseWithObject(@{
    @"pid": @(app.processID),
    @"bundleId": app.bundleID,
    @"name": app.identifier,
    @"processArguments": [self processArguments:app],
  });
}

/**
 * Returns current active app and its arguments of active session
 *
 * @return The dictionary of current active bundleId and its process/environment argumens
 *
 * @example
 *
 *     [self currentActiveApplication]
 *     //=> {
 *     //       "processArguments" : {
 *     //       "env" : {
 *     //           "HAPPY" : "testing"
 *     //       },
 *     //       "args" : [
 *     //           "happy",
 *     //           "tseting"
 *     //       ]
 *     //   }
 *
 *     [self currentActiveApplication]
 *     //=> {}
 */
+ (NSDictionary *)processArguments:(XCUIApplication *)app
{
  // Can be nil if no active activation is defined by XCTest
  if (app == nil) {
    return @{};
  }

  return
  @{
    @"args": app.launchArguments,
    @"env": app.launchEnvironment
  };
}

#if !TARGET_OS_TV
+ (id<FBResponsePayload>)handleSetPasteboard:(FBRouteRequest *)request
{
  NSString *contentType = request.arguments[@"contentType"] ?: @"plaintext";
  NSData *content = [[NSData alloc] initWithBase64EncodedString:(NSString *)request.arguments[@"content"]
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
  if (nil == content) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Cannot decode the pasteboard content from base64" traceback:nil]);
  }
  NSError *error;
  if (![FBPasteboard setData:content forType:contentType error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetPasteboard:(FBRouteRequest *)request
{
  NSString *contentType = request.arguments[@"contentType"] ?: @"plaintext";
  NSError *error;
  id result = [FBPasteboard dataForType:contentType error:&error];
  if (nil == result) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithObject([result base64EncodedStringWithOptions:0]);
}

+ (id<FBResponsePayload>)handleGetBatteryInfo:(FBRouteRequest *)request
{
  if (![[UIDevice currentDevice] isBatteryMonitoringEnabled]) {
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
  }
  return FBResponseWithObject(@{
    @"level": @([UIDevice currentDevice].batteryLevel),
    @"state": @([UIDevice currentDevice].batteryState)
  });
}
#endif

+ (id<FBResponsePayload>)handlePressButtonCommand:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_pressButton:(id)request.arguments[@"name"]
                                   forDuration:(NSNumber *)request.arguments[@"duration"]
                                         error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleActivateSiri:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_activateSiriVoiceRecognitionWithText:(id)request.arguments[@"text"] error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handlePeformIOHIDEvent:(FBRouteRequest *)request
{
  NSNumber *page = request.arguments[@"page"];
  NSNumber *usage = request.arguments[@"usage"];
  NSNumber *duration = request.arguments[@"duration"];
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_performIOHIDEventWithPage:page.unsignedIntValue
                                                       usage:usage.unsignedIntValue
                                                    duration:duration.doubleValue
                                                       error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id <FBResponsePayload>)handleLaunchUnattachedApp:(FBRouteRequest *)request
{
  NSString *bundle = (NSString *)request.arguments[@"bundleId"];
  if ([FBUnattachedAppLauncher launchAppWithBundleId:bundle]) {
    return FBResponseWithOK();
  }
  return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:@"LSApplicationWorkspace failed to launch app" traceback:nil]);
}

+ (id <FBResponsePayload>)handleResetAppAuth:(FBRouteRequest *)request
{
  NSNumber *resource = request.arguments[@"resource"];
  if (nil == resource) {
    NSString *errMsg = @"The 'resource' argument must be set to a valid resource identifier (numeric value). See https://developer.apple.com/documentation/xctest/xcuiprotectedresource?language=objc";
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:errMsg traceback:nil]);
  }
  [request.session.activeApplication resetAuthorizationStatusForResource:(XCUIProtectedResource)resource.longLongValue];
  return FBResponseWithOK();
}

/**
 Returns device location data.
 It requires to configure location access permission by manual.
 The response of 'latitude', 'longitude' and 'altitude' are always zero (0) without authorization.
 'authorizationStatus' indicates current authorization status. '3' is 'Always'.
 https://developer.apple.com/documentation/corelocation/clauthorizationstatus

 Settings -> Privacy -> Location Service -> WebDriverAgent-Runner -> Always

 The return value could be zero even if the permission is set to 'Always'
 since the location service needs some time to update the location data.
 */
+ (id<FBResponsePayload>)handleGetLocation:(FBRouteRequest *)request
{
#if TARGET_OS_TV
  return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"unsupported"
                                                                          traceback:nil]);
#else
  CLLocationManager *locationManager = [[CLLocationManager alloc] init];
  [locationManager setDistanceFilter:kCLHeadingFilterNone];
  // Always return the best acurate location data
  [locationManager setDesiredAccuracy:kCLLocationAccuracyBest];
  [locationManager setPausesLocationUpdatesAutomatically:NO];
  [locationManager startUpdatingLocation];

  CLAuthorizationStatus authStatus;
  if ([locationManager respondsToSelector:@selector(authorizationStatus)]) {
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[locationManager class]
                                                                            instanceMethodSignatureForSelector:@selector(authorizationStatus)]];
    [invocation setSelector:@selector(authorizationStatus)];
    [invocation setTarget:locationManager];
    [invocation invoke];
    [invocation getReturnValue:&authStatus];
  } else {
    authStatus = [CLLocationManager authorizationStatus];
  }

  return FBResponseWithObject(@{
    @"authorizationStatus": @(authStatus),
    @"latitude": @(locationManager.location.coordinate.latitude),
    @"longitude": @(locationManager.location.coordinate.longitude),
    @"altitude": @(locationManager.location.altitude),
  });
#endif
}

+ (id<FBResponsePayload>)handleExpectNotification:(FBRouteRequest *)request
{
  NSString *name = request.arguments[@"name"];
  if (nil == name) {
    NSString *message = @"Notification name argument must be provided";
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
  }
  NSNumber *timeout = request.arguments[@"timeout"] ?: @60;
  NSString *type = request.arguments[@"type"] ?: @"plain";

  XCTWaiterResult result;
  if ([type isEqualToString:@"plain"]) {
    result = [FBNotificationsHelper waitForNotificationWithName:name timeout:timeout.doubleValue];
  } else if ([type isEqualToString:@"darwin"]) {
    result = [FBNotificationsHelper waitForDarwinNotificationWithName:name timeout:timeout.doubleValue];
  } else {
    NSString *message = [NSString stringWithFormat:@"Notification type could only be 'plain' or 'darwin'. Got '%@' instead", type];
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
  }
  if (result != XCTWaiterResultCompleted) {
    NSString *message = [NSString stringWithFormat:@"Did not receive any expected %@ notifications within %@s",
                         name, timeout];
    return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:message traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleSetDeviceAppearance:(FBRouteRequest *)request
{
  NSString *name = [request.arguments[@"name"] lowercaseString];
  if (nil == name || !([name isEqualToString:@"light"] || [name isEqualToString:@"dark"])) {
    NSString *message = @"The appearance name must be either 'light' or 'dark'";
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
  }

  FBUIInterfaceAppearance appearance = [name isEqualToString:@"light"]
  ? FBUIInterfaceAppearanceLight
  : FBUIInterfaceAppearanceDark;
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_setAppearance:appearance error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetDeviceInfo:(FBRouteRequest *)request
{
  // Returns locale like ja_EN and zh-Hant_US. The format depends on OS
  // Developers should use this locale by default
  // https://developer.apple.com/documentation/foundation/nslocale/1414388-autoupdatingcurrentlocale
  NSString *currentLocale = [[NSLocale autoupdatingCurrentLocale] localeIdentifier];

  NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionaryWithDictionary:
                                     @{
    @"currentLocale": currentLocale,
    @"timeZone": self.timeZone,
    @"name": UIDevice.currentDevice.name,
    @"model": UIDevice.currentDevice.model,
    @"uuid": [UIDevice.currentDevice.identifierForVendor UUIDString] ?: @"unknown",
    // https://developer.apple.com/documentation/uikit/uiuserinterfaceidiom?language=objc
    @"userInterfaceIdiom": @(UIDevice.currentDevice.userInterfaceIdiom),
    @"userInterfaceStyle": self.userInterfaceStyle,
#if TARGET_OS_SIMULATOR
    @"isSimulator": @(YES),
#else
    @"isSimulator": @(NO),
#endif
  }];

  // https://developer.apple.com/documentation/foundation/nsprocessinfothermalstate
  deviceInfo[@"thermalState"] = @(NSProcessInfo.processInfo.thermalState);

  return FBResponseWithObject(deviceInfo);
}

/**
 * @return Current user interface style as a string
 */
+ (NSString *)userInterfaceStyle
{

  if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"15.0")) {
    // Only iOS 15+ simulators/devices return correct data while
    // the api itself works in iOS 13 and 14 that has style preference.
    NSNumber *appearance = [XCUIDevice.sharedDevice fb_getAppearance];
    if (appearance != nil) {
      return [self getAppearanceName:appearance];
    }
  }

  static id userInterfaceStyle = nil;
  static dispatch_once_t styleOnceToken;
  dispatch_once(&styleOnceToken, ^{
    if ([UITraitCollection respondsToSelector:NSSelectorFromString(@"currentTraitCollection")]) {
      id currentTraitCollection = [UITraitCollection performSelector:NSSelectorFromString(@"currentTraitCollection")];
      if (nil != currentTraitCollection) {
        userInterfaceStyle = [currentTraitCollection valueForKey:@"userInterfaceStyle"];
      }
    }
  });

  if (nil == userInterfaceStyle) {
    return @"unsupported";
  }

  return [self getAppearanceName:userInterfaceStyle];
}

+ (NSString *)getAppearanceName:(NSNumber *)appearance
{
  switch ([appearance longLongValue]) {
    case FBUIInterfaceAppearanceUnspecified:
      return @"automatic";
    case FBUIInterfaceAppearanceLight:
      return @"light";
    case FBUIInterfaceAppearanceDark:
      return @"dark";
    default:
      return @"unknown";
  }
}

/**
 * @return The string of TimeZone. Returns TZ timezone id by default. Returns TimeZone name by Apple if TZ timezone id is not available.
 */
+ (NSString *)timeZone
{
  NSTimeZone *localTimeZone = [NSTimeZone localTimeZone];
  // Apple timezone name like "US/New_York"
  NSString *timeZoneAbb = [localTimeZone abbreviation];
  if (timeZoneAbb == nil) {
    return [localTimeZone name];
  }

  // Convert timezone name to ids like "America/New_York" as TZ database Time Zones format
  // https://developer.apple.com/documentation/foundation/nstimezone
  NSString *timeZoneId = [[NSTimeZone timeZoneWithAbbreviation:timeZoneAbb] name];
  if (timeZoneId != nil) {
    return timeZoneId;
  }

  return [localTimeZone name];
}

#if !TARGET_OS_TV // tvOS does not provide relevant APIs
+ (id<FBResponsePayload>)handleGetSimulatedLocation:(FBRouteRequest *)request
{
  NSError *error;
  CLLocation *location = [XCUIDevice.sharedDevice fb_getSimulatedLocation:&error];
  if (nil != error) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithObject(@{
    @"latitude": location ? @(location.coordinate.latitude) : NSNull.null,
    @"longitude": location ? @(location.coordinate.longitude) : NSNull.null,
    @"altitude": location ? @(location.altitude) : NSNull.null,
  });
}

+ (id<FBResponsePayload>)handleSetSimulatedLocation:(FBRouteRequest *)request
{
  NSNumber *longitude = request.arguments[@"longitude"];
  NSNumber *latitude = request.arguments[@"latitude"];

  if (nil == longitude || nil == latitude) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Both latitude and longitude must be provided"
                                                                       traceback:nil]);
  }
  NSError *error;
  CLLocation *location = [[CLLocation alloc] initWithLatitude:latitude.doubleValue
                                                    longitude:longitude.doubleValue];
  if (![XCUIDevice.sharedDevice fb_setSimulatedLocation:location error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleClearSimulatedLocation:(FBRouteRequest *)request
{
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_clearSimulatedLocation:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

#if __clang_major__ >= 15
+ (id<FBResponsePayload>)handleKeyboardInput:(FBRouteRequest *)request
{
  FBElementCache *elementCache = request.session.elementCache;
  BOOL hasElement = ![request.parameters[@"uuid"] isEqual:@"0"];
  XCUIElement *destination = hasElement
    ? [elementCache elementForUUID:(NSString *)request.parameters[@"uuid"]
                    checkStaleness:YES]
    : request.session.activeApplication;
  id keys = request.arguments[@"keys"];

  if (![destination respondsToSelector:@selector(typeKey:modifierFlags:)]) {
    NSString *message = @"typeKey API is only supported since Xcode15 and iPadOS 17";
    return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:message
                                                                            traceback:nil]);
  }

  if (![keys isKindOfClass:NSArray.class]) {
    NSString *message = @"The 'keys' argument must be an array";
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message
                                                                       traceback:nil]);
  }
  for (id item in (NSArray *)keys) {
    if ([item isKindOfClass:NSString.class]) {
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: item;
      [destination typeKey:keyValue modifierFlags:XCUIKeyModifierNone];
    } else if ([item isKindOfClass:NSDictionary.class]) {
      id key = [(NSDictionary *)item objectForKey:@"key"];
      if (![key isKindOfClass:NSString.class]) {
        NSString *message = [NSString stringWithFormat:@"All dictionaries of 'keys' array must have the 'key' item of type string. Got '%@' instead in the item %@", key, item];
        return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message
                                                                           traceback:nil]);
      }
      id modifiers = [(NSDictionary *)item objectForKey:@"modifierFlags"];
      NSUInteger modifierFlags = XCUIKeyModifierNone;
      if ([modifiers isKindOfClass:NSNumber.class]) {
        modifierFlags = [(NSNumber *)modifiers unsignedIntValue];
      }
      NSString *keyValue = [FBKeyboard keyValueForName:item] ?: key;
      [destination typeKey:keyValue modifierFlags:modifierFlags];
    } else {
      NSString *message = @"All items of the 'keys' array must be either dictionaries or strings";
      return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message
                                                                         traceback:nil]);
    }
  }
  return FBResponseWithOK();
}
#endif
#endif

+ (id<FBResponsePayload>)handlePerformAccessibilityAudit:(FBRouteRequest *)request
{
  NSError *error;
  NSArray *requestedTypes = request.arguments[@"auditTypes"];
  NSMutableSet *typesSet = [NSMutableSet set];
  if (nil == requestedTypes || 0 == [requestedTypes count]) {
    [typesSet addObject:@"XCUIAccessibilityAuditTypeAll"];
  } else {
    [typesSet addObjectsFromArray:requestedTypes];
  }
  NSArray *result = [request.session.activeApplication fb_performAccessibilityAuditWithAuditTypesSet:typesSet.copy
                                                                                               error:&error];
  if (nil == result) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.description
                                                               traceback:nil]);
  }
  return FBResponseWithObject(result);
}

@end
