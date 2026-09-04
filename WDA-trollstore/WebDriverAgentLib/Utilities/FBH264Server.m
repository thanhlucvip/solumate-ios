/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBH264Server.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <mach/mach_time.h>
#import <VideoToolbox/VideoToolbox.h>
@import UniformTypeIdentifiers;

#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "GCDAsyncSocket.h"
#import "XCUIScreen.h"

static const NSUInteger H264_DEFAULT_FPS = 30;
static const NSUInteger H264_DEFAULT_BITRATE = 4000000;
static const NSUInteger H264_DEFAULT_GOP = 30;
static const NSUInteger H264_DEFAULT_MAX_WIDTH = 1600;
static const NSUInteger H264_DEFAULT_MAX_HEIGHT = 1600;
static const NSTimeInterval H264_FRAME_TIMEOUT = 1.0;
static const CGFloat H264_DEFAULT_SCREENSHOT_QUALITY = 0.7;

@interface FBH264Server ()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) long long mainScreenID;
@property (nonatomic, readonly) NSUInteger targetFps;
@property (nonatomic, readonly) NSUInteger targetBitrate;
@property (nonatomic, readonly) NSUInteger keyframeInterval;
@property (nonatomic, readonly) NSUInteger maxWidth;
@property (nonatomic, readonly) NSUInteger maxHeight;
@property (nonatomic, readonly) CGFloat screenshotQuality;
@property (atomic, assign) BOOL isStreaming;
@property (atomic, assign) BOOL forceKeyframe;
@property (nonatomic, assign) VTCompressionSessionRef session;
@property (nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic, assign) size_t encodedWidth;
@property (nonatomic, assign) size_t encodedHeight;
@property (nonatomic, assign) size_t pixelBufferPoolWidth;
@property (nonatomic, assign) size_t pixelBufferPoolHeight;
@property (nonatomic, assign) int64_t frameIndex;
@property (atomic, assign) BOOL isEncodingFrame;

- (void)sendAnnexB:(NSData *)data;

@end

static void FBH264OutputCallback(void *outputRefCon,
                                 void *sourceRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer);

static NSUInteger FBH264EnvInteger(NSString *name, NSUInteger fallback, NSUInteger minValue, NSUInteger maxValue)
{
  NSString *raw = NSProcessInfo.processInfo.environment[name];
  if (0 == raw.length) {
    return fallback;
  }
  NSInteger parsed = raw.integerValue;
  if (parsed <= 0) {
    return fallback;
  }
  return (NSUInteger)MIN(MAX(parsed, (NSInteger)minValue), (NSInteger)maxValue);
}

static CGFloat FBH264EnvQuality(NSString *name, CGFloat fallback)
{
  NSString *raw = NSProcessInfo.processInfo.environment[name];
  if (0 == raw.length) {
    return fallback;
  }
  CGFloat parsed = raw.doubleValue;
  if (parsed > 1.0) {
    parsed = parsed / 100.0;
  }
  return MAX(0.1, MIN(1.0, parsed));
}

@implementation FBH264Server

- (instancetype)init
{
  if ((self = [super init])) {
    _isStreaming = YES;
    _forceKeyframe = NO;
    _session = NULL;
    _pixelBufferPool = NULL;
    _encodedWidth = 0;
    _encodedHeight = 0;
    _pixelBufferPoolWidth = 0;
    _pixelBufferPoolHeight = 0;
    _frameIndex = 0;
    _isEncodingFrame = NO;
    _targetFps = FBH264EnvInteger(@"H264_FPS", H264_DEFAULT_FPS, 1, 60);
    _targetBitrate = FBH264EnvInteger(@"H264_BITRATE", H264_DEFAULT_BITRATE, 500000, 50000000);
    _keyframeInterval = FBH264EnvInteger(@"H264_GOP", H264_DEFAULT_GOP, 1, 240);
    _maxWidth = FBH264EnvInteger(@"H264_MAX_WIDTH", H264_DEFAULT_MAX_WIDTH, 0, 4096);
    _maxHeight = FBH264EnvInteger(@"H264_MAX_HEIGHT", H264_DEFAULT_MAX_HEIGHT, 0, 4096);
    _screenshotQuality = FBH264EnvQuality(@"H264_QUALITY", H264_DEFAULT_SCREENSHOT_QUALITY);
    _listeningClients = [NSMutableArray array];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
    dispatch_queue_attr_t attrs = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _backgroundQueue = dispatch_queue_create("H264 Screen Provider Queue", attrs);
    [FBLogger logFmt:@"H264 stream configured: %@ fps, %@ bps, gop %@, max %@x%@, screenshot quality %.2f",
     @(self.targetFps), @(self.targetBitrate), @(self.keyframeInterval),
     @(self.maxWidth), @(self.maxHeight), self.screenshotQuality];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
  return self;
}

- (void)scheduleNextFrameWithInterval:(uint64_t)interval timeStarted:(uint64_t)started
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started;
  int64_t delta = (int64_t)interval - (int64_t)elapsed;
  __weak typeof(self) weakSelf = self;
  if (delta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delta), self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  } else {
    dispatch_async(self.backgroundQueue, ^{
      [weakSelf streamFrame];
    });
  }
}

- (void)streamFrame
{
  if (!self.isStreaming) {
    return;
  }
  uint64_t interval = (uint64_t)(1.0 / (double)self.targetFps * NSEC_PER_SEC);
  uint64_t started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextFrameWithInterval:interval timeStarted:started];
      return;
    }
  }

  if (self.isEncodingFrame) {
    [self scheduleNextFrameWithInterval:interval timeStarted:started];
    return;
  }

  NSError *error = nil;
  NSData *jpeg = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                 compressionQuality:self.screenshotQuality
                                                                uti:UTTypeJPEG
                                                            timeout:H264_FRAME_TIMEOUT
                                                              error:&error];
  if (nil == jpeg) {
    if (nil != error) {
      [FBLogger logFmt:@"H264 screenshot failed: %@", error.description];
    }
    [self scheduleNextFrameWithInterval:interval timeStarted:started];
    return;
  }

  CVPixelBufferRef pixelBuffer = [self pixelBufferFromJPEG:jpeg];
  if (NULL != pixelBuffer) {
    [self encodePixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
  }

  [self scheduleNextFrameWithInterval:interval timeStarted:started];
}

- (CVPixelBufferRef)pixelBufferFromJPEG:(NSData *)jpeg CF_RETURNS_RETAINED
{
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
  if (NULL == source) {
    return NULL;
  }

  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  size_t originalWidth = (size_t)[properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
  size_t originalHeight = (size_t)[properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
  if (0 == originalWidth || 0 == originalHeight) {
    CGImageRef probeImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (NULL == probeImage) {
      CFRelease(source);
      return NULL;
    }
    originalWidth = CGImageGetWidth(probeImage);
    originalHeight = CGImageGetHeight(probeImage);
    CGImageRelease(probeImage);
  }

  size_t width = originalWidth;
  size_t height = originalHeight;

  CGFloat scale = 1.0;
  if (self.maxWidth > 0 && width > self.maxWidth) {
    scale = MIN(scale, (CGFloat)self.maxWidth / (CGFloat)width);
  }
  if (self.maxHeight > 0 && height > self.maxHeight) {
    scale = MIN(scale, (CGFloat)self.maxHeight / (CGFloat)height);
  }
  if (scale < 1.0) {
    width = (size_t)floor((CGFloat)originalWidth * scale) & ~(size_t)1;
    height = (size_t)floor((CGFloat)originalHeight * scale) & ~(size_t)1;
    width = MAX((size_t)2, width);
    height = MAX((size_t)2, height);
  }

  NSDictionary *imageOptions = nil;
  if (scale < 1.0) {
    imageOptions = @{
      (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
      (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
      (id)kCGImageSourceShouldCacheImmediately: @YES,
      (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(width, height)),
    };
  } else {
    imageOptions = @{
      (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
  }

  CGImageRef image = scale < 1.0
    ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)imageOptions)
    : CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)imageOptions);
  CFRelease(source);
  if (NULL == image) {
    return NULL;
  }

  CVPixelBufferRef pixelBuffer = [self createPixelBufferForWidth:width height:height];
  if (NULL == pixelBuffer) {
    CGImageRelease(image);
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(baseAddress,
                                               width,
                                               height,
                                               8,
                                               bytesPerRow,
                                               colorSpace,
                                               kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  if (NULL != context) {
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
  }
  CGColorSpaceRelease(colorSpace);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  CGImageRelease(image);
  return pixelBuffer;
}

- (CVPixelBufferRef)createPixelBufferForWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED
{
  [self ensurePixelBufferPoolForWidth:width height:height];

  CVPixelBufferRef pixelBuffer = NULL;
  if (NULL != self.pixelBufferPool) {
    CVReturn result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
    if (kCVReturnSuccess == result && NULL != pixelBuffer) {
      return pixelBuffer;
    }
  }

  NSDictionary *attributes = @{
    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width,
                                        height,
                                        kCVPixelFormatType_32BGRA,
                                        (__bridge CFDictionaryRef)attributes,
                                        &pixelBuffer);
  if (kCVReturnSuccess != result) {
    return NULL;
  }
  return pixelBuffer;
}

- (void)ensurePixelBufferPoolForWidth:(size_t)width height:(size_t)height
{
  if (NULL != self.pixelBufferPool && self.pixelBufferPoolWidth == width && self.pixelBufferPoolHeight == height) {
    return;
  }
  [self teardownPixelBufferPool];

  NSDictionary *attributes = @{
    (id)kCVPixelBufferWidthKey: @(width),
    (id)kCVPixelBufferHeightKey: @(height),
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVPixelBufferPoolRef pool = NULL;
  CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                            NULL,
                                            (__bridge CFDictionaryRef)attributes,
                                            &pool);
  if (kCVReturnSuccess != result || NULL == pool) {
    [FBLogger logFmt:@"Cannot create H264 pixel buffer pool: %@", @(result)];
    return;
  }
  self.pixelBufferPool = pool;
  self.pixelBufferPoolWidth = width;
  self.pixelBufferPoolHeight = height;
}

- (void)teardownPixelBufferPool
{
  if (NULL != self.pixelBufferPool) {
    CFRelease(self.pixelBufferPool);
    self.pixelBufferPool = NULL;
  }
  self.pixelBufferPoolWidth = 0;
  self.pixelBufferPoolHeight = 0;
}

- (void)ensureSessionForWidth:(size_t)width height:(size_t)height
{
  if (NULL != self.session && self.encodedWidth == width && self.encodedHeight == height) {
    return;
  }
  [self teardownSession];

  VTCompressionSessionRef session = NULL;
  OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault,
                                               (int32_t)width,
                                               (int32_t)height,
                                               kCMVideoCodecType_H264,
                                               NULL,
                                               NULL,
                                               NULL,
                                               FBH264OutputCallback,
                                               (__bridge void *)self,
                                               &session);
  if (noErr != status || NULL == session) {
    [FBLogger logFmt:@"Cannot create H264 encoder session: %@", @(status)];
    return;
  }

  VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFTypeRef)@(1));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(self.keyframeInterval));
  VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(self.targetBitrate));
  VTSessionSetProperty(session,
                       kVTCompressionPropertyKey_DataRateLimits,
                       (__bridge CFArrayRef)@[@((NSInteger)((double)self.targetBitrate / 8.0 * 1.3)), @(1.0)]);
  VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@(self.targetFps));
  VTCompressionSessionPrepareToEncodeFrames(session);

  self.session = session;
  self.encodedWidth = width;
  self.encodedHeight = height;
  self.forceKeyframe = YES;
  [FBLogger logFmt:@"H264 encoder ready: %@x%@", @(width), @(height)];
}

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
{
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  [self ensureSessionForWidth:width height:height];
  if (NULL == self.session) {
    return;
  }
  if (self.isEncodingFrame) {
    return;
  }
  self.isEncodingFrame = YES;

  CMTime presentationTime = CMTimeMake(self.frameIndex, (int32_t)self.targetFps);
  self.frameIndex++;

  NSDictionary *frameProperties = nil;
  if (self.forceKeyframe) {
    self.forceKeyframe = NO;
    frameProperties = @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
  }

  VTEncodeInfoFlags flags = 0;
  OSStatus status = VTCompressionSessionEncodeFrame(self.session,
                                                    pixelBuffer,
                                                    presentationTime,
                                                    kCMTimeInvalid,
                                                    (__bridge CFDictionaryRef)frameProperties,
                                                    NULL,
                                                    &flags);
  if (noErr != status) {
    self.isEncodingFrame = NO;
    [FBLogger logFmt:@"Cannot encode H264 frame: %@", @(status)];
    return;
  }
  VTCompressionSessionCompleteFrames(self.session, presentationTime);
}

- (void)teardownSession
{
  if (NULL != self.session) {
    self.isEncodingFrame = NO;
    VTCompressionSessionCompleteFrames(self.session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.session);
    CFRelease(self.session);
    self.session = NULL;
  }
}

- (void)sendAnnexB:(NSData *)data
{
  @synchronized (self.listeningClients) {
    if (!self.isStreaming || 0 == self.listeningClients.count) {
      return;
    }
    for (GCDAsyncSocket *client in self.listeningClients) {
      [client writeData:data withTimeout:H264_FRAME_TIMEOUT tag:0];
    }
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"H264 client connected %@:%d", newClient.connectedHost, newClient.connectedPort];
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClient:(GCDAsyncSocket *)client didReadData:(NSData *)data
{
  BOOL isKnownClient = NO;
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      isKnownClient = YES;
    }
  }

  if (!isKnownClient && ![FBConfiguration isStreamHandshakeAuthorized:data]) {
    [FBLogger logFmt:@"Rejected unauthorized H264 stream client %@:%d", client.connectedHost, client.connectedPort];
    [client disconnect];
    return;
  }

  @synchronized (self.listeningClients) {
    if (![self.listeningClients containsObject:client]) {
      [self.listeningClients addObject:client];
    }
  }

  self.forceKeyframe = YES;
  [client readDataWithTimeout:-1 tag:0];
  if (isKnownClient) {
    return;
  }
  [FBLogger logFmt:@"Starting H264 stream for client %@:%d", client.connectedHost, client.connectedPort];
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"Disconnected a client from H264 stream"];
}

- (void)stopStreaming
{
  self.isStreaming = NO;
  @synchronized (self.listeningClients) {
    NSArray<GCDAsyncSocket *> *clients = self.listeningClients.copy;
    [self.listeningClients removeAllObjects];
    for (GCDAsyncSocket *client in clients) {
      [client disconnect];
    }
  }
  [self teardownSession];
  [self teardownPixelBufferPool];
  self.isEncodingFrame = NO;
}

- (void)dealloc
{
  [self stopStreaming];
}

@end

static void FBH264OutputCallback(void *outputRefCon,
                                 void *sourceRefCon,
                                 OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer)
{
  FBH264Server *server = (__bridge FBH264Server *)outputRefCon;
  server.isEncodingFrame = NO;
  if (noErr != status || NULL == sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }

  static const uint8_t startCode[4] = {0x00, 0x00, 0x00, 0x01};
  static const int avccLengthSize = 4;
  NSMutableData *output = [NSMutableData data];

  BOOL keyframe = NO;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (NULL != attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    keyframe = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  }

  if (keyframe) {
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (NULL != formatDescription) {
      size_t parameterSetCount = 0;
      int naluHeaderLength = 0;
      const uint8_t *sps = NULL;
      const uint8_t *pps = NULL;
      size_t spsLength = 0;
      size_t ppsLength = 0;
      if (noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, 0, &sps, &spsLength, &parameterSetCount, &naluHeaderLength) &&
          noErr == CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, 1, &pps, &ppsLength, NULL, NULL)) {
        [output appendBytes:startCode length:sizeof(startCode)];
        [output appendBytes:sps length:spsLength];
        [output appendBytes:startCode length:sizeof(startCode)];
        [output appendBytes:pps length:ppsLength];
      }
    }
  }

  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
  if (NULL != blockBuffer) {
    size_t totalLength = 0;
    char *dataPointer = NULL;
    if (noErr == CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer)) {
      size_t offset = 0;
      while (offset + avccLengthSize <= totalLength) {
        uint32_t naluLength = 0;
        memcpy(&naluLength, dataPointer + offset, avccLengthSize);
        naluLength = CFSwapInt32BigToHost(naluLength);
        if (offset + avccLengthSize + naluLength > totalLength) {
          break;
        }
        [output appendBytes:startCode length:sizeof(startCode)];
        [output appendBytes:(dataPointer + offset + avccLengthSize) length:naluLength];
        offset += avccLengthSize + naluLength;
      }
    }
  }

  if (output.length > 0) {
    [server sendAnnexB:output];
  }
}
