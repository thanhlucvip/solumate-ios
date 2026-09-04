/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMjpegServer.h"

#import <mach/mach_time.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"
#import "XCUIScreen.h"

static const NSUInteger MAX_FPS = 60;
static const NSTimeInterval FRAME_TIMEOUT = 1.;
static const NSTimeInterval FAILURE_BACKOFF_MIN = 1.0;
static const NSTimeInterval FAILURE_BACKOFF_MAX = 10.0;

static NSString *const SERVER_NAME = @"WDA MJPEG Server";
static const char *QUEUE_NAME = "JPEG Screenshots Provider Queue";


@interface FBMjpegServer()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) FBImageProcessor *imageProcessor;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, assign) NSUInteger consecutiveScreenshotFailures;
@property (nonatomic, assign) NSTimeInterval frameTimeout;
@property (atomic, assign) BOOL isStreaming;
@property (atomic, assign) BOOL isProcessingFrame;

@end

static NSTimeInterval FBMjpegEnvTimeInterval(NSString *name, NSTimeInterval fallback, NSTimeInterval minValue, NSTimeInterval maxValue)
{
  NSString *raw = NSProcessInfo.processInfo.environment[name];
  if (0 == raw.length) {
    return fallback;
  }
  NSTimeInterval parsed = raw.doubleValue;
  if (parsed <= 0) {
    return fallback;
  }
  return MIN(MAX(parsed, minValue), maxValue);
}

@implementation FBMjpegServer

- (instancetype)init
{
  if ((self = [super init])) {
    _isStreaming = YES;
    _isProcessingFrame = NO;
    _consecutiveScreenshotFailures = 0;
    _listeningClients = [NSMutableArray array];
    _frameTimeout = FBMjpegEnvTimeInterval(@"MJPEG_FRAME_TIMEOUT", FRAME_TIMEOUT, 0.1, 5.0);
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    dispatch_async(_backgroundQueue, ^{
      [self streamScreenshot];
    });
    _imageProcessor = [[FBImageProcessor alloc] init];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    [FBLogger logFmt:@"MJPEG stream configured: %@ fps, scale %.0f, quality %@, fix orientation %@, timeout %.2fs",
     @(FBConfiguration.mjpegServerFramerate),
     FBConfiguration.mjpegScalingFactor,
     @(FBConfiguration.mjpegServerScreenshotQuality),
     FBConfiguration.mjpegShouldFixOrientation ? @"YES" : @"NO",
     self.frameTimeout];
  }
  return self;
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = timerInterval - timeElapsed;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  } else {
    // Try to do our best to keep the FPS at a decent level
    dispatch_async(self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  }
}

- (void)streamScreenshot
{
  if (!self.isStreaming) {
    return;
  }
  NSUInteger framerate = FBConfiguration.mjpegServerFramerate;
  uint64_t timerInterval = (uint64_t)(1.0 / ((0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate) * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
  }

  if (self.isProcessingFrame) {
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }
  self.isProcessingFrame = YES;

  NSError *error;
  CGFloat compressionQuality = MAX(FBMinCompressionQuality,
                                   MIN(FBMaxCompressionQuality, FBConfiguration.mjpegServerScreenshotQuality / 100.0));
  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                           compressionQuality:compressionQuality
                                                                          uti:UTTypeJPEG
                                                                      timeout:self.frameTimeout
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"%@", error.description];
    self.isProcessingFrame = NO;
    self.consecutiveScreenshotFailures++;
    NSTimeInterval backoffSeconds = MIN(FAILURE_BACKOFF_MAX,
                                        FAILURE_BACKOFF_MIN * (1 << MIN(self.consecutiveScreenshotFailures, 4)));
    uint64_t backoffInterval = (uint64_t)(backoffSeconds * NSEC_PER_SEC);
    [self scheduleNextScreenshotWithInterval:backoffInterval timeStarted:timeStarted];
    return;
  }

  self.consecutiveScreenshotFailures = 0;

  CGFloat scalingFactor = FBConfiguration.mjpegScalingFactor / 100.0;
  [self.imageProcessor submitImageData:screenshotData
                         scalingFactor:scalingFactor
                     completionHandler:^(NSData * _Nonnull scaled) {
    [self sendScreenshot:scaled];
    self.isProcessingFrame = NO;
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
  }];
}

- (void)sendScreenshot:(NSData *)screenshotData {
  if (!self.isStreaming) {
    return;
  }
  NSString *chunkHeader = [NSString stringWithFormat:@"--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: %@\r\n\r\n", @(screenshotData.length)];
  NSMutableData *chunk = [[chunkHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [chunk appendData:screenshotData];
  [chunk appendData:(id)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  @synchronized (self.listeningClients) {
    for (GCDAsyncSocket *client in self.listeningClients) {
      [client writeData:chunk withTimeout:-1 tag:0];
    }
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"Got screenshots broadcast client connection at %@:%d", newClient.connectedHost, newClient.connectedPort];
  // Start broadcast only after there is any data from the client
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClient:(GCDAsyncSocket *)client didReadData:(NSData *)data
{
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
  }

  if (![FBConfiguration isStreamHandshakeAuthorized:data]) {
    [FBLogger logFmt:@"Rejected unauthorized MJPEG stream client at %@:%d", client.connectedHost, client.connectedPort];
    NSString *response = @"HTTP/1.0 401 Unauthorized\r\nConnection: close\r\nWWW-Authenticate: Bearer\r\n\r\n";
    [client writeData:(id)[response dataUsingEncoding:NSUTF8StringEncoding] withTimeout:1 tag:0];
    [client disconnectAfterWriting];
    return;
  }

  [FBLogger logFmt:@"Starting screenshots broadcast for the client at %@:%d", client.connectedHost, client.connectedPort];
  NSString *streamHeader = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nMax-Age: 0\r\nExpires: 0\r\nCache-Control: no-cache, private\r\nPragma: no-cache\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n", SERVER_NAME];
  [client writeData:(id)[streamHeader dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:0];
  @synchronized (self.listeningClients) {
    [self.listeningClients addObject:client];
  }
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"Disconnected a client from screenshots broadcast"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  self.isProcessingFrame = NO;
  @synchronized (self.listeningClients) {
    NSArray<GCDAsyncSocket *> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
  }
}

@end
