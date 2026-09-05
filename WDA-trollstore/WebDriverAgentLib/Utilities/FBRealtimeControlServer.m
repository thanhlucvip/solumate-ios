/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBRealtimeControlServer.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <math.h>

#import "FBConfiguration.h"
#import "FBLogger.h"
#import "XCUIDevice+FBHelpers.h"

static const NSUInteger FBRealtimeControlMaxLineLength = 1024 * 1024;

static BOOL FBRealtimeControlDebugEnabled(void)
{
  NSString *value = NSProcessInfo.processInfo.environment[@"WDA_REALTIME_TOUCH_DEBUG"];
  NSString *normalized = value.lowercaseString;
  return [normalized isEqualToString:@"1"] ||
    [normalized isEqualToString:@"true"] ||
    [normalized isEqualToString:@"yes"] ||
    [normalized isEqualToString:@"on"];
}

static double FBRealtimeControlWallClockMs(void)
{
  return NSDate.date.timeIntervalSince1970 * 1000.0;
}

static NSString *FBRealtimeControlNormalizeType(NSString *type)
{
  NSString *normalized = [type.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *compact = [[normalized stringByReplacingOccurrencesOfString:@"-" withString:@""]
                       stringByReplacingOccurrencesOfString:@"_" withString:@""];
  if ([compact isEqualToString:@"touchdown"] ||
      [compact isEqualToString:@"pointerdown"] ||
      [compact isEqualToString:@"touch1down"] ||
      [compact isEqualToString:@"touchbegin"] ||
      [compact isEqualToString:@"begin"] ||
      [compact isEqualToString:@"down"]) {
    return @"down";
  }
  if ([compact isEqualToString:@"touchmove"] ||
      [compact isEqualToString:@"pointermove"] ||
      [compact isEqualToString:@"touch1move"] ||
      [compact isEqualToString:@"move"]) {
    return @"move";
  }
  if ([compact isEqualToString:@"touchup"] ||
      [compact isEqualToString:@"pointerup"] ||
      [compact isEqualToString:@"touch1up"] ||
      [compact isEqualToString:@"touchend"] ||
      [compact isEqualToString:@"end"] ||
      [compact isEqualToString:@"up"]) {
    return @"up";
  }
  if ([compact isEqualToString:@"touchcancel"] ||
      [compact isEqualToString:@"pointercancel"] ||
      [compact isEqualToString:@"cancel"]) {
    return @"cancel";
  }
  if ([compact isEqualToString:@"hidprobe"] ||
      [compact isEqualToString:@"hidstatus"]) {
    return @"hidprobe";
  }
  if ([compact isEqualToString:@"pointarray"]) {
    return @"pointarray";
  }
  return normalized;
}

@interface FBRealtimeControlClientState : NSObject
@property (nonatomic, assign) BOOL authenticated;
@property (nonatomic, assign) BOOL ownsTouch;
@property (nonatomic, assign) BOOL hasLastPoint;
@property (nonatomic, assign) NSUInteger pointerId;
@property (nonatomic, assign) double lastX;
@property (nonatomic, assign) double lastY;
@property (nonatomic, assign) uint64_t lastSequence;
@property (nonatomic, assign) double lastTimestamp;
@end

@implementation FBRealtimeControlClientState
@end

@interface FBRealtimeControlServer ()
@property (nonatomic, strong) NSMutableDictionary<NSValue *, FBRealtimeControlClientState *> *clientStates;
@property (nonatomic, weak) GCDAsyncSocket *touchOwner;
@property (nonatomic, weak) GCDAsyncSocket *currentClient;
@property (nonatomic, strong) FBRealtimeControlClientState *currentState;
@property (nonatomic, strong) NSDictionary *pendingResponse;
@end

@implementation FBRealtimeControlServer

- (instancetype)init
{
  if ((self = [super init])) {
    _clientStates = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)stop
{
  [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
  self.touchOwner = nil;
  @synchronized (self.clientStates) {
    [self.clientStates removeAllObjects];
  }
}

- (FBRealtimeControlClientState *)stateForClient:(GCDAsyncSocket *)client createIfNeeded:(BOOL)createIfNeeded
{
  NSValue *key = [NSValue valueWithNonretainedObject:client];
  @synchronized (self.clientStates) {
    FBRealtimeControlClientState *state = self.clientStates[key];
    if (nil == state && createIfNeeded) {
      state = [FBRealtimeControlClientState new];
      self.clientStates[key] = state;
    }
    return state;
  }
}

- (void)removeStateForClient:(GCDAsyncSocket *)client
{
  NSValue *key = [NSValue valueWithNonretainedObject:client];
  @synchronized (self.clientStates) {
    [self.clientStates removeObjectForKey:key];
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"Realtime control client connected at %@:%d", newClient.connectedHost, newClient.connectedPort];
  [self stateForClient:newClient createIfNeeded:YES];
  [newClient readDataToData:[GCDAsyncSocket LFData]
                withTimeout:-1
                   maxLength:FBRealtimeControlMaxLineLength
                        tag:0];
}

- (void)didClient:(GCDAsyncSocket *)client didReadData:(NSData *)data
{
  FBRealtimeControlClientState *state = [self stateForClient:client createIfNeeded:YES];
  [client readDataToData:[GCDAsyncSocket LFData]
            withTimeout:-1
               maxLength:FBRealtimeControlMaxLineLength
                    tag:0];

  NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (line.length == 0) {
    return;
  }
  line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (line.length == 0) {
    return;
  }

  NSError *error = nil;
  NSDictionary *payload = [self decodeLine:line error:&error];
  if (nil == payload) {
    [self sendResponse:@{
      @"ok": @NO,
      @"error": error.localizedDescription ?: @"Invalid control payload",
    } toClient:client];
    return;
  }

  double serverReceiveTimestamp = FBRealtimeControlWallClockMs();
  if (FBRealtimeControlDebugEnabled()) {
    NSString *typeForLog = [payload[@"type"] isKindOfClass:NSString.class] ? FBRealtimeControlNormalizeType(payload[@"type"]) : @"?";
    [FBLogger logFmt:@"[RT INPUT] stage=ws-recv type=%@ seq=%@ pointerId=%@ x=%@ y=%@ clientTs=%@ nodeRecvTs=%@ nodeForwardTs=%@ wdaRecvTs=%.3f",
      typeForLog ?: @"?",
      payload[@"sequence"] ?: payload[@"seq"] ?: @"-",
      payload[@"pointerId"] ?: payload[@"finger"] ?: payload[@"pointer"] ?: @"-",
      payload[@"x"] ?: @"-",
      payload[@"y"] ?: @"-",
      payload[@"timestamp"] ?: @"-",
      payload[@"serverReceiveTimestamp"] ?: @"-",
      payload[@"serverForwardTimestamp"] ?: @"-",
      serverReceiveTimestamp];
  }
  NSMutableDictionary *payloadWithReceiveTs = [payload mutableCopy];
  payloadWithReceiveTs[@"wdaReceiveTimestamp"] = @(serverReceiveTimestamp);

  BOOL requiresAuth = FBConfiguration.requiresAuthentication;
  if (!state.authenticated && requiresAuth) {
    if (![self authorizePayload:payloadWithReceiveTs error:&error]) {
      [self sendResponse:@{
        @"type": @"auth",
        @"ok": @NO,
        @"error": error.localizedDescription ?: @"Authentication failed",
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    state.authenticated = YES;
    [self sendResponse:@{ @"type": @"auth", @"ok": @YES } toClient:client];
    return;
  }
  state.authenticated = YES;

  NSString *type = [payload[@"type"] isKindOfClass:NSString.class]
    ? FBRealtimeControlNormalizeType(payload[@"type"])
    : nil;
  if (type.length == 0) {
    type = @"pointarray";
  }

  if ([type isEqualToString:@"auth"]) {
    [self sendResponse:@{ @"type": @"auth", @"ok": @YES } toClient:client];
    return;
  }

  if ([type isEqualToString:@"ping"]) {
    [self sendResponse:@{ @"type": @"pong", @"ok": @YES, @"is_trollstore": @YES } toClient:client];
    return;
  }

  self.currentClient = client;
  self.currentState = state;
  self.pendingResponse = nil;

  __block NSError *executeError = nil;
  __block BOOL ok = NO;
  // Mirror the sign build: XCTest-backed gesture execution needs the main queue.
  dispatch_sync(dispatch_get_main_queue(), ^{
    ok = [self executePayload:payloadWithReceiveTs type:type error:&executeError];
  });
  NSDictionary *customResponse = self.pendingResponse;
  self.pendingResponse = nil;
  self.currentClient = nil;
  self.currentState = nil;

  if (customResponse != nil) {
    NSMutableDictionary *response = [customResponse mutableCopy];
    if (payload[@"id"] != nil && response[@"id"] == nil) {
      response[@"id"] = payload[@"id"];
    }
    [self sendResponse:response toClient:client];
    return;
  }

  BOOL shouldAck = ![type isEqualToString:@"move"] || [payload[@"ack"] boolValue] || [NSProcessInfo.processInfo.environment[@"WDA_REALTIME_TOUCH_ACK_MOVES"] boolValue];
  NSString *message = (!ok && nil != executeError) ? executeError.localizedDescription : nil;

  if (!ok) {
    [self sendResponse:@{
      @"ok": @NO,
      @"type": type,
      @"error": message ?: @"Command failed",
      @"id": payload[@"id"] ?: [NSNull null],
    } toClient:client];
    return;
  }

  if (shouldAck) {
    [self sendResponse:@{
      @"ok": @YES,
      @"type": type,
      @"id": payload[@"id"] ?: [NSNull null],
    } toClient:client];
  }
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  FBRealtimeControlClientState *state = [self stateForClient:client createIfNeeded:NO];
  if (state.ownsTouch || self.touchOwner == client) {
    [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
    self.touchOwner = nil;
  }
  [self removeStateForClient:client];
  [FBLogger log:@"Disconnected a client from realtime control socket"];
}

- (nullable NSDictionary *)decodeLine:(NSString *)line error:(NSError **)error
{
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (0 == data.length) {
    return nil;
  }
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if ([object isKindOfClass:NSDictionary.class]) {
    return (NSDictionary *)object;
  }
  if ([object isKindOfClass:NSString.class]) {
    return @{ @"type": @"auth", @"token": object };
  }
  if ([object isKindOfClass:NSArray.class]) {
    return @{ @"type": @"pointArray", @"pointArray": object };
  }
  if (nil != error && nil == *error) {
    *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                 code:400
                             userInfo:@{ NSLocalizedDescriptionKey: @"Unsupported control payload" }];
  }
  return nil;
}

- (BOOL)authorizePayload:(NSDictionary *)payload error:(NSError **)error
{
  if (!FBConfiguration.requiresAuthentication) {
    return YES;
  }

  NSString *token =
    NSProcessInfo.processInfo.environment[@"WDA_AUTH_TOKEN"]
    ?: NSProcessInfo.processInfo.environment[@"WEBDRIVERAGENT_AUTH_TOKEN"]
    ?: @"";
  if (token.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:401
                               userInfo:@{ NSLocalizedDescriptionKey: @"WDA auth token is required" }];
    }
    return NO;
  }

  id candidate = payload[@"token"] ?: payload[@"auth"] ?: payload[@"authorization"];
  if (![candidate isKindOfClass:NSString.class]) {
    candidate = [candidate description];
  }
  NSString *value = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([value.lowercaseString hasPrefix:@"bearer "]) {
    value = [[value substringFromIndex:@"Bearer ".length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  }

  NSData *left = [token dataUsingEncoding:NSUTF8StringEncoding];
  NSData *right = [value dataUsingEncoding:NSUTF8StringEncoding];
  if (left.length != right.length) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:401
                               userInfo:@{ NSLocalizedDescriptionKey: @"Authentication failed" }];
    }
    return NO;
  }
  const uint8_t *leftBytes = left.bytes;
  const uint8_t *rightBytes = right.bytes;
  uint8_t diff = 0;
  for (NSUInteger idx = 0; idx < left.length; idx++) {
    diff |= leftBytes[idx] ^ rightBytes[idx];
  }
  if (diff != 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:401
                               userInfo:@{ NSLocalizedDescriptionKey: @"Authentication failed" }];
    }
    return NO;
  }
  return YES;
}

- (BOOL)executePayload:(NSDictionary *)payload type:(NSString *)type error:(NSError **)error
{
  if ([type isEqualToString:@"tap"]) {
    return [self handleTapPayload:payload error:error];
  }
  if ([type isEqualToString:@"button"]) {
    return [self handleButtonPayload:payload error:error];
  }
  if ([type isEqualToString:@"home"]) {
    return [[XCUIDevice sharedDevice] fb_goToHomescreenWithError:error];
  }
  if ([type isEqualToString:@"swipe"]) {
    return [self handleSwipePayload:payload error:error];
  }
  if ([type isEqualToString:@"pointarray"] || [type isEqualToString:@"gesture"]) {
    return [self handlePointArrayPayload:payload error:error];
  }
  if ([type isEqualToString:@"touchdown"] || [type isEqualToString:@"down"]) {
    return [self handleTouchDownPayload:payload error:error];
  }
  if ([type isEqualToString:@"touchmove"] || [type isEqualToString:@"move"]) {
    return [self handleTouchMovePayload:payload error:error];
  }
  if ([type isEqualToString:@"touchup"] || [type isEqualToString:@"up"]) {
    return [self handleTouchUpPayload:payload error:error];
  }
  if ([type isEqualToString:@"touchcancel"] || [type isEqualToString:@"cancel"]) {
    return [self handleTouchCancelPayload:payload error:error];
  }
  if ([type isEqualToString:@"hidprobe"]) {
    return [self handleHidProbePayload:payload error:error];
  }
  if (error) {
    *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                 code:400
                             userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unsupported control type: %@", type] }];
  }
  return NO;
}

- (BOOL)handleTouchDownPayload:(NSDictionary *)payload error:(NSError **)error
{
  NSNumber *x = [payload[@"x"] isKindOfClass:NSNumber.class] ? payload[@"x"] : nil;
  NSNumber *y = [payload[@"y"] isKindOfClass:NSNumber.class] ? payload[@"y"] : nil;
  NSNumber *pointerId = [payload[@"pointerId"] isKindOfClass:NSNumber.class] ? payload[@"pointerId"] : nil;
  NSNumber *sequence = [payload[@"sequence"] isKindOfClass:NSNumber.class] ? payload[@"sequence"] : nil;
  NSNumber *clientTimestamp = [payload[@"timestamp"] isKindOfClass:NSNumber.class] ? payload[@"timestamp"] : nil;
  if (nil == x || nil == y) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"touchDown requires x and y" }];
    }
    return NO;
  }
  if (self.touchOwner != nil && self.touchOwner != self.currentClient) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:409
                               userInfo:@{ NSLocalizedDescriptionKey: @"Another client currently owns the active touch" }];
    }
    return NO;
  }
  BOOL ok = [[XCUIDevice sharedDevice] fb_realtimeTouchDownAtX:(CGFloat)x.doubleValue
                                                              y:(CGFloat)y.doubleValue
                                                      pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : 1
                                                       sequence:sequence
                                                clientTimestamp:clientTimestamp
                                                          error:error];
  if (ok) {
    FBRealtimeControlClientState *state = self.currentState ?: [self stateForClient:self.currentClient createIfNeeded:YES];
    state.ownsTouch = YES;
    state.hasLastPoint = YES;
    state.pointerId = pointerId != nil ? pointerId.unsignedIntegerValue : 1;
    state.lastX = x.doubleValue;
    state.lastY = y.doubleValue;
    state.lastSequence = sequence != nil ? sequence.unsignedLongLongValue : 0;
    state.lastTimestamp = clientTimestamp != nil ? clientTimestamp.doubleValue : 0;
    self.touchOwner = self.currentClient;
  }
  return ok;
}

- (BOOL)handleTouchMovePayload:(NSDictionary *)payload error:(NSError **)error
{
  FBRealtimeControlClientState *state = self.currentState ?: [self stateForClient:self.currentClient createIfNeeded:NO];
  if (self.touchOwner != self.currentClient || !state.ownsTouch) {
    [FBLogger verboseLog:@"Ignoring realtime touch move without an active owner"];
    return YES;
  }

  NSNumber *x = [payload[@"x"] isKindOfClass:NSNumber.class] ? payload[@"x"] : nil;
  NSNumber *y = [payload[@"y"] isKindOfClass:NSNumber.class] ? payload[@"y"] : nil;
  NSNumber *pointerId = [payload[@"pointerId"] isKindOfClass:NSNumber.class] ? payload[@"pointerId"] : nil;
  NSNumber *sequence = [payload[@"sequence"] isKindOfClass:NSNumber.class] ? payload[@"sequence"] : nil;
  NSNumber *clientTimestamp = [payload[@"timestamp"] isKindOfClass:NSNumber.class] ? payload[@"timestamp"] : nil;
  if (nil == x || nil == y) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"touchMove requires x and y" }];
    }
    return NO;
  }
  if (sequence != nil && sequence.unsignedLongLongValue < state.lastSequence) {
    return YES;
  }
  BOOL ok = [[XCUIDevice sharedDevice] fb_realtimeTouchMoveAtX:(CGFloat)x.doubleValue
                                                             y:(CGFloat)y.doubleValue
                                                     pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : state.pointerId
                                                      sequence:sequence
                                                clientTimestamp:clientTimestamp
                                                         error:error];
  if (ok) {
    state.hasLastPoint = YES;
    state.pointerId = pointerId != nil ? pointerId.unsignedIntegerValue : state.pointerId;
    state.lastX = x.doubleValue;
    state.lastY = y.doubleValue;
    state.lastSequence = sequence != nil ? sequence.unsignedLongLongValue : state.lastSequence + 1;
    state.lastTimestamp = clientTimestamp != nil ? clientTimestamp.doubleValue : state.lastTimestamp;
  }
  return ok;
}

- (BOOL)handleTouchUpPayload:(NSDictionary *)payload error:(NSError **)error
{
  FBRealtimeControlClientState *state = self.currentState ?: [self stateForClient:self.currentClient createIfNeeded:NO];
  if (self.touchOwner != self.currentClient || !state.ownsTouch) {
    [FBLogger verboseLog:@"Ignoring realtime touch up without an active owner"];
    return YES;
  }

  NSNumber *x = [payload[@"x"] isKindOfClass:NSNumber.class] ? payload[@"x"] : @(state.lastX);
  NSNumber *y = [payload[@"y"] isKindOfClass:NSNumber.class] ? payload[@"y"] : @(state.lastY);
  NSNumber *pointerId = [payload[@"pointerId"] isKindOfClass:NSNumber.class] ? payload[@"pointerId"] : nil;
  NSNumber *sequence = [payload[@"sequence"] isKindOfClass:NSNumber.class] ? payload[@"sequence"] : nil;
  NSNumber *clientTimestamp = [payload[@"timestamp"] isKindOfClass:NSNumber.class] ? payload[@"timestamp"] : nil;
  BOOL ok = [[XCUIDevice sharedDevice] fb_realtimeTouchUpAtX:(CGFloat)x.doubleValue
                                                            y:(CGFloat)y.doubleValue
                                                    pointerId:pointerId != nil ? pointerId.unsignedIntegerValue : state.pointerId
                                                      sequence:sequence
                                               clientTimestamp:clientTimestamp
                                                         error:error];
  if (ok) {
    state.ownsTouch = NO;
    state.hasLastPoint = NO;
    state.pointerId = 0;
    state.lastSequence = sequence != nil ? sequence.unsignedLongLongValue : state.lastSequence + 1;
    state.lastTimestamp = clientTimestamp != nil ? clientTimestamp.doubleValue : state.lastTimestamp;
    self.touchOwner = nil;
  }
  return ok;
}

- (BOOL)handleTouchCancelPayload:(NSDictionary *)payload error:(NSError **)error
{
  (void)payload;
  if (self.touchOwner == nil) {
    [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
    return YES;
  }
  FBRealtimeControlClientState *state = self.currentState ?: [self stateForClient:self.currentClient createIfNeeded:NO];
  if (state.ownsTouch || self.touchOwner == self.currentClient) {
    [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
    state.ownsTouch = NO;
    state.hasLastPoint = NO;
    state.pointerId = 0;
    self.touchOwner = nil;
    return YES;
  }
  [FBLogger verboseLog:@"Ignoring realtime touch cancel without ownership"];
  return YES;
}

- (BOOL)handleHidProbePayload:(NSDictionary *)payload error:(NSError **)error
{
  (void)error;
  CGFloat x = 0;
  CGFloat y = 0;
  if ([payload[@"x"] isKindOfClass:NSNumber.class]) {
    x = [payload[@"x"] doubleValue];
  }
  if ([payload[@"y"] isKindOfClass:NSNumber.class]) {
    y = [payload[@"y"] doubleValue];
  }
  NSDictionary *status = [[XCUIDevice sharedDevice] fb_realtimeHIDStatusWithDispatchProbe:[payload[@"dispatch"] boolValue]
                                                                                         x:x
                                                                                         y:y];
  self.pendingResponse = @{
    @"ok": @YES,
    @"type": @"hidProbe",
    @"status": status ?: @{},
  };
  return YES;
}

- (BOOL)handleTapPayload:(NSDictionary *)payload error:(NSError **)error
{
  NSNumber *x = [payload[@"x"] isKindOfClass:NSNumber.class] ? payload[@"x"] : nil;
  NSNumber *y = [payload[@"y"] isKindOfClass:NSNumber.class] ? payload[@"y"] : nil;
  NSNumber *duration = [payload[@"duration"] isKindOfClass:NSNumber.class] ? payload[@"duration"] : nil;
  if (nil == x || nil == y) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"Tap requires x and y" }];
    }
    return NO;
  }
  return [[XCUIDevice sharedDevice] fb_synthTapWithX:(CGFloat)x.doubleValue
                                                   y:(CGFloat)y.doubleValue
                                            duration:duration];
}

- (BOOL)handleSwipePayload:(NSDictionary *)payload error:(NSError **)error
{
  NSArray *points = payload[@"pointArray"] ?: payload[@"points"];
  if ([points isKindOfClass:NSArray.class] && points.count >= 2) {
    return [self handlePointArrayPayload:payload error:error];
  }

  NSNumber *fromX = [payload[@"fromX"] isKindOfClass:NSNumber.class] ? payload[@"fromX"] : nil;
  NSNumber *fromY = [payload[@"fromY"] isKindOfClass:NSNumber.class] ? payload[@"fromY"] : nil;
  NSNumber *toX = [payload[@"toX"] isKindOfClass:NSNumber.class] ? payload[@"toX"] : nil;
  NSNumber *toY = [payload[@"toY"] isKindOfClass:NSNumber.class] ? payload[@"toY"] : nil;
  NSNumber *duration = [payload[@"duration"] isKindOfClass:NSNumber.class] ? payload[@"duration"] : nil;
  if (nil == fromX || nil == fromY || nil == toX || nil == toY) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"Swipe requires fromX, fromY, toX and toY" }];
    }
    return NO;
  }
  return [[XCUIDevice sharedDevice] fb_synthSwipe:(CGFloat)fromX.doubleValue
                                            fromY:(CGFloat)fromY.doubleValue
                                              toX:(CGFloat)toX.doubleValue
                                              toY:(CGFloat)toY.doubleValue
                                            delay:duration];
}

- (BOOL)handlePointArrayPayload:(NSDictionary *)payload error:(NSError **)error
{
  NSArray *points = nil;
  id rawPoints = payload[@"pointArray"] ?: payload[@"points"] ?: payload[@"path"] ?: payload[@"data"];
  if ([rawPoints isKindOfClass:NSArray.class]) {
    points = rawPoints;
  }
  if (points.count < 2) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"pointArray requires at least 2 points" }];
    }
    return NO;
  }

  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *secret = env[@"SOLUMATE_WDA_SWIPE_SECRET"];
  if (secret.length > 0) {
    NSString *st = [payload[@"st"] isKindOfClass:NSString.class] ? payload[@"st"] : nil;
    if (![self validatePointArray:points st:st secret:secret]) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                     code:401
                                 userInfo:@{ NSLocalizedDescriptionKey: @"Invalid pointArray signature" }];
      }
      return NO;
    }
  }

  return [[XCUIDevice sharedDevice] fb_qx9:points];
}

- (BOOL)validatePointArray:(NSArray *)points st:(NSString *)st secret:(NSString *)secret
{
  if (points.count < 2 || st.length == 0 || secret.length == 0) {
    return NO;
  }
  NSArray<NSString *> *parts = [st componentsSeparatedByString:@"."];
  if (parts.count != 2) {
    return NO;
  }

  NSNumberFormatter *formatter = [NSNumberFormatter new];
  formatter.numberStyle = NSNumberFormatterDecimalStyle;
  NSString *timestampString = parts.firstObject ?: @"";
  NSNumber *timestamp = [formatter numberFromString:timestampString];
  if (nil == timestamp) {
    return NO;
  }
  if (fabs([NSDate date].timeIntervalSince1970 - timestamp.doubleValue) > 30.0) {
    return NO;
  }

  NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:points.count];
  for (id rawPoint in points) {
    NSArray *item = nil;
    if ([rawPoint isKindOfClass:NSArray.class]) {
      item = rawPoint;
    } else if ([rawPoint isKindOfClass:NSDictionary.class]) {
      NSDictionary *dict = rawPoint;
      id x = dict[@"x"] ?: dict[@"X"];
      id y = dict[@"y"] ?: dict[@"Y"];
      id t = dict[@"t"] ?: dict[@"time"] ?: dict[@"timestamp"] ?: dict[@"delay"] ?: dict[@"duration"];
      item = @[
        [x isKindOfClass:NSNumber.class] ? x : @([x doubleValue]),
        [y isKindOfClass:NSNumber.class] ? y : @([y doubleValue]),
        [t isKindOfClass:NSNumber.class] ? t : @([t doubleValue]),
      ];
    }
    if (item.count < 2) {
      return NO;
    }
    double x = [item[0] doubleValue];
    double y = [item[1] doubleValue];
      double t = item.count > 2 ? [item[2] doubleValue] : 0;
      [rows addObject:[NSString stringWithFormat:@"%.6f,%.6f,%.6f", x, y, t]];
  }

  NSString *message = [NSString stringWithFormat:@"%@\n%@", parts.firstObject, [rows componentsJoinedByString:@";"]];
  NSData *secretData = [secret dataUsingEncoding:NSUTF8StringEncoding];
  NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
  CCHmac(kCCHmacAlgSHA256,
         secretData.bytes,
         secretData.length,
         messageData.bytes,
         messageData.length,
         digest);
  NSMutableString *signature = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger idx = 0; idx < CC_SHA256_DIGEST_LENGTH; idx++) {
    [signature appendFormat:@"%02x", digest[idx]];
  }
  NSString *expectedSignature = parts.lastObject ?: @"";
  return [signature isEqualToString:expectedSignature];
}

- (BOOL)handleButtonPayload:(NSDictionary *)payload error:(NSError **)error
{
  NSString *button = [payload[@"name"] isKindOfClass:NSString.class] ? payload[@"name"] : nil;
  NSNumber *duration = [payload[@"duration"] isKindOfClass:NSNumber.class] ? payload[@"duration"] : nil;
  if (button.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.facebook.WebDriverAgent.RealtimeControl"
                                   code:400
                               userInfo:@{ NSLocalizedDescriptionKey: @"Button requires name" }];
    }
    return NO;
  }
  return [[XCUIDevice sharedDevice] fb_pressButton:button forDuration:duration error:error];
}

- (void)sendResponse:(NSDictionary *)payload toClient:(GCDAsyncSocket *)client
{
  if (nil == client) {
    return;
  }
  NSMutableDictionary *response = [payload mutableCopy];
  id requestId = response[@"id"];
  if (nil == requestId || requestId == NSNull.null) {
    [response removeObjectForKey:@"id"];
  }
  NSError *error = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:&error];
  if (nil == json) {
    NSString *fallback = @"{\"ok\":false,\"error\":\"Cannot encode response\"}\n";
    [client writeData:[fallback dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:0];
    return;
  }
  NSMutableData *data = [json mutableCopy];
  [data appendData:[GCDAsyncSocket LFData]];
  [client writeData:data withTimeout:-1 tag:0];
}

@end
