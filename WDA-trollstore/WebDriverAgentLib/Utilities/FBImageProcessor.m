/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBImageProcessor.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
@import UniformTypeIdentifiers;

#import "FBConfiguration.h"
#import "FBErrorBuilder.h"
#import "FBImageUtils.h"
#import "FBLogger.h"

const CGFloat FBMinScalingFactor = 0.01f;
const CGFloat FBMaxScalingFactor = 1.0f;
const CGFloat FBMinCompressionQuality = 0.0f;
const CGFloat FBMaxCompressionQuality = 1.0f;

@interface FBImageProcessor ()

@property (nonatomic) NSData *nextImage;
@property (nonatomic, readonly) NSLock *nextImageLock;
@property (nonatomic, readonly) dispatch_queue_t scalingQueue;

@end

@implementation FBImageProcessor

- (id)init
{
  self = [super init];
  if (self) {
    _nextImageLock = [[NSLock alloc] init];
    _scalingQueue = dispatch_queue_create("image.scaling.queue", NULL);
  }
  return self;
}

- (void)submitImageData:(NSData *)image
          scalingFactor:(CGFloat)scalingFactor
      completionHandler:(void (^)(NSData *))completionHandler
{
  [self.nextImageLock lock];
  if (self.nextImage != nil) {
    [FBLogger verboseLog:@"Discarding screenshot"];
  }
  self.nextImage = image;
  [self.nextImageLock unlock];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcompletion-handler"
  dispatch_async(self.scalingQueue, ^{
    [self.nextImageLock lock];
    NSData *nextImageData = self.nextImage;
    self.nextImage = nil;
    [self.nextImageLock unlock];
    if (nextImageData == nil) {
      return;
    }

    CGFloat recompressionQuality = MAX(0.1,
                                       MIN(FBMaxCompressionQuality, FBConfiguration.mjpegServerScreenshotQuality / 100.0));
    NSData *thumbnailData = [self.class fixedImageDataWithImageData:nextImageData
                                                      scalingFactor:scalingFactor
                                                                uti:UTTypeJPEG
                                                 compressionQuality:recompressionQuality
    // iOS always returns screnshots in portrait orientation, but puts the real value into the metadata
    // Use it with care. See https://github.com/appium/WebDriverAgent/pull/812
                                                     fixOrientation:FBConfiguration.mjpegShouldFixOrientation
                                                 desiredOrientation:nil];
    completionHandler(thumbnailData ?: nextImageData);
  });
#pragma clang diagnostic pop
}

+ (nullable NSData *)fixedImageDataWithImageData:(NSData *)imageData
                                   scalingFactor:(CGFloat)scalingFactor
                                             uti:(UTType *)uti
                              compressionQuality:(CGFloat)compressionQuality
                                  fixOrientation:(BOOL)fixOrientation
                              desiredOrientation:(nullable NSNumber *)orientation
{
  scalingFactor = MAX(FBMinScalingFactor, MIN(FBMaxScalingFactor, scalingFactor));
  BOOL usesScaling = scalingFactor > 0.0 && scalingFactor < FBMaxScalingFactor;
  @autoreleasepool {
    if (!usesScaling && !fixOrientation) {
      return [uti conformsToType:UTTypePNG] ? FBToPngData(imageData) : FBToJpegData(imageData, compressionQuality);
    }

    if (orientation == nil && [uti conformsToType:UTTypeJPEG]) {
      NSData *thumbnailData = [self.class jpegThumbnailWithImageData:imageData
                                                       scalingFactor:scalingFactor
                                                  compressionQuality:compressionQuality
                                                      fixOrientation:fixOrientation];
      if (nil != thumbnailData) {
        return thumbnailData;
      }
    }
  
    UIImage *image = [UIImage imageWithData:imageData];
    if (nil == image
        || ((image.imageOrientation == UIImageOrientationUp || !fixOrientation) && !usesScaling)) {
      return [uti conformsToType:UTTypePNG] ? FBToPngData(imageData) : FBToJpegData(imageData, compressionQuality);
    }
    
    CGSize scaledSize = CGSizeMake(image.size.width * scalingFactor, image.size.height * scalingFactor);
    if (!fixOrientation && usesScaling) {
      dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
      __block UIImage *result = nil;
      [image prepareThumbnailOfSize:scaledSize
                  completionHandler:^(UIImage * _Nullable thumbnail) {
        result = thumbnail;
        dispatch_semaphore_signal(semaphore);
      }];
      dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
      if (nil == result) {
        return [uti conformsToType:UTTypePNG] ? FBToPngData(imageData) : FBToJpegData(imageData, compressionQuality);
      }
      return [uti conformsToType:UTTypePNG]
        ? UIImagePNGRepresentation(result)
        : UIImageJPEGRepresentation(result, compressionQuality);
    }
  
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.scale = scalingFactor;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:scaledSize
                                                                               format:format];
    UIImageOrientation desiredOrientation = orientation == nil
      ? image.imageOrientation
      : (UIImageOrientation)orientation.integerValue;
    UIImage *uiImage = [UIImage imageWithCGImage:(CGImageRef)image.CGImage
                                           scale:image.scale
                                     orientation:desiredOrientation];
    return [uti conformsToType:UTTypePNG]
      ? [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        [uiImage drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];
      }]
      : [renderer JPEGDataWithCompressionQuality:compressionQuality
                                         actions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
        [uiImage drawInRect:CGRectMake(0, 0, scaledSize.width, scaledSize.height)];
      }];
  }
}

+ (nullable NSData *)jpegThumbnailWithImageData:(NSData *)imageData
                                  scalingFactor:(CGFloat)scalingFactor
                             compressionQuality:(CGFloat)compressionQuality
                                 fixOrientation:(BOOL)fixOrientation
{
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
  if (NULL == source) {
    return nil;
  }

  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  NSUInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
  NSUInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
  NSUInteger maxPixelSize = MAX((NSUInteger)2, (NSUInteger)lrint((CGFloat)MAX(width, height) * scalingFactor));

  NSDictionary *thumbnailOptions = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (id)kCGImageSourceCreateThumbnailWithTransform: @(fixOrientation),
    (id)kCGImageSourceShouldCacheImmediately: @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
  };

  CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
  CFRelease(source);
  if (NULL == thumbnail) {
    return nil;
  }

  NSMutableData *result = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result,
                                                                      (__bridge CFStringRef)UTTypeJPEG.identifier,
                                                                      1,
                                                                      NULL);
  if (NULL == destination) {
    CGImageRelease(thumbnail);
    return nil;
  }

  NSDictionary *destinationOptions = @{
    (id)kCGImageDestinationLossyCompressionQuality: @(compressionQuality),
  };
  CGImageDestinationAddImage(destination, thumbnail, (__bridge CFDictionaryRef)destinationOptions);
  BOOL ok = CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(thumbnail);
  return ok ? result : nil;
}

- (nullable NSData *)scaledImageWithData:(NSData *)imageData
                                     uti:(UTType *)uti
                           scalingFactor:(CGFloat)scalingFactor
                      compressionQuality:(CGFloat)compressionQuality
                                   error:(NSError **)error
{
  NSNumber *orientation = nil;
#if !TARGET_OS_TV
  if (FBConfiguration.screenshotOrientation == UIInterfaceOrientationPortrait) {
    orientation = @(UIImageOrientationUp);
  } else if (FBConfiguration.screenshotOrientation == UIInterfaceOrientationPortraitUpsideDown) {
    orientation = @(UIImageOrientationDown);
  } else if (FBConfiguration.screenshotOrientation == UIInterfaceOrientationLandscapeLeft) {
    orientation = @(UIImageOrientationRight);
  } else if (FBConfiguration.screenshotOrientation == UIInterfaceOrientationLandscapeRight) {
    orientation = @(UIImageOrientationLeft);
  }
#endif
  NSData *resultData = [self.class fixedImageDataWithImageData:imageData
                                                 scalingFactor:scalingFactor
                                                           uti:uti
                                            compressionQuality:compressionQuality
                                                fixOrientation:YES
                                            desiredOrientation:orientation];
  return resultData ?: imageData;
}

@end
