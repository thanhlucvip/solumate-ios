#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <stdlib.h>

static void SoluSetValueSafely(id object, NSString *key, id value)
{
  if (!object || !key || !value) {
    return;
  }
  @try {
    [object setValue:value forKey:key];
  } @catch (NSException *exception) {
    NSLog(@"[SolumateBootstrap] Skip XCTestConfiguration.%@: %@", key, exception.reason);
  }
}

static void SoluSetBoolSafely(id object, NSString *key, BOOL value)
{
  SoluSetValueSafely(object, key, @(value));
}

static NSString *SoluEnvString(NSString *name)
{
  const char *value = getenv(name.UTF8String);
  return value ? [NSString stringWithUTF8String:value] : nil;
}

static void SoluSetEnvIfMissing(NSString *name, NSString *value)
{
  if (name.length == 0 || value.length == 0 || SoluEnvString(name).length > 0) {
    return;
  }
  setenv(name.UTF8String, value.UTF8String, 0);
}

__attribute__((constructor))
static void SolumateBootstrapInstall(void)
{
  @autoreleasepool {
    if ([SoluEnvString(@"SOLUMATE_BOOTSTRAP_DISABLE") isEqualToString:@"1"]) {
      NSLog(@"[SolumateBootstrap] Disabled by SOLUMATE_BOOTSTRAP_DISABLE=1");
      return;
    }

    if (SoluEnvString(@"XCTestConfigurationFilePath").length > 0) {
      NSLog(@"[SolumateBootstrap] XCTestConfigurationFilePath already exists, leaving host-provided config untouched");
      return;
    }

    NSBundle *mainBundle = NSBundle.mainBundle;
    NSString *appPath = mainBundle.bundlePath;
    NSString *testBundlePath = [appPath stringByAppendingPathComponent:@"PlugIns/WebDriverAgentRunner.xctest"];
    NSString *testInfoPath = [testBundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *testInfo = [NSDictionary dictionaryWithContentsOfFile:testInfoPath] ?: @{};
    NSString *testBundleIdentifier = testInfo[@"CFBundleIdentifier"] ?: mainBundle.bundleIdentifier;
    NSString *productModuleName = SoluEnvString(@"SOLUMATE_WDA_PRODUCT_MODULE") ?: @"WebDriverAgentRunner";
    NSString *automationFrameworkPath = SoluEnvString(@"SOLUMATE_WDA_AUTOMATION_FRAMEWORK")
      ?: @"/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework";

    if (![[NSFileManager defaultManager] fileExistsAtPath:testBundlePath]) {
      NSLog(@"[SolumateBootstrap] Test bundle not found at %@", testBundlePath);
      return;
    }

    Class configurationClass = NSClassFromString(@"XCTestConfiguration");
    if (!configurationClass) {
      NSLog(@"[SolumateBootstrap] XCTestConfiguration class is not available");
      return;
    }

    NSUUID *sessionIdentifier = NSUUID.UUID;
    NSString *configurationPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"%@.xctestconfiguration", sessionIdentifier.UUIDString.lowercaseString]];

    id configuration = [[configurationClass alloc] init];
    SoluSetValueSafely(configuration, @"testBundleURL", [NSURL fileURLWithPath:testBundlePath]);
    SoluSetValueSafely(configuration, @"productModuleName", productModuleName);
    SoluSetValueSafely(configuration, @"sessionIdentifier", sessionIdentifier);
    SoluSetValueSafely(configuration, @"targetApplicationPath", appPath);
    SoluSetValueSafely(configuration, @"targetApplicationBundleID", testBundleIdentifier);
    SoluSetValueSafely(configuration, @"automationFrameworkPath", automationFrameworkPath);
    SoluSetValueSafely(configuration, @"aggregateStatisticsBeforeCrash", @{@"XCSuiteRecordsKey": @{}});
    SoluSetBoolSafely(configuration, @"reportResultsToIDE", YES);
    SoluSetBoolSafely(configuration, @"reportActivities", YES);
    SoluSetBoolSafely(configuration, @"testsMustRunOnMainThread", YES);
    SoluSetBoolSafely(configuration, @"initializeForUITesting", YES);
    SoluSetBoolSafely(configuration, @"emitOSLogs", NO);

    SEL writeSelector = NSSelectorFromString(@"writeToFile:");
    BOOL wroteConfiguration = NO;
    if ([configuration respondsToSelector:writeSelector]) {
      wroteConfiguration = ((BOOL (*)(id, SEL, id))objc_msgSend)(configuration, writeSelector, configurationPath);
    }

    if (!wroteConfiguration) {
      NSLog(@"[SolumateBootstrap] Failed to write XCTest configuration to %@", configurationPath);
      return;
    }

    SEL setActiveSelector = NSSelectorFromString(@"setActiveTestConfiguration:");
    if ([configurationClass respondsToSelector:setActiveSelector]) {
      ((void (*)(id, SEL, id))objc_msgSend)(configurationClass, setActiveSelector, configuration);
    }

    setenv("XCTestConfigurationFilePath", configurationPath.UTF8String, 1);
    setenv("XCTestBundlePath", testBundlePath.UTF8String, 1);
    setenv("XCTestSessionIdentifier", sessionIdentifier.UUIDString.lowercaseString.UTF8String, 1);
    SoluSetEnvIfMissing(@"USE_PORT", @"8000");
    SoluSetEnvIfMissing(@"MJPEG_SERVER_PORT", @"8001");
    SoluSetEnvIfMissing(@"H264_SERVER_PORT", @"-1");
    SoluSetEnvIfMissing(@"WDA_REALTIME_CONTROL_ENABLED", @"1");
    SoluSetEnvIfMissing(@"WDA_REALTIME_CONTROL_PORT", @"8003");

    NSLog(@"[SolumateBootstrap] Installed manual-launch XCTest config at %@", configurationPath);
  }
}
