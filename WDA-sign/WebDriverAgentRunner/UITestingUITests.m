/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <WebDriverAgentLib/FBDebugLogDelegateDecorator.h>
#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBFailureProofTestCase.h>
#import <WebDriverAgentLib/FBWebServer.h>
#import <WebDriverAgentLib/XCTestCase.h>

static void ConfigureWDA(void)
{
  [FBDebugLogDelegateDecorator decorateXCTestLogger];
  [FBConfiguration disableRemoteQueryEvaluation];
  [FBConfiguration configureDefaultKeyboardPreferences];
  [FBConfiguration disableApplicationUIInterruptionsHandling];
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREEN_RECORDINGS"]) {
    [FBConfiguration enableScreenRecordings];
  } else {
    [FBConfiguration disableScreenRecordings];
  }
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREENSHOTS"]) {
    [FBConfiguration enableScreenshots];
  } else {
    [FBConfiguration disableScreenshots];
  }
}

static void StartWDAOnce(id<FBWebServerDelegate> delegate)
{
  static BOOL didStart = NO;
  if (didStart) {
    return;
  }
  didStart = YES;

  ConfigureWDA();

  FBWebServer *webServer = [[FBWebServer alloc] init];
  webServer.delegate = delegate;
  [webServer startServing];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wglobal-constructors"
__attribute__((constructor))
static void BootstrapWDA(void)
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    StartWDAOnce(nil);
  });
}
#pragma clang diagnostic pop

@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>
@end

@implementation UITestingUITests

+ (void)setUp
{
  ConfigureWDA();
  [super setUp];
}

/**
 Never ending test used to start WebDriverAgent
 */
- (void)testRunner
{
  StartWDAOnce(self);
}

#pragma mark - FBWebServerDelegate

- (void)webServerDidRequestShutdown:(FBWebServer *)webServer
{
  [webServer stopServing];
}

@end
