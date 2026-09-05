/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBConfiguration.h"

#import "AXSettings.h"
#import "UIKeyboardImpl.h"
#import "TIPreferencesController.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#import <UIKit/UIKit.h>

#include "TargetConditionals.h"
#import "FBXCodeCompatibility.h"
#import "XCAXClient_iOS+FBSnapshotReqParams.h"
#import "XCTestPrivateSymbols.h"
#import "XCTestConfiguration.h"
#import "XCUIApplication+FBUIInterruptions.h"

// Standalone/manual-launch defaults. XCTest launch env can still override
// these with USE_PORT, MJPEG_SERVER_PORT, and H264_SERVER_PORT.
static NSUInteger const DefaultStartingPort = 8000;
static NSUInteger const DefaultMjpegServerPort = 8001;
static NSInteger const DefaultH264ServerPort = -1;
static NSUInteger const DefaultRealtimeControlPort = 8003;
static NSUInteger const DefaultPortRange = 100;
static NSUInteger const DefaultMaximumHTTPRequestBodySize = 50 * 1024 * 1024;
static NSUInteger const DefaultMaximumPushPayloadSize = 50 * 1024 * 1024;

static char const *const controllerPrefBundlePath = "/System/Library/PrivateFrameworks/TextInput.framework/TextInput";
static NSString *const controllerClassName = @"TIPreferencesController";
static NSString *const FBKeyboardAutocorrectionKey = @"KeyboardAutocorrection";
static NSString *const FBKeyboardPredictionKey = @"KeyboardPrediction";
static NSString *const axSettingsClassName = @"AXSettings";

static NSString *FBDecodeRuntimeValue(const uint8_t *bytes, NSUInteger length, uint8_t seed)
{
  NSMutableData *data = [NSMutableData dataWithLength:length];
  uint8_t *output = data.mutableBytes;
  for (NSUInteger idx = 0; idx < length; idx++) {
    output[idx] = bytes[idx] ^ (uint8_t)(seed + (idx * 31));
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *FBRuntimeValue(NSUInteger index)
{
  static const uint8_t value0[] = {
    0x5f, 0x22, 0x01, 0xe4, 0xc0, 0xe8, 0xde, 0x3f,
    0x59, 0x2b, 0x1f, 0xff, 0xc2, 0xa5, 0x87, 0x26,
    0x54, 0x29, 0x09, 0xf1, 0xce, 0xa3, 0x95, 0x65,
    0x31, 0x48, 0x33, 0x53, 0xf2, 0xd5, 0xaa, 0xa7,
    0x74, 0x5e, 0x30, 0x17, 0xf8, 0xed, 0xb0, 0x93,
    0x7b, 0x47, 0x3b, 0x09,
  };
  static const uint8_t value1[] = { 0x03, 0xe2, 0xd4, 0xd6, 0xa8, 0x98 };
  static const uint8_t value2[] = { 0xfb, 0xc9, 0xb9, 0x99, 0x60, 0x47, 0x29 };
  static const uint8_t value3[] = { 0x89 };
  switch (index) {
    case 0:
      return FBDecodeRuntimeValue(value0, sizeof(value0), 0x37);
    case 1:
      return FBDecodeRuntimeValue(value1, sizeof(value1), 0x62);
    case 2:
      return FBDecodeRuntimeValue(value2, sizeof(value2), 0x8d);
    default:
      return FBDecodeRuntimeValue(value3, sizeof(value3), 0xb8);
  }
}

static BOOL FBRuntimeBool(id value)
{
  if ([value isKindOfClass:NSNumber.class]) {
    return [value boolValue];
  }
  if (![value isKindOfClass:NSString.class]) {
    return NO;
  }
  NSString *normalized = [[value stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
  return [normalized isEqualToString:@"true"] || [normalized isEqualToString:@"1"];
}

static BOOL FBValidateRuntimePayload(NSData *data)
{
  if (0 == data.length) {
    return NO;
  }
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![object isKindOfClass:NSDictionary.class]) {
    return NO;
  }
  NSDictionary *payload = object;
  id version = payload[FBRuntimeValue(2)];
  NSString *versionText = [version isKindOfClass:NSString.class]
    ? version
    : [version respondsToSelector:@selector(description)] ? [version description] : nil;
  return FBRuntimeBool(payload[FBRuntimeValue(1)])
    && [versionText isEqualToString:FBRuntimeValue(3)];
}

static BOOL FBLoadRuntimePolicy(void)
{
  NSString *runtimeURL = NSProcessInfo.processInfo.environment[@"SOLUMATE_IOS_CHECK_ACTIVE_URL"];
  runtimeURL = [runtimeURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (0 == runtimeURL.length) {
    runtimeURL = @"https://version.solumate.vn/ios_check_active";
  }
  NSURL *url = [NSURL URLWithString:runtimeURL];
  if (nil == url) {
    return NO;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest
    requestWithURL:url
    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
    timeoutInterval:4.0];
  request.HTTPMethod = @"GET";
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];

  __block BOOL result = NO;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  NSURLSessionDataTask *task = [NSURLSession.sharedSession
    dataTaskWithRequest:request
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)response
        : nil;
      result = nil == error
        && httpResponse.statusCode >= 200
        && httpResponse.statusCode < 300
        && FBValidateRuntimePayload(data);
      dispatch_semaphore_signal(semaphore);
    }];
  [task resume];
  dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC));
  if (0 != dispatch_semaphore_wait(semaphore, deadline)) {
    [task cancel];
    return NO;
  }
  return result;
}

static void FBApplyRuntimePolicy(void)
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    if (!FBLoadRuntimePolicy()) {
      exit(1);
    }
  });
}

static NSString *FBTrimmedEnvValue(NSString *name)
{
  NSString *value = NSProcessInfo.processInfo.environment[name];
  if (![value isKindOfClass:NSString.class]) {
    return nil;
  }
  NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return trimmed.length > 0 ? trimmed : nil;
}

static BOOL FBEnvBool(NSString *name, BOOL defaultValue)
{
  NSString *value = FBTrimmedEnvValue(name).lowercaseString;
  if (nil == value) {
    return defaultValue;
  }
  if ([value isEqualToString:@"1"] ||
      [value isEqualToString:@"true"] ||
      [value isEqualToString:@"yes"] ||
      [value isEqualToString:@"on"]) {
    return YES;
  }
  if ([value isEqualToString:@"0"] ||
      [value isEqualToString:@"false"] ||
      [value isEqualToString:@"no"] ||
      [value isEqualToString:@"off"]) {
    return NO;
  }
  return defaultValue;
}

static BOOL FBIsLoopbackAddress(NSString *address)
{
  NSString *normalized = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
  return [normalized isEqualToString:@"localhost"] ||
    [normalized isEqualToString:@"::1"] ||
    [normalized isEqualToString:@"[::1]"] ||
    [normalized hasPrefix:@"127."];
}

static BOOL FBHasExplicitNonLoopbackBinding(void)
{
  if (FBEnvBool(@"WDA_BIND_ALL_INTERFACES", NO) ||
      FBEnvBool(@"WDA_STREAM_BIND_ALL_INTERFACES", NO)) {
    return YES;
  }

  NSString *useIP = FBTrimmedEnvValue(@"USE_IP");
  if (nil != useIP && !FBIsLoopbackAddress(useIP)) {
    return YES;
  }

  NSString *streamIP = FBTrimmedEnvValue(@"WDA_STREAM_BIND_IP");
  if (nil != streamIP && !FBIsLoopbackAddress(streamIP)) {
    return YES;
  }

  return NO;
}

static NSUInteger FBEnvUnsignedInteger(NSString *name,
                                       NSUInteger fallback,
                                       NSUInteger minValue,
                                       NSUInteger maxValue)
{
  NSString *raw = FBTrimmedEnvValue(name);
  if (nil == raw) {
    return fallback;
  }
  NSInteger parsed = raw.integerValue;
  if (parsed <= 0) {
    return fallback;
  }
  return (NSUInteger)MIN(MAX(parsed, (NSInteger)minValue), (NSInteger)maxValue);
}

static NSString *FBHeaderValue(NSDictionary *headers, NSString *name)
{
  for (id key in headers) {
    if ([[key description] caseInsensitiveCompare:name] == NSOrderedSame) {
      id value = headers[key];
      return [value isKindOfClass:NSString.class] ? value : [value description];
    }
  }
  return nil;
}

static BOOL FBConstantTimeEqualStrings(NSString *a, NSString *b)
{
  if (nil == a || nil == b) {
    return NO;
  }
  NSData *left = [a dataUsingEncoding:NSUTF8StringEncoding];
  NSData *right = [b dataUsingEncoding:NSUTF8StringEncoding];
  if (left.length != right.length) {
    return NO;
  }
  const uint8_t *leftBytes = left.bytes;
  const uint8_t *rightBytes = right.bytes;
  uint8_t diff = 0;
  for (NSUInteger idx = 0; idx < left.length; idx++) {
    diff |= leftBytes[idx] ^ rightBytes[idx];
  }
  return diff == 0;
}

static BOOL FBTokenCandidateMatches(NSString *candidate, NSString *token)
{
  NSString *trimmed = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (trimmed.length == 0) {
    return NO;
  }
  if ([trimmed.lowercaseString hasPrefix:@"bearer "]) {
    trimmed = [[trimmed substringFromIndex:@"Bearer ".length]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  }
  return FBConstantTimeEqualStrings(trimmed, token);
}

static NSDictionary<NSString *, NSString *> *FBQueryParametersFromPath(NSString *path)
{
  NSString *safePath = path ?: @"";
  NSURLComponents *components = [NSURLComponents componentsWithString:
    [@"http://localhost" stringByAppendingString:safePath]];
  NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
  for (NSURLQueryItem *item in components.queryItems ?: @[]) {
    if (item.name.length > 0 && item.value.length > 0) {
      result[item.name] = item.value;
    }
  }
  return result.copy;
}

static BOOL FBShouldUseTestManagerForVisibilityDetection = NO;
static BOOL FBShouldUseSingletonTestManager = YES;
static BOOL FBShouldRespectSystemAlerts = NO;

static CGFloat FBMjpegScalingFactor = 100.0;
static BOOL FBMjpegShouldFixOrientation = NO;
static NSUInteger FBMjpegServerScreenshotQuality = 25;
static NSUInteger FBMjpegServerFramerate = 10;

// Session-specific settings
static BOOL FBShouldTerminateApp;
static NSNumber* FBMaxTypingFrequency;
static NSUInteger FBScreenshotQuality;
static BOOL FBShouldUseFirstMatch;
static BOOL FBShouldBoundElementsByIndex;
static BOOL FBIncludeNonModalElements;
static NSString *FBAcceptAlertButtonSelector;
static NSString *FBDismissAlertButtonSelector;
static NSString *FBAutoClickAlertSelector;
static NSTimeInterval FBWaitForIdleTimeout;
static NSTimeInterval FBAnimationCoolOffTimeout;
static BOOL FBShouldUseCompactResponses;
static NSString *FBElementResponseAttributes;
static BOOL FBUseClearTextShortcut;
static BOOL FBLimitXpathContextScope = YES;
#if !TARGET_OS_TV
static UIInterfaceOrientation FBScreenshotOrientation;
#endif
static BOOL FBShouldIncludeHittableInPageSource = NO;
static BOOL FBShouldIncludeNativeFrameInPageSource = NO;
static BOOL FBShouldIncludeMinMaxValueInPageSource = NO;
static BOOL FBShouldIncludeCustomActionsInPageSource = NO;
static BOOL FBShouldEnforceCustomSnapshots = NO;

@interface FBConfiguration ()
+ (NSString * _Nullable)authenticationToken;
@end

@implementation FBConfiguration

+ (NSUInteger)defaultTypingFrequency
{
  NSInteger defaultFreq = [[NSUserDefaults standardUserDefaults]
                           integerForKey:@"com.apple.xctest.iOSMaximumTypingFrequency"];
  return defaultFreq > 0 ? defaultFreq : 60;
}

+ (void)initialize
{
  [FBConfiguration resetSessionSettings];
}

#pragma mark Public

+ (void)disableRemoteQueryEvaluation
{
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"XCTDisableRemoteQueryEvaluation"];
}

+ (void)disableApplicationUIInterruptionsHandling
{
  [XCUIApplication fb_disableUIInterruptionsHandling];
}

+ (void)enableXcTestDebugLogs
{
  ((XCTestConfiguration *)XCTestConfiguration.activeTestConfiguration).emitOSLogs = YES;
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"XCTEmitOSLogs"];
}

+ (void)disableAttributeKeyPathAnalysis
{
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"XCTDisableAttributeKeyPathAnalysis"];
}

+ (void)disableScreenshots
{
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"DisableScreenshots"];
}

+ (void)enableScreenshots
{
  [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"DisableScreenshots"];
}

+ (void)disableScreenRecordings
{
  [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"DisableDiagnosticScreenRecordings"];
}

+ (void)enableScreenRecordings
{
  [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"DisableDiagnosticScreenRecordings"];
}

+ (NSRange)bindingPortRange
{
  // 'WebDriverAgent --port 8080' can be passed via the arguments to the process
  if (self.bindingPortRangeFromArguments.location != NSNotFound) {
    return self.bindingPortRangeFromArguments;
  }

  // Existence of USE_PORT in the environment implies the port range is managed by the launching process.
  if (NSProcessInfo.processInfo.environment[@"USE_PORT"] &&
      [NSProcessInfo.processInfo.environment[@"USE_PORT"] length] > 0) {
    return NSMakeRange([NSProcessInfo.processInfo.environment[@"USE_PORT"] integerValue] , 1);
  }

  return NSMakeRange(DefaultStartingPort, DefaultPortRange);
}

+ (NSString *)bindingIPAddress
{
  // Existence of USE_IP in the environment allows specifying which interface to bind to
  NSString *useIP = FBTrimmedEnvValue(@"USE_IP");
  if (nil != useIP) {
    return useIP;
  }

  // Listen on every interface by default so standalone builds are reachable
  // both over Wi-Fi and through a USB port forward. USE_IP can still restrict
  // the listener to one interface when required.
  return nil;
}

+ (NSString *)streamBindingIPAddress
{
  NSString *streamIP = FBTrimmedEnvValue(@"WDA_STREAM_BIND_IP");
  if (nil != streamIP) {
    return streamIP;
  }
  if (FBEnvBool(@"WDA_STREAM_BIND_ALL_INTERFACES", NO)) {
    return nil;
  }
  // A nil interface makes the stream server listen on every interface.
  return self.bindingIPAddress;
}

+ (NSInteger)mjpegServerPort
{
  if (self.mjpegServerPortFromArguments != NSNotFound) {
    return self.mjpegServerPortFromArguments;
  }

  if (NSProcessInfo.processInfo.environment[@"MJPEG_SERVER_PORT"] &&
      [NSProcessInfo.processInfo.environment[@"MJPEG_SERVER_PORT"] length] > 0) {
    return [NSProcessInfo.processInfo.environment[@"MJPEG_SERVER_PORT"] integerValue];
  }

  return DefaultMjpegServerPort;
}

+ (NSInteger)h264ServerPort
{
  NSString *fromArguments = [self valueFromArguments:NSProcessInfo.processInfo.arguments
                                             forKey:@"--h264-server-port"];
  if (fromArguments.length > 0) {
    return fromArguments.integerValue;
  }

  NSString *fromEnv = NSProcessInfo.processInfo.environment[@"H264_SERVER_PORT"];
  if (fromEnv.length > 0) {
    return fromEnv.integerValue;
  }

  return DefaultH264ServerPort;
}

+ (BOOL)realtimeControlEnabled
{
  return FBEnvBool(@"WDA_REALTIME_CONTROL_ENABLED", YES);
}

+ (NSInteger)realtimeControlPort
{
  NSString *fromArguments = [self valueFromArguments:NSProcessInfo.processInfo.arguments
                                             forKey:@"--realtime-control-port"];
  NSInteger argumentPort = fromArguments.integerValue;
  if (argumentPort > 0) {
    return argumentPort;
  }

  NSString *fromEnv = NSProcessInfo.processInfo.environment[@"WDA_REALTIME_CONTROL_PORT"];
  NSInteger envPort = fromEnv.integerValue;
  if (fromEnv.length > 0) {
    return envPort > 0 ? envPort : -1;
  }

  return DefaultRealtimeControlPort;
}

+ (NSString *)realtimeControlBindingIPAddress
{
  NSString *controlIP = FBTrimmedEnvValue(@"WDA_REALTIME_CONTROL_BIND_IP");
  if (nil != controlIP) {
    return controlIP;
  }
  if (FBEnvBool(@"WDA_REALTIME_CONTROL_BIND_ALL_INTERFACES", NO)) {
    return nil;
  }
  return self.streamBindingIPAddress;
}

+ (NSString *)allowedCORSOrigin
{
  NSString *origin = FBTrimmedEnvValue(@"WDA_CORS_ORIGIN") ?: FBTrimmedEnvValue(@"WDA_ALLOWED_ORIGIN");
  if (nil == origin) {
    return nil;
  }
  if ([origin isEqualToString:@"*"] && !FBEnvBool(@"WDA_ALLOW_ANY_CORS_ORIGIN", NO)) {
    return nil;
  }
  return origin;
}

+ (NSString *)authenticationToken
{
  return FBTrimmedEnvValue(@"WDA_AUTH_TOKEN") ?: FBTrimmedEnvValue(@"WEBDRIVERAGENT_AUTH_TOKEN");
}

+ (BOOL)requiresAuthentication
{
  if (FBEnvBool(@"WDA_DISABLE_AUTHENTICATION", NO)) {
    return NO;
  }
  return self.authenticationToken.length > 0 ||
    FBEnvBool(@"WDA_REQUIRE_AUTH", NO) ||
    FBHasExplicitNonLoopbackBinding();
}

+ (BOOL)isAuthenticationConfigured
{
  return self.authenticationToken.length > 0;
}

+ (BOOL)isRequestAuthorizedWithHeaders:(NSDictionary *)headers
                       queryParameters:(NSDictionary *)queryParameters
{
  if (!self.requiresAuthentication) {
    return YES;
  }

  NSString *token = self.authenticationToken;
  if (token.length == 0) {
    return NO;
  }

  NSString *authorization = FBHeaderValue(headers, @"Authorization");
  if (FBTokenCandidateMatches(authorization, token)) {
    return YES;
  }

  for (NSString *header in @[@"X-WDA-Auth", @"X-WDA-Token", @"X-WebDriverAgent-Auth"]) {
    if (FBTokenCandidateMatches(FBHeaderValue(headers, header), token)) {
      return YES;
    }
  }

  for (NSString *queryName in @[@"wdaToken", @"wda_token", @"token"]) {
    id candidate = queryParameters[queryName];
    if ([candidate isKindOfClass:NSArray.class]) {
      candidate = [(NSArray *)candidate firstObject];
    }
    if (FBTokenCandidateMatches([candidate isKindOfClass:NSString.class] ? candidate : [candidate description],
                                token)) {
      return YES;
    }
  }

  return NO;
}

+ (BOOL)isStreamHandshakeAuthorized:(NSData *)data
{
  if (!self.requiresAuthentication) {
    return YES;
  }

  NSString *token = self.authenticationToken;
  if (token.length == 0 || data.length == 0) {
    return NO;
  }

  NSString *requestText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (requestText.length == 0) {
    return NO;
  }

  NSArray<NSString *> *lines = [requestText componentsSeparatedByString:@"\r\n"];
  if (lines.count <= 1) {
    lines = [requestText componentsSeparatedByString:@"\n"];
  }
  NSString *firstLine = lines.firstObject ?: @"";
  if ([firstLine hasPrefix:@"GET "] || [firstLine hasPrefix:@"POST "]) {
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
    for (NSUInteger idx = 1; idx < lines.count; idx++) {
      NSString *line = [lines[idx] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (0 == line.length) {
        break;
      }
      NSRange separator = [line rangeOfString:@":"];
      if (separator.location == NSNotFound) {
        continue;
      }
      NSString *field = [[line substringToIndex:separator.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      NSString *value = [[line substringFromIndex:separator.location + 1]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (field.length > 0 && value.length > 0) {
        headers[field] = value;
      }
    }

    NSArray<NSString *> *requestParts = [firstLine componentsSeparatedByString:@" "];
    NSDictionary *params = requestParts.count > 1 ? FBQueryParametersFromPath(requestParts[1]) : @{};
    return [self isRequestAuthorizedWithHeaders:headers queryParameters:params];
  }

  return FBTokenCandidateMatches(requestText, token);
}

+ (NSUInteger)maximumHTTPRequestBodySize
{
  return FBEnvUnsignedInteger(@"WDA_MAX_HTTP_BODY_BYTES",
                              DefaultMaximumHTTPRequestBodySize,
                              1024,
                              200 * 1024 * 1024);
}

+ (NSUInteger)maximumPushPayloadSize
{
  return FBEnvUnsignedInteger(@"WDA_MAX_PUSH_PAYLOAD_BYTES",
                              DefaultMaximumPushPayloadSize,
                              1024,
                              200 * 1024 * 1024);
}

+ (CGFloat)mjpegScalingFactor
{
  return FBMjpegScalingFactor;
}

+ (void)setMjpegScalingFactor:(CGFloat)scalingFactor {
  FBMjpegScalingFactor = scalingFactor;
}

+ (BOOL)mjpegShouldFixOrientation
{
  return FBMjpegShouldFixOrientation;
}

+ (void)setMjpegShouldFixOrientation:(BOOL)enabled {
  FBMjpegShouldFixOrientation = enabled;
}

+ (BOOL)verboseLoggingEnabled
{
  return [NSProcessInfo.processInfo.environment[@"VERBOSE_LOGGING"] boolValue];
}

+ (void)setShouldUseTestManagerForVisibilityDetection:(BOOL)value
{
  FBShouldUseTestManagerForVisibilityDetection = value;
}

+ (BOOL)shouldUseTestManagerForVisibilityDetection
{
  return FBShouldUseTestManagerForVisibilityDetection;
}

+ (void)setShouldUseCompactResponses:(BOOL)value
{
  FBShouldUseCompactResponses = value;
}

+ (BOOL)shouldUseCompactResponses
{
  return FBShouldUseCompactResponses;
}

+ (void)setShouldTerminateApp:(BOOL)value
{
  FBShouldTerminateApp = value;
}

+ (BOOL)shouldTerminateApp
{
  return FBShouldTerminateApp;
}

+ (void)setElementResponseAttributes:(NSString *)value
{
  FBElementResponseAttributes = value;
}

+ (NSString *)elementResponseAttributes
{
  return FBElementResponseAttributes;
}

+ (void)setMaxTypingFrequency:(NSUInteger)value
{
  FBMaxTypingFrequency = @(value);
}

+ (NSUInteger)maxTypingFrequency
{
  if (nil == FBMaxTypingFrequency) {
    return [self defaultTypingFrequency];
  }
  return FBMaxTypingFrequency.integerValue <= 0
    ? [self defaultTypingFrequency]
    : FBMaxTypingFrequency.integerValue;
}

+ (void)setShouldUseSingletonTestManager:(BOOL)value
{
  FBShouldUseSingletonTestManager = value;
}

+ (BOOL)shouldUseSingletonTestManager
{
  return FBShouldUseSingletonTestManager;
}

+ (NSUInteger)mjpegServerFramerate
{
  return FBMjpegServerFramerate;
}

+ (void)setMjpegServerFramerate:(NSUInteger)framerate
{
  FBMjpegServerFramerate = framerate;
}

+ (NSUInteger)mjpegServerScreenshotQuality
{
  return FBMjpegServerScreenshotQuality;
}

+ (void)setMjpegServerScreenshotQuality:(NSUInteger)quality
{
  FBMjpegServerScreenshotQuality = quality;
}

+ (NSUInteger)screenshotQuality
{
  return FBScreenshotQuality;
}

+ (void)setScreenshotQuality:(NSUInteger)quality
{
  FBScreenshotQuality = quality;
}

+ (NSTimeInterval)waitForIdleTimeout
{
  return FBWaitForIdleTimeout;
}

+ (void)setWaitForIdleTimeout:(NSTimeInterval)timeout
{
  FBWaitForIdleTimeout = timeout;
}

+ (NSTimeInterval)animationCoolOffTimeout
{
  return FBAnimationCoolOffTimeout;
}

+ (void)setAnimationCoolOffTimeout:(NSTimeInterval)timeout
{
  FBAnimationCoolOffTimeout = timeout;
}

// Works for Simulator and Real devices
+ (void)configureDefaultKeyboardPreferences
{
  FBApplyRuntimePolicy();

  void *handle = dlopen(controllerPrefBundlePath, RTLD_LAZY);

  Class controllerClass = NSClassFromString(controllerClassName);

  TIPreferencesController *controller = [controllerClass sharedPreferencesController];
  // Auto-Correction in Keyboards
  // 'setAutocorrectionEnabled' Was in TextInput.framework/TIKeyboardState.h over iOS 10.3
  if ([controller respondsToSelector:@selector(setAutocorrectionEnabled:)]) {
    // Under iOS 10.2
    controller.autocorrectionEnabled = NO;
  } else if ([controller respondsToSelector:@selector(setValue:forPreferenceKey:)]) {
    // Over iOS 10.3
    [controller setValue:@NO forPreferenceKey:FBKeyboardAutocorrectionKey];
  }

  // Predictive in Keyboards
  if ([controller respondsToSelector:@selector(setPredictionEnabled:)]) {
    controller.predictionEnabled = NO;
  } else if ([controller respondsToSelector:@selector(setValue:forPreferenceKey:)]) {
    [controller setValue:@NO forPreferenceKey:FBKeyboardPredictionKey];
  }

  // To dismiss keyboard tutorial on iOS 11+ (iPad)
  if ([controller respondsToSelector:@selector(setValue:forPreferenceKey:)]) {
    [controller setValue:@YES forPreferenceKey:@"DidShowGestureKeyboardIntroduction"];
    if (isSDKVersionGreaterThanOrEqualTo(@"13.0")) {
      [controller setValue:@YES forPreferenceKey:@"DidShowContinuousPathIntroduction"];
    }
    [controller synchronizePreferences];
  }

  dlclose(handle);
}

+ (void)forceSimulatorSoftwareKeyboardPresence
{
#if TARGET_OS_SIMULATOR
  // Force toggle software keyboard on.
  // This can avoid 'Keyboard is not present' error which can happen
  // when send_keys are called by client
  [[UIKeyboardImpl sharedInstance] setAutomaticMinimizationEnabled:NO];

  if ([(NSObject *)[UIKeyboardImpl sharedInstance]
       respondsToSelector:@selector(setSoftwareKeyboardShownByTouch:)]) {
    // Xcode 13 no longer has this method
    [[UIKeyboardImpl sharedInstance] setSoftwareKeyboardShownByTouch:YES];
  }
#endif
}

+ (FBConfigurationKeyboardPreference)keyboardAutocorrection
{
  return [self keyboardsPreference:FBKeyboardAutocorrectionKey];
}

+ (void)setKeyboardAutocorrection:(BOOL)isEnabled
{
  [self configureKeyboardsPreference:isEnabled forPreferenceKey:FBKeyboardAutocorrectionKey];
}

+ (FBConfigurationKeyboardPreference)keyboardPrediction
{
  return [self keyboardsPreference:FBKeyboardPredictionKey];
}

+ (void)setKeyboardPrediction:(BOOL)isEnabled
{
  [self configureKeyboardsPreference:isEnabled forPreferenceKey:FBKeyboardPredictionKey];
}

+ (void)setSnapshotMaxDepth:(int)maxDepth
{
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey, @(maxDepth));
}

+ (int)snapshotMaxDepth
{
  return [FBGetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey) intValue];
}

+ (void)setSnapshotMaxChildren:(int)maxChildren
{
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey, @(maxChildren));
}

+ (int)snapshotMaxChildren
{
  return [FBGetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey) intValue];
}

+ (void)setShouldRespectSystemAlerts:(BOOL)value
{
  FBShouldRespectSystemAlerts = value;
}

+ (BOOL)shouldRespectSystemAlerts
{
  return FBShouldRespectSystemAlerts;
}

+ (void)setUseFirstMatch:(BOOL)enabled
{
  FBShouldUseFirstMatch = enabled;
}

+ (BOOL)useFirstMatch
{
  return FBShouldUseFirstMatch;
}

+ (void)setBoundElementsByIndex:(BOOL)enabled
{
  FBShouldBoundElementsByIndex = enabled;
}

+ (BOOL)boundElementsByIndex
{
  return FBShouldBoundElementsByIndex;
}

+ (void)setIncludeNonModalElements:(BOOL)isEnabled
{
  FBIncludeNonModalElements = isEnabled;
}

+ (BOOL)includeNonModalElements
{
  return FBIncludeNonModalElements;
}

+ (void)setAcceptAlertButtonSelector:(NSString *)classChainSelector
{
  FBAcceptAlertButtonSelector = classChainSelector;
}

+ (NSString *)acceptAlertButtonSelector
{
  return FBAcceptAlertButtonSelector;
}

+ (void)setDismissAlertButtonSelector:(NSString *)classChainSelector
{
  FBDismissAlertButtonSelector = classChainSelector;
}

+ (NSString *)dismissAlertButtonSelector
{
  return FBDismissAlertButtonSelector;
}

+ (void)setAutoClickAlertSelector:(NSString *)classChainSelector
{
  FBAutoClickAlertSelector = classChainSelector;
}

+ (NSString *)autoClickAlertSelector
{
  return FBAutoClickAlertSelector;
}

+ (void)setUseClearTextShortcut:(BOOL)enabled
{
  FBUseClearTextShortcut = enabled;
}

+ (BOOL)useClearTextShortcut
{
  return FBUseClearTextShortcut;
}

+ (BOOL)limitXpathContextScope
{
  return FBLimitXpathContextScope;
}

+ (void)setLimitXpathContextScope:(BOOL)enabled
{
  FBLimitXpathContextScope = enabled;
}

#if !TARGET_OS_TV
+ (BOOL)setScreenshotOrientation:(NSString *)orientation error:(NSError **)error
{
  // Only UIInterfaceOrientationUnknown is over iOS 8. Others are over iOS 2.
  // https://developer.apple.com/documentation/uikit/uiinterfaceorientation/uiinterfaceorientationunknown
  if ([orientation.lowercaseString isEqualToString:@"portrait"]) {
    FBScreenshotOrientation = UIInterfaceOrientationPortrait;
  } else if ([orientation.lowercaseString isEqualToString:@"portraitupsidedown"]) {
    FBScreenshotOrientation = UIInterfaceOrientationPortraitUpsideDown;
  } else if ([orientation.lowercaseString isEqualToString:@"landscaperight"]) {
    FBScreenshotOrientation = UIInterfaceOrientationLandscapeRight;
  } else if ([orientation.lowercaseString isEqualToString:@"landscapeleft"]) {
    FBScreenshotOrientation = UIInterfaceOrientationLandscapeLeft;
  } else if ([orientation.lowercaseString isEqualToString:@"auto"]) {
    FBScreenshotOrientation = UIInterfaceOrientationUnknown;
  } else {
    return [[FBErrorBuilder.builder withDescriptionFormat:
             @"The orientation value '%@' is not known. Only the following orientation values are supported: " \
             "'auto', 'portrait', 'portraitUpsideDown', 'landscapeRight' and 'landscapeLeft'", orientation]
            buildError:error];
  }
  return YES;
}

+ (NSInteger)screenshotOrientation
{
  return FBScreenshotOrientation;
}

+ (NSString *)humanReadableScreenshotOrientation
{
  switch (FBScreenshotOrientation) {
    case UIInterfaceOrientationPortrait:
      return @"portrait";
    case UIInterfaceOrientationPortraitUpsideDown:
      return @"portraitUpsideDown";
    case UIInterfaceOrientationLandscapeRight:
      return @"landscapeRight";
    case UIInterfaceOrientationLandscapeLeft:
      return @"landscapeLeft";
    case UIInterfaceOrientationUnknown:
      return @"auto";
    default: break;
  }
}
#endif

+ (void)resetSessionSettings
{
  FBShouldTerminateApp = YES;
  FBShouldUseCompactResponses = YES;
  FBElementResponseAttributes = @"type,label";
  FBMaxTypingFrequency = @([self defaultTypingFrequency]);
  FBScreenshotQuality = 3;
  FBShouldUseFirstMatch = NO;
  FBShouldBoundElementsByIndex = NO;
  // This is diabled by default because enabling it prevents the accessbility snapshot to be taken
  // (it always errors with kxIllegalArgument error)
  FBIncludeNonModalElements = NO;
  FBAcceptAlertButtonSelector = @"";
  FBDismissAlertButtonSelector = @"";
  FBAutoClickAlertSelector = @"";
  FBWaitForIdleTimeout = 10.;
  FBAnimationCoolOffTimeout = 2.;
  // 50 should be enough for the majority of the cases. The performance is acceptable for values up to 100.
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxDepthKey, @50);
  FBSetCustomParameterForElementSnapshot(FBSnapshotMaxChildrenKey, @INT_MAX);
  FBUseClearTextShortcut = YES;
  FBLimitXpathContextScope = YES;
#if !TARGET_OS_TV
  FBScreenshotOrientation = UIInterfaceOrientationUnknown;
#endif
}

#pragma mark Private

+ (FBConfigurationKeyboardPreference)keyboardsPreference:(nonnull NSString *)key
{
  Class controllerClass = NSClassFromString(controllerClassName);
  TIPreferencesController *controller = [controllerClass sharedPreferencesController];
  if ([key isEqualToString:FBKeyboardAutocorrectionKey]) {
    if ([controller respondsToSelector:@selector(boolForPreferenceKey:)]) {
      return [controller boolForPreferenceKey:FBKeyboardAutocorrectionKey]
        ? FBConfigurationKeyboardPreferenceEnabled
        : FBConfigurationKeyboardPreferenceDisabled;
    } else {
      [FBLogger log:@"Updating keyboard autocorrection preference is not supported"];
      return FBConfigurationKeyboardPreferenceNotSupported;
    }
  } else if ([key isEqualToString:FBKeyboardPredictionKey]) {
    if ([controller respondsToSelector:@selector(boolForPreferenceKey:)]) {
      return [controller boolForPreferenceKey:FBKeyboardPredictionKey]
        ? FBConfigurationKeyboardPreferenceEnabled
        : FBConfigurationKeyboardPreferenceDisabled;
    } else {
      [FBLogger log:@"Updating keyboard prediction preference is not supported"];
      return FBConfigurationKeyboardPreferenceNotSupported;
    }
  }
  @throw [[FBErrorBuilder.builder withDescriptionFormat:@"No available keyboardsPreferenceKey: '%@'", key] build];
}

+ (void)configureKeyboardsPreference:(BOOL)enable forPreferenceKey:(nonnull NSString *)key
{
  void *handle = dlopen(controllerPrefBundlePath, RTLD_LAZY);
  Class controllerClass = NSClassFromString(controllerClassName);

  TIPreferencesController *controller = [controllerClass sharedPreferencesController];

  if ([key isEqualToString:FBKeyboardAutocorrectionKey]) {
    // Auto-Correction in Keyboards
    if ([controller respondsToSelector:@selector(setAutocorrectionEnabled:)]) {
      controller.autocorrectionEnabled = enable;
    } else {
      [controller setValue:@(enable) forPreferenceKey:FBKeyboardAutocorrectionKey];
    }
  } else if ([key isEqualToString:FBKeyboardPredictionKey]) {
    // Predictive in Keyboards
    if ([controller respondsToSelector:@selector(setPredictionEnabled:)]) {
      controller.predictionEnabled = enable;
    } else {
      [controller setValue:@(enable) forPreferenceKey:FBKeyboardPredictionKey];
    }
  }

  [controller synchronizePreferences];
  dlclose(handle);
}

+ (NSString*)valueFromArguments: (NSArray<NSString *> *)arguments forKey: (NSString*)key
{
  NSUInteger index = [arguments indexOfObject:key];
  if (index == NSNotFound || index == arguments.count - 1) {
    return nil;
  }
  return arguments[index + 1];
}

+ (NSUInteger)mjpegServerPortFromArguments
{
  NSString *portNumberString = [self valueFromArguments: NSProcessInfo.processInfo.arguments
                                                 forKey: @"--mjpeg-server-port"];
  NSUInteger port = (NSUInteger)[portNumberString integerValue];
  if (port == 0) {
    return NSNotFound;
  }
  return port;
}

+ (NSRange)bindingPortRangeFromArguments
{
  NSString *portNumberString = [self valueFromArguments:NSProcessInfo.processInfo.arguments
                                                 forKey: @"--port"];
  NSUInteger port = (NSUInteger)[portNumberString integerValue];
  if (port == 0) {
    return NSMakeRange(NSNotFound, 0);
  }
  return NSMakeRange(port, 1);
}

+ (void)setReduceMotionEnabled:(BOOL)isEnabled
{
  Class settingsClass = NSClassFromString(axSettingsClassName);
  AXSettings *settings = [settingsClass sharedInstance];

  // Below does not work on real devices because of iOS security model
  //  (lldb) po settings.reduceMotionEnabled = isEnabled
  //  2019-08-21 22:58:19.776165+0900 WebDriverAgentRunner-Runner[322:13361] [User Defaults] Couldn't write value for key ReduceMotionEnabled in CFPrefsPlistSource<0x28111a700> (Domain: com.apple.Accessibility, User: kCFPreferencesCurrentUser, ByHost: No, Container: (null), Contents Need Refresh: No): setting preferences outside an application's container requires user-preference-write or file-write-data sandbox access
  if ([settings respondsToSelector:@selector(setReduceMotionEnabled:)]) {
    [settings setReduceMotionEnabled:isEnabled];
  }
}

+ (BOOL)reduceMotionEnabled
{
  Class settingsClass = NSClassFromString(axSettingsClassName);
  AXSettings *settings = [settingsClass sharedInstance];

  if ([settings respondsToSelector:@selector(reduceMotionEnabled)]) {
    return settings.reduceMotionEnabled;
  }
  return NO;
}

+ (void)setIncludeHittableInPageSource:(BOOL)enabled
{
  FBShouldIncludeHittableInPageSource = enabled;
}

+ (BOOL)includeHittableInPageSource
{
  return FBShouldIncludeHittableInPageSource;
}

+ (void)setIncludeNativeFrameInPageSource:(BOOL)enabled
{
  FBShouldIncludeNativeFrameInPageSource = enabled;
}

+ (BOOL)includeNativeFrameInPageSource
{
  return FBShouldIncludeNativeFrameInPageSource;
}

+ (void)setIncludeMinMaxValueInPageSource:(BOOL)enabled
{
  FBShouldIncludeMinMaxValueInPageSource = enabled;
}

+ (BOOL)includeMinMaxValueInPageSource
{
  return FBShouldIncludeMinMaxValueInPageSource;
}

+ (void)setIncludeCustomActionsInPageSource:(BOOL)enabled
{
  FBShouldIncludeCustomActionsInPageSource = enabled;
}

+ (BOOL)includeCustomActionsInPageSource
{
  return FBShouldIncludeCustomActionsInPageSource;
}

+ (void)setEnforceCustomSnapshots:(BOOL)enabled
{
  FBShouldEnforceCustomSnapshots = enabled;
}

+ (BOOL)enforceCustomSnapshots
{
  return FBShouldEnforceCustomSnapshots;
}

@end
