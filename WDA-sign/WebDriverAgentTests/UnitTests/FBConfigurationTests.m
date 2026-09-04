/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBConfiguration.h"
#import "FBCustomCommands.h"
#import "FBResponsePayload.h"

@interface FBCustomCommands (SecurityTests)
+ (NSString *)safeExtensionFromFilename:(NSString *)filename
                       defaultExtension:(NSString *)defaultExtension;
+ (NSString *)safeUploadFilenameFromRequestedFilename:(nullable NSString *)filename
                                       defaultPrefix:(NSString *)defaultPrefix
                                   defaultExtension:(NSString *)defaultExtension;
+ (nullable NSString *)safeTemporaryUploadPathForFilename:(NSString *)filename
                                                    error:(NSError **)error;
+ (nullable NSData *)decodeBase64Payload:(NSString *)payload
                           errorResponse:(id<FBResponsePayload> __autoreleasing *)errorResponse;
@end

@interface FBConfigurationTests : XCTestCase

@end

@implementation FBConfigurationTests

- (void)setUp
{
  [super setUp];
  unsetenv("USE_PORT");
  unsetenv("USE_IP");
  unsetenv("MJPEG_SERVER_PORT");
  unsetenv("H264_SERVER_PORT");
  unsetenv("VERBOSE_LOGGING");
  unsetenv("WDA_ALLOWED_ORIGIN");
  unsetenv("WDA_ALLOW_ANY_CORS_ORIGIN");
  unsetenv("WDA_AUTH_TOKEN");
  unsetenv("WEBDRIVERAGENT_AUTH_TOKEN");
  unsetenv("WDA_BIND_ALL_INTERFACES");
  unsetenv("WDA_CORS_ORIGIN");
  unsetenv("WDA_DISABLE_AUTHENTICATION");
  unsetenv("WDA_MAX_HTTP_BODY_BYTES");
  unsetenv("WDA_MAX_PUSH_PAYLOAD_BYTES");
  unsetenv("WDA_REALTIME_CONTROL_BIND_ALL_INTERFACES");
  unsetenv("WDA_REALTIME_CONTROL_BIND_IP");
  unsetenv("WDA_REALTIME_CONTROL_ENABLED");
  unsetenv("WDA_REALTIME_CONTROL_PORT");
  unsetenv("WDA_REQUIRE_AUTH");
  unsetenv("WDA_STREAM_BIND_ALL_INTERFACES");
  unsetenv("WDA_STREAM_BIND_IP");
}

- (void)testBindingPortDefault
{
  XCTAssertTrue(NSEqualRanges([FBConfiguration bindingPortRange], NSMakeRange(8000, 100)));
}

- (void)testBindingPortEnvironmentOverwrite
{
  setenv("USE_PORT", "1000", 1);
  XCTAssertTrue(NSEqualRanges([FBConfiguration bindingPortRange], NSMakeRange(1000, 1)));
}

- (void)testMjpegServerPortDefault
{
  XCTAssertEqual([FBConfiguration mjpegServerPort], 8001);
}

- (void)testH264ServerPortDefault
{
  XCTAssertEqual([FBConfiguration h264ServerPort], 8002);
}

- (void)testRealtimeControlEnabledByDefault
{
  XCTAssertTrue([FBConfiguration realtimeControlEnabled]);
}

- (void)testRealtimeControlCanBeDisabled
{
  setenv("WDA_REALTIME_CONTROL_ENABLED", "0", 1);
  XCTAssertFalse([FBConfiguration realtimeControlEnabled]);
}

- (void)testRealtimeControlPortDefault
{
  XCTAssertEqual([FBConfiguration realtimeControlPort], 8003);
}

- (void)testVerboseLoggingDefault
{
  XCTAssertFalse([FBConfiguration verboseLoggingEnabled]);
}

- (void)testVerboseLoggingEnvironmentOverwrite
{
  setenv("VERBOSE_LOGGING", "YES", 1);
  XCTAssertTrue([FBConfiguration verboseLoggingEnabled]);
}

- (void)testBindingIPDefaultsToAllInterfaces
{
  XCTAssertNil([FBConfiguration bindingIPAddress]);
}

- (void)testBindingIPCanExplicitlyBindAllInterfaces
{
  setenv("WDA_BIND_ALL_INTERFACES", "1", 1);
  XCTAssertNil([FBConfiguration bindingIPAddress]);
}

- (void)testBindingIPEnvironmentOverwrite
{
  setenv("USE_IP", "192.168.1.100", 1);
  XCTAssertEqualObjects([FBConfiguration bindingIPAddress], @"192.168.1.100");
}

- (void)testStreamBindingDefaultsToAllInterfaces
{
  XCTAssertNil([FBConfiguration streamBindingIPAddress]);
}

- (void)testStreamBindingEnvironmentOverwrite
{
  setenv("WDA_STREAM_BIND_IP", "127.0.0.2", 1);
  XCTAssertEqualObjects([FBConfiguration streamBindingIPAddress], @"127.0.0.2");
}

- (void)testCORSDefaultIsDisabled
{
  XCTAssertNil([FBConfiguration allowedCORSOrigin]);
}

- (void)testWildcardCORSRequiresExplicitUnsafeOptIn
{
  setenv("WDA_CORS_ORIGIN", "*", 1);
  XCTAssertNil([FBConfiguration allowedCORSOrigin]);

  setenv("WDA_ALLOW_ANY_CORS_ORIGIN", "1", 1);
  XCTAssertEqualObjects([FBConfiguration allowedCORSOrigin], @"*");
}

- (void)testExactCORSOrigin
{
  setenv("WDA_CORS_ORIGIN", "https://example.test", 1);
  XCTAssertEqualObjects([FBConfiguration allowedCORSOrigin], @"https://example.test");
}

- (void)testAuthenticationDisabledByDefault
{
  XCTAssertFalse([FBConfiguration requiresAuthentication]);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{} queryParameters:@{}]);
}

- (void)testAuthenticationRequiredWhenBindingAllInterfaces
{
  setenv("WDA_BIND_ALL_INTERFACES", "1", 1);
  XCTAssertTrue([FBConfiguration requiresAuthentication]);
  XCTAssertFalse([FBConfiguration isAuthenticationConfigured]);
  XCTAssertFalse([FBConfiguration isRequestAuthorizedWithHeaders:@{} queryParameters:@{}]);
}

- (void)testAuthenticationRequiredWhenBindingNonLoopbackIP
{
  setenv("USE_IP", "192.168.1.100", 1);
  XCTAssertTrue([FBConfiguration requiresAuthentication]);
  XCTAssertFalse([FBConfiguration isRequestAuthorizedWithHeaders:@{} queryParameters:@{}]);
}

- (void)testRealtimeControlBindingDoesNotRequireGlobalAuthentication
{
  setenv("WDA_REALTIME_CONTROL_BIND_ALL_INTERFACES", "1", 1);
  XCTAssertFalse([FBConfiguration requiresAuthentication]);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{} queryParameters:@{}]);
}

- (void)testAuthenticationCanBeExplicitlyDisabledForCompatibility
{
  setenv("WDA_BIND_ALL_INTERFACES", "1", 1);
  setenv("WDA_DISABLE_AUTHENTICATION", "1", 1);
  XCTAssertFalse([FBConfiguration requiresAuthentication]);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{} queryParameters:@{}]);
}

- (void)testAuthenticationWithBearerToken
{
  setenv("WDA_AUTH_TOKEN", "secret-token", 1);
  XCTAssertTrue([FBConfiguration requiresAuthentication]);
  XCTAssertTrue([FBConfiguration isAuthenticationConfigured]);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{@"Authorization": @"Bearer secret-token"}
                                                queryParameters:@{}]);
  XCTAssertFalse([FBConfiguration isRequestAuthorizedWithHeaders:@{@"Authorization": @"Bearer wrong"}
                                                 queryParameters:@{}]);
}

- (void)testAuthenticationWithHeaderAndQueryAliases
{
  setenv("WDA_AUTH_TOKEN", "secret-token", 1);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{@"X-WDA-Token": @"secret-token"}
                                                queryParameters:@{}]);
  XCTAssertTrue([FBConfiguration isRequestAuthorizedWithHeaders:@{}
                                                queryParameters:@{@"wdaToken": @"secret-token"}]);
}

- (void)testRequiredAuthenticationWithoutTokenRejectsRequests
{
  setenv("WDA_REQUIRE_AUTH", "1", 1);
  XCTAssertTrue([FBConfiguration requiresAuthentication]);
  XCTAssertFalse([FBConfiguration isAuthenticationConfigured]);
  XCTAssertFalse([FBConfiguration isRequestAuthorizedWithHeaders:@{@"Authorization": @"Bearer anything"}
                                                 queryParameters:@{}]);
}

- (void)testStreamHandshakeAuthorization
{
  setenv("WDA_AUTH_TOKEN", "secret-token", 1);
  NSData *rawBearer = [@"Bearer secret-token" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([FBConfiguration isStreamHandshakeAuthorized:rawBearer]);

  NSData *httpRequest = [@"GET /?token=secret-token HTTP/1.1\r\nHost: localhost\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertTrue([FBConfiguration isStreamHandshakeAuthorized:httpRequest]);

  NSData *badRequest = [@"GET / HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertFalse([FBConfiguration isStreamHandshakeAuthorized:badRequest]);
}

- (void)testUploadFilenameIsGeneratedAndKeepsOnlySafeExtension
{
  NSString *safeName = [FBCustomCommands safeUploadFilenameFromRequestedFilename:@"../../Library/private.txt"
                                                                  defaultPrefix:@"wda_file"
                                                              defaultExtension:@"bin"];
  XCTAssertTrue([safeName hasPrefix:@"wda_file_"]);
  XCTAssertTrue([safeName hasSuffix:@".txt"]);
  XCTAssertFalse([safeName containsString:@"/"]);
  XCTAssertFalse([safeName containsString:@".."]);

  NSString *fallbackName = [FBCustomCommands safeUploadFilenameFromRequestedFilename:@"archive.tar/evil"
                                                                      defaultPrefix:@"wda_file"
                                                                  defaultExtension:@"bin"];
  XCTAssertTrue([fallbackName hasSuffix:@".bin"]);
}

- (void)testUploadPathRejectsTraversal
{
  NSError *error = nil;
  XCTAssertNil([FBCustomCommands safeTemporaryUploadPathForFilename:@"../evil.bin" error:&error]);
  XCTAssertNotNil(error);
}

- (void)testUploadPathIsContained
{
  NSError *error = nil;
  NSString *path = [FBCustomCommands safeTemporaryUploadPathForFilename:@"wda_file_test.bin" error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([path containsString:@"/wda_uploads/"]);
  XCTAssertEqualObjects(path.lastPathComponent, @"wda_file_test.bin");
}

- (void)testPushPayloadLimit
{
  setenv("WDA_MAX_PUSH_PAYLOAD_BYTES", "1024", 1);
  NSMutableData *tooLargeData = [NSMutableData dataWithLength:1025];
  NSString *payload = [tooLargeData base64EncodedStringWithOptions:0];
  id<FBResponsePayload> response = nil;
  NSData *data = [FBCustomCommands decodeBase64Payload:payload errorResponse:&response];
  XCTAssertNil(data);
  XCTAssertNotNil(response);
}

@end
