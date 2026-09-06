/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBRealtimeControlServer.h"

#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <math.h>

#import "FBConfiguration.h"
#import "FBLogger.h"
#import "XCUIDevice+FBHelpers.h"

static NSString * const FBRealtimeControlModeTrollStore = @"trollstore";
static NSString * const FBRealtimeControlModePointArray = @"pointarray";
static NSString * const FBRealtimeControlModeSwipe = @"swipe";

static NSString *FBRealtimeControlNormalizeMode(id rawMode, BOOL isTrollStoreBuild)
{
  if (![rawMode isKindOfClass:NSString.class]) {
    return isTrollStoreBuild ? FBRealtimeControlModeTrollStore : FBRealtimeControlModePointArray;
  }
  NSString *normalized = [[(NSString *)rawMode lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString *compact = [[[normalized stringByReplacingOccurrencesOfString:@"-" withString:@""]
                        stringByReplacingOccurrencesOfString:@"_" withString:@""]
                        stringByReplacingOccurrencesOfString:@" " withString:@""];
  if ([compact isEqualToString:@"trollstore"] || [compact isEqualToString:@"realtime"]) {
    return isTrollStoreBuild ? FBRealtimeControlModeTrollStore : FBRealtimeControlModePointArray;
  }
  if ([compact isEqualToString:@"swipe"] || [compact isEqualToString:@"swip"]) {
    return FBRealtimeControlModeSwipe;
  }
  return FBRealtimeControlModePointArray;
}

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

static const uint8_t FBRealtimeBinaryMagic[4] = {'R', 'C', 'B', '1'};
static const NSUInteger FBRealtimeBinaryHeaderLength = 10;
static const NSUInteger FBRealtimeBinaryMaxBodyLength = 1024 * 1024;
static NSString * const FBRealtimeBinaryErrorDomain = @"com.facebook.WebDriverAgent.RealtimeControlBinary";

static NSError *FBRealtimeBinaryError(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain:FBRealtimeBinaryErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"Invalid realtime control binary payload" }];
}

static BOOL FBRealtimeBinaryNumberIsBoolean(NSNumber *number)
{
  return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

static void FBRealtimeBinaryAppendByte(NSMutableData *data, uint8_t value)
{
  [data appendBytes:&value length:1];
}

static void FBRealtimeBinaryAppendUInt32(NSMutableData *data, uint32_t value)
{
  uint32_t be = CFSwapInt32HostToBig(value);
  [data appendBytes:&be length:sizeof(be)];
}

static void FBRealtimeBinaryAppendInt32(NSMutableData *data, int32_t value)
{
  uint32_t be = CFSwapInt32HostToBig((uint32_t)value);
  [data appendBytes:&be length:sizeof(be)];
}

static void FBRealtimeBinaryAppendDouble(NSMutableData *data, double value)
{
  union {
    double d;
    uint64_t u;
  } bits;
  bits.d = value;
  uint64_t be = CFSwapInt64HostToBig(bits.u);
  [data appendBytes:&be length:sizeof(be)];
}

static BOOL FBRealtimeBinaryReadByte(NSData *data, NSUInteger *offset, uint8_t *value, NSError **error)
{
  if (*offset >= data.length) {
    if (error) {
      *error = FBRealtimeBinaryError(400, @"Realtime control binary payload is truncated");
    }
    return NO;
  }
  const uint8_t *bytes = data.bytes;
  *value = bytes[*offset];
  *offset += 1;
  return YES;
}

static BOOL FBRealtimeBinaryReadUInt32(NSData *data, NSUInteger *offset, uint32_t *value, NSError **error)
{
  if (data.length < *offset + sizeof(uint32_t)) {
    if (error) {
      *error = FBRealtimeBinaryError(400, @"Realtime control binary payload is truncated");
    }
    return NO;
  }
  uint32_t be = 0;
  memcpy(&be, ((const uint8_t *)data.bytes) + *offset, sizeof(be));
  *value = CFSwapInt32BigToHost(be);
  *offset += sizeof(be);
  return YES;
}

static BOOL FBRealtimeBinaryReadInt32(NSData *data, NSUInteger *offset, int32_t *value, NSError **error)
{
  uint32_t raw = 0;
  if (!FBRealtimeBinaryReadUInt32(data, offset, &raw, error)) {
    return NO;
  }
  *value = (int32_t)raw;
  return YES;
}

static BOOL FBRealtimeBinaryReadDouble(NSData *data, NSUInteger *offset, double *value, NSError **error)
{
  if (data.length < *offset + sizeof(uint64_t)) {
    if (error) {
      *error = FBRealtimeBinaryError(400, @"Realtime control binary payload is truncated");
    }
    return NO;
  }
  uint64_t be = 0;
  memcpy(&be, ((const uint8_t *)data.bytes) + *offset, sizeof(be));
  union {
    double d;
    uint64_t u;
  } bits;
  bits.u = CFSwapInt64BigToHost(be);
  *value = bits.d;
  *offset += sizeof(be);
  return YES;
}

static BOOL FBRealtimeBinaryAvailable(NSData *data, NSUInteger offset, NSUInteger length, NSError **error)
{
  if (offset > data.length || length > data.length - offset) {
    if (error) {
      *error = FBRealtimeBinaryError(400, @"Realtime control binary payload is truncated");
    }
    return NO;
  }
  return YES;
}

static void FBRealtimeBinaryEncodeValue(id value, NSMutableData *data);
static id FBRealtimeBinaryDecodeValue(NSData *data, NSUInteger *offset, NSError **error);

static NSData *FBRealtimeBinaryEncodeFrame(id value, NSError **error)
{
  NSMutableData *body = [NSMutableData data];
  FBRealtimeBinaryEncodeValue(value, body);
  if (body.length > FBRealtimeBinaryMaxBodyLength) {
    if (error) {
      *error = FBRealtimeBinaryError(413, @"Realtime control payload is too large");
    }
    return nil;
  }

  NSMutableData *frame = [NSMutableData dataWithCapacity:FBRealtimeBinaryHeaderLength + body.length];
  [frame appendBytes:FBRealtimeBinaryMagic length:sizeof(FBRealtimeBinaryMagic)];
  uint8_t version = 1;
  uint8_t flags = 0;
  [frame appendBytes:&version length:1];
  [frame appendBytes:&flags length:1];
  FBRealtimeBinaryAppendUInt32(frame, (uint32_t)body.length);
  [frame appendData:body];
  return frame;
}

static void FBRealtimeBinaryEncodeValue(id value, NSMutableData *data)
{
  if (nil == value || value == NSNull.null) {
    FBRealtimeBinaryAppendByte(data, 0x00);
    return;
  }
  if ([value isKindOfClass:NSNumber.class]) {
    NSNumber *number = (NSNumber *)value;
    if (FBRealtimeBinaryNumberIsBoolean(number)) {
      FBRealtimeBinaryAppendByte(data, number.boolValue ? 0x02 : 0x01);
      return;
    }
    const char *type = number.objCType;
    if (type[0] == 'f' || type[0] == 'd' || type[0] == 'F' || type[0] == 'D') {
      FBRealtimeBinaryAppendByte(data, 0x04);
      FBRealtimeBinaryAppendDouble(data, number.doubleValue);
      return;
    }
    long long signedValue = number.longLongValue;
    if (signedValue >= INT32_MIN && signedValue <= INT32_MAX) {
      FBRealtimeBinaryAppendByte(data, 0x03);
      FBRealtimeBinaryAppendInt32(data, (int32_t)signedValue);
      return;
    }
    FBRealtimeBinaryAppendByte(data, 0x04);
    FBRealtimeBinaryAppendDouble(data, number.doubleValue);
    return;
  }
  if ([value isKindOfClass:NSString.class]) {
    NSData *encoded = [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding];
    FBRealtimeBinaryAppendByte(data, 0x05);
    FBRealtimeBinaryAppendUInt32(data, (uint32_t)encoded.length);
    [data appendData:encoded];
    return;
  }
  if ([value isKindOfClass:NSData.class]) {
    NSData *bytes = (NSData *)value;
    FBRealtimeBinaryAppendByte(data, 0x06);
    FBRealtimeBinaryAppendUInt32(data, (uint32_t)bytes.length);
    [data appendData:bytes];
    return;
  }
  if ([value isKindOfClass:NSArray.class]) {
    NSArray *array = (NSArray *)value;
    FBRealtimeBinaryAppendByte(data, 0x07);
    FBRealtimeBinaryAppendUInt32(data, (uint32_t)array.count);
    for (id item in array) {
      FBRealtimeBinaryEncodeValue(item, data);
    }
    return;
  }
  if ([value isKindOfClass:NSDictionary.class]) {
    NSDictionary *dictionary = (NSDictionary *)value;
    FBRealtimeBinaryAppendByte(data, 0x08);
    FBRealtimeBinaryAppendUInt32(data, (uint32_t)dictionary.count);
    for (id key in dictionary) {
      FBRealtimeBinaryEncodeValue([key description], data);
      FBRealtimeBinaryEncodeValue(dictionary[key], data);
    }
    return;
  }
  FBRealtimeBinaryEncodeValue([value description], data);
}

static id FBRealtimeBinaryDecodeValue(NSData *data, NSUInteger *offset, NSError **error)
{
  uint8_t type = 0;
  if (!FBRealtimeBinaryReadByte(data, offset, &type, error)) {
    return nil;
  }

  switch (type) {
    case 0x00:
      return NSNull.null;
    case 0x01:
      return @NO;
    case 0x02:
      return @YES;
    case 0x03: {
      int32_t value = 0;
      if (!FBRealtimeBinaryReadInt32(data, offset, &value, error)) {
        return nil;
      }
      return @(value);
    }
    case 0x04: {
      double value = 0;
      if (!FBRealtimeBinaryReadDouble(data, offset, &value, error)) {
        return nil;
      }
      return @(value);
    }
    case 0x05: {
      uint32_t length = 0;
      if (!FBRealtimeBinaryReadUInt32(data, offset, &length, error)) {
        return nil;
      }
      if (!FBRealtimeBinaryAvailable(data, *offset, length, error)) {
        return nil;
      }
      NSData *slice = [data subdataWithRange:NSMakeRange(*offset, length)];
      *offset += length;
      NSString *string = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
      if (nil == string) {
        if (error) {
          *error = FBRealtimeBinaryError(400, @"Realtime control binary string is not valid UTF-8");
        }
        return nil;
      }
      return string;
    }
    case 0x06: {
      uint32_t length = 0;
      if (!FBRealtimeBinaryReadUInt32(data, offset, &length, error)) {
        return nil;
      }
      if (!FBRealtimeBinaryAvailable(data, *offset, length, error)) {
        return nil;
      }
      NSData *slice = [data subdataWithRange:NSMakeRange(*offset, length)];
      *offset += length;
      return slice;
    }
    case 0x07: {
      uint32_t count = 0;
      if (!FBRealtimeBinaryReadUInt32(data, offset, &count, error)) {
        return nil;
      }
      NSMutableArray *array = [NSMutableArray arrayWithCapacity:count];
      for (uint32_t idx = 0; idx < count; idx++) {
        id item = FBRealtimeBinaryDecodeValue(data, offset, error);
        if (nil == item) {
          return nil;
        }
        [array addObject:item];
      }
      return array;
    }
    case 0x08: {
      uint32_t count = 0;
      if (!FBRealtimeBinaryReadUInt32(data, offset, &count, error)) {
        return nil;
      }
      NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:count];
      for (uint32_t idx = 0; idx < count; idx++) {
        id key = FBRealtimeBinaryDecodeValue(data, offset, error);
        if (nil == key) {
          return nil;
        }
        if (![key isKindOfClass:NSString.class]) {
          if (error) {
            *error = FBRealtimeBinaryError(400, @"Realtime control object key must be a string");
          }
          return nil;
        }
        id item = FBRealtimeBinaryDecodeValue(data, offset, error);
        if (nil == item) {
          return nil;
        }
        dictionary[key] = item;
      }
      return dictionary;
    }
    default:
      if (error) {
        *error = FBRealtimeBinaryError(400, [NSString stringWithFormat:@"Unsupported realtime control binary type 0x%02x", type]);
      }
      return nil;
  }
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
@property (nonatomic, assign) NSUInteger pendingBinaryBodyLength;
@end

@implementation FBRealtimeControlClientState
@end

@interface FBRealtimeControlServer ()
@property (nonatomic, strong) NSMutableDictionary<NSValue *, FBRealtimeControlClientState *> *clientStates;
@property (nonatomic, weak) GCDAsyncSocket *touchOwner;
@property (nonatomic, weak) GCDAsyncSocket *currentClient;
@property (nonatomic, strong) FBRealtimeControlClientState *currentState;
@property (nonatomic, strong) NSDictionary *pendingResponse;
@property (nonatomic, copy) NSString *controlMode;
@end

@implementation FBRealtimeControlServer

- (instancetype)init
{
  if ((self = [super init])) {
    _clientStates = [NSMutableDictionary dictionary];
    _controlMode = FBRealtimeControlModeTrollStore;
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
  FBRealtimeControlClientState *state = [self stateForClient:newClient createIfNeeded:YES];
  state.pendingBinaryBodyLength = 0;
  [newClient readDataToLength:FBRealtimeBinaryHeaderLength withTimeout:-1 tag:0];
}

- (void)didClient:(GCDAsyncSocket *)client didReadData:(NSData *)data
{
  FBRealtimeControlClientState *state = [self stateForClient:client createIfNeeded:YES];
  if (state.pendingBinaryBodyLength == 0) {
    NSError *error = nil;
    if (data.length != FBRealtimeBinaryHeaderLength) {
      [self sendResponse:@{
        @"type": @"error",
        @"ok": @NO,
        @"message": @"Invalid realtime control binary header",
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    if (memcmp(data.bytes, FBRealtimeBinaryMagic, sizeof(FBRealtimeBinaryMagic)) != 0) {
      [self sendResponse:@{
        @"type": @"error",
        @"ok": @NO,
        @"message": @"Invalid realtime control binary magic",
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    const uint8_t *bytes = data.bytes;
    if (bytes[4] != 1) {
      [self sendResponse:@{
        @"type": @"error",
        @"ok": @NO,
        @"message": [NSString stringWithFormat:@"Unsupported realtime control binary version %u", bytes[4]],
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    NSUInteger headerOffset = 6;
    uint32_t bodyLength32 = 0;
    if (!FBRealtimeBinaryReadUInt32(data, &headerOffset, &bodyLength32, &error)) {
      [self sendResponse:@{
        @"type": @"error",
        @"ok": @NO,
        @"message": error.localizedDescription ?: @"Invalid realtime control binary header",
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    if (bodyLength32 == 0 || bodyLength32 > FBRealtimeBinaryMaxBodyLength) {
      [self sendResponse:@{
        @"type": @"error",
        @"ok": @NO,
        @"message": @"Invalid realtime control binary body length",
      } toClient:client];
      [client disconnectAfterWriting];
      return;
    }
    state.pendingBinaryBodyLength = (NSUInteger)bodyLength32;
    [client readDataToLength:state.pendingBinaryBodyLength withTimeout:-1 tag:0];
    return;
  }

  NSUInteger bodyLength = state.pendingBinaryBodyLength;
  state.pendingBinaryBodyLength = 0;
  [client readDataToLength:FBRealtimeBinaryHeaderLength withTimeout:-1 tag:0];
  if (data.length != bodyLength) {
    [self sendResponse:@{
      @"type": @"error",
      @"ok": @NO,
      @"message": @"Invalid realtime control binary body length",
    } toClient:client];
    [client disconnectAfterWriting];
    return;
  }

  NSError *error = nil;
  NSUInteger offset = 0;
  id object = FBRealtimeBinaryDecodeValue(data, &offset, &error);
  if (nil == object || offset != data.length) {
    [self sendResponse:@{
      @"type": @"error",
      @"ok": @NO,
      @"message": error.localizedDescription ?: @"Invalid realtime control payload",
    } toClient:client];
    [client disconnectAfterWriting];
    return;
  }
  NSDictionary *payload = nil;
  if ([object isKindOfClass:NSDictionary.class]) {
    payload = (NSDictionary *)object;
  } else if ([object isKindOfClass:NSString.class]) {
    payload = @{ @"type": @"auth", @"token": object };
  } else if ([object isKindOfClass:NSArray.class]) {
    payload = @{ @"type": @"pointArray", @"pointArray": object };
  } else {
    [self sendResponse:@{
      @"type": @"error",
      @"ok": @NO,
      @"message": @"Unsupported realtime control payload",
    } toClient:client];
    [client disconnectAfterWriting];
    return;
  }

  double serverReceiveTimestamp = FBRealtimeControlWallClockMs();
  if (FBRealtimeControlDebugEnabled()) {
    NSString *typeForLog = [payload[@"type"] isKindOfClass:NSString.class] ? FBRealtimeControlNormalizeType(payload[@"type"]) : @"?";
    [FBLogger logFmt:@"[RT INPUT] stage=binary-recv type=%@ seq=%@ pointerId=%@ x=%@ y=%@ clientTs=%@ nodeRecvTs=%@ nodeForwardTs=%@ wdaRecvTs=%.3f",
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
    [self sendResponse:@{
      @"type": @"auth",
      @"ok": @YES,
      @"socket": @"socket-realtime-trollstore",
      @"mode": self.controlMode ?: FBRealtimeControlModeTrollStore,
      @"is_trollstore": @YES,
    } toClient:client];
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
    [self sendResponse:@{
      @"type": @"auth",
      @"ok": @YES,
      @"socket": @"socket-realtime-trollstore",
      @"mode": self.controlMode ?: FBRealtimeControlModeTrollStore,
      @"is_trollstore": @YES,
    } toClient:client];
    return;
  }

  if ([type isEqualToString:@"ping"]) {
    [self sendResponse:@{
      @"type": @"ready",
      @"ok": @YES,
      @"socket": @"socket-realtime-trollstore",
      @"source": @"tcp",
      @"authenticated": @(state.authenticated),
      @"is_trollstore": @YES,
      @"mode": self.controlMode ?: FBRealtimeControlModeTrollStore,
    } toClient:client];
    return;
  }

  if ([type isEqualToString:@"mode"] ||
      [type isEqualToString:@"setmode"] ||
      [type isEqualToString:@"controlmode"]) {
    [self handleModePayload:payload toClient:client];
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
      @"socket": @"socket-realtime-trollstore",
      @"mode": self.controlMode ?: FBRealtimeControlModeTrollStore,
      @"is_trollstore": @YES,
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

- (void)handleModePayload:(NSDictionary *)payload toClient:(GCDAsyncSocket *)client
{
  id rawMode = payload[@"mode"] ?: payload[@"controlMode"] ?: payload[@"value"];
  NSString *mode = FBRealtimeControlNormalizeMode(rawMode, YES);
  if (![mode isEqualToString:FBRealtimeControlModeTrollStore]) {
    [[XCUIDevice sharedDevice] fb_realtimeTouchCancel];
    self.touchOwner = nil;
    @synchronized (self.clientStates) {
      for (FBRealtimeControlClientState *state in self.clientStates.allValues) {
        state.ownsTouch = NO;
        state.hasLastPoint = NO;
        state.pointerId = 0;
      }
    }
  }
  self.controlMode = mode;
  [self sendResponse:@{
    @"type": @"mode",
    @"ok": @YES,
    @"mode": self.controlMode ?: FBRealtimeControlModeTrollStore,
    @"is_trollstore": @YES,
    @"id": payload[@"id"] ?: [NSNull null],
  } toClient:client];
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
  NSData *frame = FBRealtimeBinaryEncodeFrame(response, &error);
  if (nil == frame) {
    NSDictionary *fallback = @{
      @"type": @"error",
      @"ok": @NO,
      @"message": error.localizedDescription ?: @"Cannot encode response",
    };
    NSData *fallbackFrame = FBRealtimeBinaryEncodeFrame(fallback, nil);
    if (nil != fallbackFrame) {
      [client writeData:fallbackFrame withTimeout:-1 tag:0];
    }
    return;
  }
  [client writeData:frame withTimeout:-1 tag:0];
}

@end
