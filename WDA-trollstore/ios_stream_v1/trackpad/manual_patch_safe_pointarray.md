# Patch thủ công cho WebDriverAgent sạch: thêm `POST /wda/swipe/pointArray` an toàn hơn

Patch này dành cho source `appium/WebDriverAgent`, không phải file `.app` binary.

Mục tiêu:

- thêm route `POST /session/:id/wda/swipe/pointArray`
- chỉ bật khi `SOLUMATE_WDA_ENABLE_POINT_ARRAY=1`
- validate `pointArray`
- hỗ trợ `st` thật sự bằng `HMAC-SHA256`
- bỏ hoàn toàn các thành phần lạ kiểu `hhhhsd.dylib`

---

## 1) Sửa `WebDriverAgentLib/Categories/XCUIDevice+FBHelpers.h`

Thêm declaration sau vào interface/category của `XCUIDevice (FBHelpers)`:

```objc
- (BOOL)fb_solumate_synthSwipePointArray:(NSArray<NSArray<NSNumber *> *> *)pointArray
                            error:(NSError **)error;
```

---

## 2) Sửa `WebDriverAgentLib/Categories/XCUIDevice+FBHelpers.m`

### 2.1 Thêm import

```objc
#import <dispatch/dispatch.h>
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCTRunnerDaemonSession.h"
```

### 2.2 Thêm helper mới vào implementation

```objc
- (BOOL)fb_solumate_synthSwipePointArray:(NSArray<NSArray<NSNumber *> *> *)pointArray
                            error:(NSError **)error
{
  if (pointArray.count < 2) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:400
                               userInfo:@{NSLocalizedDescriptionKey: @"pointArray must contain at least 2 points"}];
    }
    return NO;
  }

  NSArray<NSNumber *> *first = pointArray.firstObject;
  CGPoint start = CGPointMake(first[0].doubleValue, first[1].doubleValue);
  XCPointerEventPath *pointerEventPath = [[XCPointerEventPath alloc] initForTouchAtPoint:start offset:0];

  NSTimeInterval lastOffset = 0;
  for (NSUInteger i = 1; i < pointArray.count; i++) {
    NSArray<NSNumber *> *item = pointArray[i];
    CGPoint point = CGPointMake(item[0].doubleValue, item[1].doubleValue);
    NSTimeInterval offset = item[2].doubleValue;
    if (offset < lastOffset) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: @"pointArray offsets must be monotonic"}];
      }
      return NO;
    }
    [pointerEventPath moveToPoint:point atOffset:offset];
    lastOffset = offset;
  }

  [pointerEventPath liftUpAtOffset:lastOffset];

  XCSynthesizedEventRecord *eventRecord = [[XCSynthesizedEventRecord alloc] initWithName:@"hc.pointArray" interfaceOrientation:0];
  [eventRecord addPointerEventPath:pointerEventPath];

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block BOOL ok = YES;
  __block NSError *invokeError = nil;

  [[self eventSynthesizer] synthesizeEvent:eventRecord completion:(id)^(BOOL result, NSError *err) {
    ok = result;
    invokeError = err;
    dispatch_semaphore_signal(sema);
  }];

  dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(1.0, lastOffset + 2.0) * NSEC_PER_SEC));
  long waitResult = dispatch_semaphore_wait(sema, timeout);
  if (waitResult != 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:408
                               userInfo:@{NSLocalizedDescriptionKey: @"Timed out waiting for synthesized pointArray swipe"}];
    }
    return NO;
  }

  if (!ok || nil != invokeError) {
    if (error) {
      *error = invokeError ?: [NSError errorWithDomain:@"com.solumate.wda"
                                                  code:500
                                              userInfo:@{NSLocalizedDescriptionKey: @"Failed to synthesize pointArray swipe"}];
    }
    return NO;
  }

  return YES;
}
```

---

## 3) Sửa `WebDriverAgentLib/Commands/FBCustomCommands.m`

### 3.1 Thêm import

```objc
#import <CommonCrypto/CommonHMAC.h>
#import <UIKit/UIKit.h>
#import <math.h>

#import "FBCommandStatus.h"
```

### 3.2 Thêm helper static ở trên `@implementation FBCustomCommands`

```objc
static NSString *const SolumateWDAEnablePointArrayEnv = @"SOLUMATE_WDA_ENABLE_POINT_ARRAY";
static NSString *const SolumateWDASwipeSecretEnv = @"SOLUMATE_WDA_SWIPE_SECRET";
static NSString *const SolumateWDAAllowUnsignedPointArrayEnv = @"SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY";
static const NSUInteger SolumateWDAMaxPointCount = 256;
static const NSTimeInterval SolumateWDAMaxDuration = 30.0;
static const NSTimeInterval SolumateWDAMaxClockSkew = 30.0;
static const double SolumateWDADefaultStep = 0.016;

static BOOL SolumateWDAIsEnabled(NSString *value)
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

static NSNumber *SolumateWDANumber(id value)
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

static NSString *SolumateWDAFormatDouble(double value)
{
  return [NSString stringWithFormat:@"%.6f", value];
}

static NSString *SolumateWDACanonicalPointArrayString(NSArray<NSArray<NSNumber *> *> *pointArray)
{
  NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:pointArray.count];
  for (NSArray<NSNumber *> *item in pointArray) {
    [rows addObject:[NSString stringWithFormat:@"%@,%@,%@",
                     SolumateWDAFormatDouble(item[0].doubleValue),
                     SolumateWDAFormatDouble(item[1].doubleValue),
                     SolumateWDAFormatDouble(item[2].doubleValue)]];
  }
  return [rows componentsJoinedByString:@";"];
}

static NSString *SolumateWDAHexString(NSData *data)
{
  const unsigned char *bytes = data.bytes;
  NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
  for (NSUInteger i = 0; i < data.length; i++) {
    [result appendFormat:@"%02x", bytes[i]];
  }
  return result;
}

static NSString *SolumateWDAHmacSha256(NSString *secret, NSString *message)
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
  return SolumateWDAHexString([NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH]);
}

static BOOL SolumateWDAConstantTimeEqual(NSString *a, NSString *b)
{
  NSData *da = [[a lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
  NSData *db = [[b lowercaseString] dataUsingEncoding:NSUTF8StringEncoding];
  if (da.length != db.length) {
    return NO;
  }
  const uint8_t *pa = da.bytes;
  const uint8_t *pb = db.bytes;
  uint8_t diff = 0;
  for (NSUInteger i = 0; i < da.length; i++) {
    diff |= pa[i] ^ pb[i];
  }
  return diff == 0;
}

static id<FBResponsePayload> SolumateWDAInvalidArgument(NSString *message)
{
  return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil]);
}

static NSArray<NSArray<NSNumber *> *> *SolumateWDANormalizePointArray(id rawValue, NSError **error)
{
  if (![rawValue isKindOfClass:NSArray.class]) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:400
                               userInfo:@{NSLocalizedDescriptionKey: @"pointArray must be an array"}];
    }
    return nil;
  }

  NSArray *rawPoints = (NSArray *)rawValue;
  if (rawPoints.count < 2 || rawPoints.count > SolumateWDAMaxPointCount) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:400
                               userInfo:@{NSLocalizedDescriptionKey: @"pointArray must contain between 2 and 256 points"}];
    }
    return nil;
  }

  CGRect bounds = [UIScreen mainScreen].bounds;
  NSMutableArray<NSArray<NSNumber *> *> *normalized = [NSMutableArray arrayWithCapacity:rawPoints.count];
  double lastOffset = 0;

  for (NSUInteger idx = 0; idx < rawPoints.count; idx++) {
    id rawItem = rawPoints[idx];
    if (![rawItem isKindOfClass:NSArray.class]) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] must be an array", (unsigned long)idx]}];
      }
      return nil;
    }

    NSArray *item = (NSArray *)rawItem;
    if (item.count < 2 || item.count > 3) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] must have 2 or 3 numeric values", (unsigned long)idx]}];
      }
      return nil;
    }

    NSNumber *xNum = SolumateWDANumber(item[0]);
    NSNumber *yNum = SolumateWDANumber(item[1]);
    NSNumber *tNum = item.count == 3 ? SolumateWDANumber(item[2]) : nil;
    if (nil == xNum || nil == yNum || (item.count == 3 && nil == tNum)) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] contains non-numeric values", (unsigned long)idx]}];
      }
      return nil;
    }

    double x = xNum.doubleValue;
    double y = yNum.doubleValue;
    if (!isfinite(x) || !isfinite(y)) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] coordinates must be finite", (unsigned long)idx]}];
      }
      return nil;
    }

    if (x < 0 || y < 0 || x > CGRectGetMaxX(bounds) || y > CGRectGetMaxY(bounds)) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] is outside the screen bounds", (unsigned long)idx]}];
      }
      return nil;
    }

    double offset = 0;
    if (idx == 0) {
      offset = 0;
      if (nil != tNum && fabs(tNum.doubleValue) > 0.000001) {
        if (error) {
          *error = [NSError errorWithDomain:@"com.solumate.wda"
                                       code:400
                                   userInfo:@{NSLocalizedDescriptionKey: @"pointArray[0] offset must be 0 or omitted"}];
        }
        return nil;
      }
    } else if (nil != tNum) {
      offset = tNum.doubleValue;
      if (!isfinite(offset) || offset < lastOffset) {
        if (error) {
          *error = [NSError errorWithDomain:@"com.solumate.wda"
                                       code:400
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"pointArray[%lu] offset must be monotonic", (unsigned long)idx]}];
        }
        return nil;
      }
    } else {
      offset = lastOffset + SolumateWDADefaultStep;
    }

    if (offset > SolumateWDAMaxDuration) {
      if (error) {
        *error = [NSError errorWithDomain:@"com.solumate.wda"
                                     code:400
                                 userInfo:@{NSLocalizedDescriptionKey: @"pointArray total duration exceeds 30 seconds"}];
      }
      return nil;
    }

    lastOffset = offset;
    [normalized addObject:@[@(x), @(y), @(offset)]];
  }

  return normalized;
}

static BOOL SolumateWDAVerifyST(NSArray<NSArray<NSNumber *> *> *pointArray,
                          NSString *st,
                          NSString *secret,
                          NSError **error)
{
  if (secret.length == 0) {
    return YES;
  }

  if (![st isKindOfClass:NSString.class] || st.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:401
                               userInfo:@{NSLocalizedDescriptionKey: @"Missing st token"}];
    }
    return NO;
  }

  NSArray<NSString *> *parts = [st componentsSeparatedByString:@"."];
  if (parts.count != 2) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:401
                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid st format"}];
    }
    return NO;
  }

  NSString *tsString = parts[0];
  NSString *sigString = parts[1];
  NSNumber *tsNum = SolumateWDANumber(tsString);
  if (nil == tsNum) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:401
                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid st timestamp"}];
    }
    return NO;
  }

  NSTimeInterval now = [NSDate date].timeIntervalSince1970;
  if (fabs(now - tsNum.doubleValue) > SolumateWDAMaxClockSkew) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:401
                               userInfo:@{NSLocalizedDescriptionKey: @"Expired st token"}];
    }
    return NO;
  }

  NSString *message = [NSString stringWithFormat:@"%@\n%@", tsString, SolumateWDACanonicalPointArrayString(pointArray)];
  NSString *expected = SolumateWDAHmacSha256(secret, message);
  if (!SolumateWDAConstantTimeEqual(expected, sigString)) {
    if (error) {
      *error = [NSError errorWithDomain:@"com.solumate.wda"
                                   code:401
                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid st signature"}];
    }
    return NO;
  }
  return YES;
}
```

### 3.3 Thêm route vào `+ (NSArray *)routes`

**Chỉ thêm route có session**, không thêm `.withoutSession`:

```objc
[[FBRoute POST:@"/wda/swipe/pointArray"] respondWithTarget:self action:@selector(handleDeviceSwipePointArray:)],
```

### 3.4 Thêm handler mới vào `FBCustomCommands.m`

```objc
+ (id<FBResponsePayload>)handleDeviceSwipePointArray:(FBRouteRequest *)request
{
  NSString *enableFlag = [NSProcessInfo processInfo].environment[SolumateWDAEnablePointArrayEnv];
  if (!SolumateWDAIsEnabled(enableFlag)) {
    return FBResponseWithStatus([FBCommandStatus unsupportedOperationErrorWithMessage:@"pointArray swipe is disabled" traceback:nil]);
  }

  NSError *validationError = nil;
  NSArray<NSArray<NSNumber *> *> *normalized = SolumateWDANormalizePointArray(request.arguments[@"pointArray"], &validationError);
  if (nil == normalized) {
    return SolumateWDAInvalidArgument(validationError.localizedDescription ?: @"Invalid pointArray");
  }

  NSString *secret = [NSProcessInfo processInfo].environment[SolumateWDASwipeSecretEnv] ?: @"";
  NSString *st = [request.arguments[@"st"] isKindOfClass:NSString.class] ? request.arguments[@"st"] : @"";
  NSString *allowUnsigned = [NSProcessInfo processInfo].environment[SolumateWDAAllowUnsignedPointArrayEnv];
  if (secret.length == 0 && !SolumateWDAIsEnabled(allowUnsigned)) {
    return SolumateWDAInvalidArgument(@"SOLUMATE_WDA_SWIPE_SECRET is required for pointArray swipe");
  }

  NSError *authError = nil;
  if (!SolumateWDAVerifyST(normalized, st, secret, &authError)) {
    return SolumateWDAInvalidArgument(authError.localizedDescription ?: @"Invalid st");
  }

  NSError *gestureError = nil;
  BOOL ok = [[XCUIDevice sharedDevice] fb_solumate_synthSwipePointArray:normalized error:&gestureError];
  if (!ok) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:(gestureError.localizedDescription ?: @"Unable to synthesize pointArray swipe") traceback:nil]);
  }

  return FBResponseWithOK();
}
```

---

## 4) Khuyến nghị build

### Build-time

- build từ source `appium/WebDriverAgent`
- không nhúng bất kỳ `.dylib` lạ nào
- không giữ file ngoài như `amazoncloud`

### Runtime

Nên bật:

- `SOLUMATE_WDA_ENABLE_POINT_ARRAY=1`
- `SOLUMATE_WDA_SWIPE_SECRET=your-long-random-secret`

Chi dung `SOLUMATE_WDA_ALLOW_UNSIGNED_POINT_ARRAY=1` trong moi truong test noi bo neu muon tam cho phep request khong co `st`.

### Client

Dùng script `call_wda_swipe_pointarray_secure.js` trong thư mục này. Script sẽ:

- validate `pointArray` ở phía client
- canonicalize dữ liệu giống server
- tạo `st = <unixTs>.<hmacHex>`

---

## 5) Vì sao patch này an toàn hơn bản `solumate-agent`

- route chỉ bật khi có cờ runtime
- có thể buộc HMAC bằng `st`
- validate chặt số điểm, toạ độ, thời lượng, thứ tự thời gian
- đợi completion của synthesize event thay vì trả `YES` ngay
- không cần `hhhhsd.dylib`
