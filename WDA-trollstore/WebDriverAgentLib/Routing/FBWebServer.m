/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBWebServer.h"

#import "RoutingConnection.h"
#import "RoutingHTTPServer.h"

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBH264Server.h"
#import "FBMjpegServer.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBRealtimeControlServer.h"
#import "FBTCPSocket.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"

#import "XCUIDevice+FBHelpers.h"

static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

@interface FBHTTPConnection : RoutingConnection
@end

@implementation FBHTTPConnection

- (void)handleResourceNotFound
{
  [FBLogger logFmt:@"Received request for %@ which we do not handle", self.requestURI];
  [super handleResourceNotFound];
}

@end


@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) RoutingHTTPServer *server;
@property (atomic, assign) BOOL keepAlive;
@property (nonatomic, nullable) FBTCPSocket *screenshotsBroadcaster;
@property (nonatomic, nullable, strong) FBMjpegServer *mjpegServer;
@property (nonatomic, nullable) FBTCPSocket *h264Broadcaster;
@property (nonatomic, nullable, strong) FBH264Server *h264Server;
@property (nonatomic, nullable) FBTCPSocket *realtimeControlSocket;
@property (nonatomic, nullable, strong) FBRealtimeControlServer *realtimeControlServer;
@end

@implementation FBWebServer

- (void)dealloc
{
  [self stopScreenshotsBroadcaster];
  [self stopH264Broadcaster];
  [self stopRealtimeControlServer];
}

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  [self startHTTPServer];
  [self initScreenshotsBroadcaster];
  [self initH264Broadcaster];
  [self initRealtimeControlServer];

  self.keepAlive = YES;
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive &&
         [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}

- (void)startHTTPServer
{
  self.server = [[RoutingHTTPServer alloc] init];
  [self.server setRouteQueue:dispatch_get_main_queue()];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  NSString *allowedCORSOrigin = FBConfiguration.allowedCORSOrigin;
  if (allowedCORSOrigin.length > 0) {
    [self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:allowedCORSOrigin];
    [self.server setDefaultHeader:@"Access-Control-Allow-Headers" value:@"Authorization, Content-Type, X-Requested-With, X-WDA-Auth, X-WDA-Token"];
    [self.server setDefaultHeader:@"Access-Control-Allow-Methods" value:@"GET, POST, PUT, DELETE, OPTIONS"];
  }
  [self.server setConnectionClass:[FBHTTPConnection self]];

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.bindingPortRange;
  NSString *bindingIP = FBConfiguration.bindingIPAddress;
  if (bindingIP != nil) {
    [self.server setInterface:bindingIP];
    [FBLogger logFmt:@"Using custom binding IP address: %@", bindingIP];
  } else {
    [FBLogger log:@"Binding HTTP server to all interfaces because WDA_BIND_ALL_INTERFACES=1 or USE_IP explicitly requested it"];
  }

  if (FBConfiguration.requiresAuthentication && !FBConfiguration.isAuthenticationConfigured) {
    [FBLogger log:@"WDA authentication is required but WDA_AUTH_TOKEN is not configured; protected routes will reject requests"];
  }
  
  NSError *error;
  BOOL serverStarted = NO;

  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];

    serverStarted = [self attemptToStartServer:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }

    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }

  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    abort();
  }
  
  NSString *serverHost = bindingIP ?: ([XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"127.0.0.1");
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, serverHost, [self.server port], FBServerURLEndMarker];
}

- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.mjpegServer = [[FBMjpegServer alloc] init];
  NSString *streamBindingIP = FBConfiguration.streamBindingIPAddress;
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.mjpegServerPort
                                 interface:streamBindingIP];
  self.screenshotsBroadcaster.delegate = self.mjpegServer;
  NSError *error;
  if (![self.screenshotsBroadcaster startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init screenshots broadcaster service on port %@. Original error: %@", @(FBConfiguration.mjpegServerPort), error.description];
    [self.mjpegServer stopStreaming];
    self.mjpegServer = nil;
    self.screenshotsBroadcaster = nil;
  } else {
    [FBLogger logFmt:@"MJPEG stream server started on %@:%@", streamBindingIP ?: @"0.0.0.0", @(FBConfiguration.mjpegServerPort)];
  }
}

- (void)stopScreenshotsBroadcaster
{
  if (nil == self.screenshotsBroadcaster) {
    self.mjpegServer = nil;
    return;
  }

  id<FBTCPSocketDelegate> delegate = self.screenshotsBroadcaster.delegate;
  if ([(NSObject *)delegate respondsToSelector:@selector(stopStreaming)]) {
    [(FBMjpegServer *)delegate stopStreaming];
  }
  self.screenshotsBroadcaster.delegate = nil;
  [self.screenshotsBroadcaster stop];
  self.screenshotsBroadcaster = nil;
  self.mjpegServer = nil;
}

- (void)initH264Broadcaster
{
  NSInteger port = FBConfiguration.h264ServerPort;
  if (port < 1) {
    return;
  }
  self.h264Server = [[FBH264Server alloc] init];
  NSString *streamBindingIP = FBConfiguration.streamBindingIPAddress;
  self.h264Broadcaster = [[FBTCPSocket alloc] initWithPort:(uint16_t)port
                                                 interface:streamBindingIP];
  self.h264Broadcaster.delegate = self.h264Server;
  NSError *error;
  if (![self.h264Broadcaster startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init H264 broadcaster on port %@. Original error: %@", @(port), error.description];
    [self.h264Server stopStreaming];
    self.h264Server = nil;
    self.h264Broadcaster = nil;
  } else {
    [FBLogger logFmt:@"H264 hardware stream server started on %@:%@", streamBindingIP ?: @"0.0.0.0", @(port)];
  }
}

- (void)initRealtimeControlServer
{
  if (!FBConfiguration.realtimeControlEnabled) {
    return;
  }

  NSInteger port = FBConfiguration.realtimeControlPort;
  if (port < 1) {
    return;
  }

  self.realtimeControlServer = [[FBRealtimeControlServer alloc] init];
  NSString *bindingIP = FBConfiguration.realtimeControlBindingIPAddress;
  self.realtimeControlSocket = [[FBTCPSocket alloc] initWithPort:(uint16_t)port
                                                       interface:bindingIP];
  self.realtimeControlSocket.delegate = self.realtimeControlServer;
  NSError *error;
  if (![self.realtimeControlSocket startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init realtime control socket on port %@. Original error: %@", @(port), error.description];
    [self.realtimeControlServer stop];
    self.realtimeControlServer = nil;
    self.realtimeControlSocket = nil;
  } else {
    [FBLogger logFmt:@"Realtime control socket started on %@:%@", bindingIP ?: @"0.0.0.0", @(port)];
  }
}

- (void)stopRealtimeControlServer
{
  if (nil == self.realtimeControlSocket) {
    self.realtimeControlServer = nil;
    return;
  }
  [self.realtimeControlServer stop];
  self.realtimeControlSocket.delegate = nil;
  [self.realtimeControlSocket stop];
  self.realtimeControlSocket = nil;
  self.realtimeControlServer = nil;
}

- (void)stopH264Broadcaster
{
  if (nil == self.h264Broadcaster) {
    self.h264Server = nil;
    return;
  }
  [self.h264Server stopStreaming];
  self.h264Broadcaster.delegate = nil;
  [self.h264Broadcaster stop];
  self.h264Broadcaster = nil;
  self.h264Server = nil;
}

- (void)readMjpegSettingsFromEnv
{
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *scalingFactor = [env objectForKey:@"MJPEG_SCALING_FACTOR"];
  if (scalingFactor != nil && [scalingFactor length] > 0) {
    [FBConfiguration setMjpegScalingFactor:[scalingFactor floatValue]];
  }
  NSString *screenshotQuality = [env objectForKey:@"MJPEG_SERVER_SCREENSHOT_QUALITY"];
  if (screenshotQuality != nil && [screenshotQuality length] > 0) {
    [FBConfiguration setMjpegServerScreenshotQuality:[screenshotQuality integerValue]];
  }
  NSString *framerate = [env objectForKey:@"MJPEG_SERVER_FRAMERATE"];
  if (framerate == nil || 0 == framerate.length) {
    framerate = [env objectForKey:@"MJPEG_FRAMERATE"];
  }
  if (framerate != nil && [framerate length] > 0) {
    [FBConfiguration setMjpegServerFramerate:[framerate integerValue]];
  }
  NSString *fixOrientation = [env objectForKey:@"MJPEG_FIX_ORIENTATION"];
  if (fixOrientation != nil && [fixOrientation length] > 0) {
    [FBConfiguration setMjpegShouldFixOrientation:[fixOrientation boolValue]];
  }
}

- (void)stopServing
{
  [FBSession.activeSession kill];
  [self stopScreenshotsBroadcaster];
  [self stopH264Broadcaster];
  [self stopRealtimeControlServer];
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.keepAlive = NO;
}

- (BOOL)attemptToStartServer:(RoutingHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }

    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (BOOL)dispatchUnauthorizedIfNeededForRequest:(RouteRequest *)request
                                      response:(RouteResponse *)response
{
  if ([[request method] isEqualToString:@"OPTIONS"]) {
    return NO;
  }
  if ([FBConfiguration isRequestAuthorizedWithHeaders:request.headers
                                     queryParameters:request.params]) {
    return NO;
  }

  NSString *message = FBConfiguration.isAuthenticationConfigured
    ? @"Authentication is required for this WebDriverAgent endpoint"
    : @"Authentication is required but WDA_AUTH_TOKEN is not configured";
  [response setHeader:@"WWW-Authenticate" value:@"Bearer"];
  [FBResponseWithStatus([FBCommandStatus authorizationErrorWithMessage:message traceback:nil])
    dispatchWithResponse:response];
  return YES;
}

- (BOOL)dispatchBodyTooLargeIfNeededForRequest:(RouteRequest *)request
                                      response:(RouteResponse *)response
{
  NSUInteger maxBodySize = FBConfiguration.maximumHTTPRequestBodySize;
  if (request.body.length <= maxBodySize) {
    return NO;
  }

  NSString *message = [NSString stringWithFormat:@"Request body exceeds the configured limit of %@ bytes",
                       @(maxBodySize)];
  [FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:message traceback:nil])
    dispatchWithResponse:response];
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path block:^(RouteRequest *request, RouteResponse *response) {
        if ([self dispatchUnauthorizedIfNeededForRequest:request response:response] ||
            [self dispatchBodyTooLargeIfNeededForRequest:request response:response]) {
          return;
        }

        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
        ];

        [FBLogger verboseLog:routeParams.description];

        @try {
          [route mountRequest:routeParams intoResponse:response];
        }
        @catch (NSException *exception) {
          [self handleException:exception forResponse:response];
        }
      }];
    }
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  [self.exceptionHandler handleException:exception forResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server get:@"/health" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"<!DOCTYPE html><html><title>Health Check</title><body><p>I-AM-ALIVE</p></body></html>"];
  }];

  NSString *calibrationPage = @"<html>"
  "<title>{\"x\":null,\"y\":null}</title>"
  "<header>"
  "<script>document.addEventListener(\"click\",function(e){document.title=JSON.stringify({x:e.clientX,y:e.clientY})})</script>"
  "</header>"
  "</html>";
  [self.server get:@"/calibrate" withBlock:^(RouteRequest *request, RouteResponse *response) {
    if ([self dispatchUnauthorizedIfNeededForRequest:request response:response]) {
      return;
    }
    [response respondWithString:calibrationPage];
  }];

  [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
    if ([self dispatchUnauthorizedIfNeededForRequest:request response:response]) {
      return;
    }
    [response respondWithString:@"Shutting down"];
    [self.delegate webServerDidRequestShutdown:self];
  }];

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
