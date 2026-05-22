//
//  ScrcpySDLWrapper.m
//  Scrcpy Remote
//
//  Created by Ethan on 12/15/24.
//

#import "ScrcpyClientWrapper.h"
#import "ScrcpyBlockWrapper.h"

#import <objc/runtime.h>
#import <SDL3/SDL.h>

#import "ScrcpyVNCClient.h"
#import "ScrcpyADBClient.h"
#import "ScrcpyCommon.h"
#import "ADBClient.h"

@interface ScrcpyClientWrapper ()

// VNC Client
@property (nonatomic, strong) ScrcpyVNCClient *vncClient;
// ADB Client
@property (nonatomic, strong) ScrcpyADBClient *adbClient;

// Track current active client
@property (nonatomic, weak) id<ScrcpyClientProtocol> currentActiveClient;

@end

@implementation ScrcpyClientWrapper

- (instancetype)init
{
    self = [super init];
    if (self) {
    }
    return self;
}

- (UIWindow *)keyWindowForScene:(UIScene *)scene {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

- (ScrcpyADBClient *)adbClient {
    if (!_adbClient) {
        _adbClient = [[ScrcpyADBClient alloc] init];
    }
    return _adbClient;
}

- (ScrcpyVNCClient *)vncClient {
    if (!_vncClient) {
        _vncClient = [[ScrcpyVNCClient alloc] init];
    }
    return _vncClient;
}

- (void)startClient:(NSDictionary *)arguments completion:(nonnull void (^)(enum ScrcpyStatus, NSString * _Nonnull))completion {
    NSLog(@"SDL_main start");
    NSDictionary *deviceClients = @{
        @"adb": self.adbClient,
        @"vnc": self.vncClient
    };
    
    NSString *deviceType = arguments[@"deviceType"];
    if (!deviceType || ![deviceClients.allKeys containsObject:deviceType]) {
        NSLog(@"Unsupported device type: %@", deviceType);
        if (completion) {
            completion(ScrcpyStatusConnectingFailed, @"Unsupported device type");
        }
        return;
    }
    
    id<ScrcpyClientProtocol> deviceClient = deviceClients[deviceType];
    
    // Track current active client
    self.currentActiveClient = deviceClient;
    
    if ([deviceClient respondsToSelector:@selector(startWithArguments:completion:)]) {
        [deviceClient startWithArguments:arguments completion:completion];
    }
}

- (void)disconnectCurrentClient {
    NSLog(@"🔌 [ScrcpyClientWrapper] Disconnecting current client");
    
    if (self.currentActiveClient && [self.currentActiveClient respondsToSelector:@selector(disconnect)]) {
        [self.currentActiveClient disconnect];
        self.currentActiveClient = nil;
        NSLog(@"✅ [ScrcpyClientWrapper] Current client disconnected");
    } else {
        NSLog(@"ℹ️ [ScrcpyClientWrapper] No active client to disconnect");
    }
}

#pragma mark - Action Execution Methods

- (void)executeVNCActions:(NSArray<NSNumber *> *)vncActions completion:(void(^)(BOOL success, NSString *error))completion {
    NSLog(@"🖥️ [ScrcpyClientWrapper] Executing %lu VNC actions", (unsigned long)vncActions.count);
    
    // 检查当前客户端是否是 VNC 客户端
    if (![self.currentActiveClient isKindOfClass:[ScrcpyVNCClient class]]) {
        NSLog(@"❌ [ScrcpyClientWrapper] Current client is not VNC client, cannot execute VNC actions");
        if (completion) {
            completion(0, @"Current client is not VNC client, cannot execute VNC actions");
        }
        return;
    }
    
    ScrcpyVNCClient *vncClient = (ScrcpyVNCClient *)self.currentActiveClient;
    [vncClient executeVNCActions:vncActions completion:completion];
}

- (void)executeADBHomeKeyOnDevice:(NSString *)deviceSerial completion:(void (^)(NSString * _Nullable output, int returnCode))completion {
    NSLog(@"🏠 [ScrcpyClientWrapper] Executing ADB Home key on device: %@", deviceSerial);
    
    // 检查当前客户端是否是 ADB 客户端
    if (![self.currentActiveClient isKindOfClass:[ScrcpyADBClient class]]) {
        NSLog(@"❌ [ScrcpyClientWrapper] Current client is not ADB client, cannot execute ADB actions");
        if (completion) {
            completion(@"Current client is not ADB client", -1);
        }
        return;
    }
    
    // 通过 ADBClient.shared 执行（这里仍然需要访问实际的 ADB 功能）
    ADBClient *adbClient = [ADBClient shared];
    [adbClient executeHomeKeyOnDevice:deviceSerial completion:completion];
}

- (void)executeADBSwitchKeyOnDevice:(NSString *)deviceSerial completion:(void (^)(NSString * _Nullable output, int returnCode))completion {
    NSLog(@"🔀 [ScrcpyClientWrapper] Executing ADB Switch key on device: %@", deviceSerial);
    
    // 检查当前客户端是否是 ADB 客户端
    if (![self.currentActiveClient isKindOfClass:[ScrcpyADBClient class]]) {
        NSLog(@"❌ [ScrcpyClientWrapper] Current client is not ADB client, cannot execute ADB actions");
        if (completion) {
            completion(@"Current client is not ADB client", -1);
        }
        return;
    }
    
    // 通过 ADBClient.shared 执行
    ADBClient *adbClient = [ADBClient shared];
    [adbClient executeSwitchKeyOnDevice:deviceSerial completion:completion];
}

- (void)executeADBKeySequence:(NSArray<NSNumber *> *)keyCodes
                     onDevice:(NSString *)deviceSerial
                     interval:(NSInteger)intervalMs
                   completion:(void(^)(NSInteger successCount, NSString *error))completion {
    NSLog(@"⌨️ [ScrcpyClientWrapper] Executing ADB key sequence on device: %@", deviceSerial);
    
    // 检查当前客户端是否是 ADB 客户端
    if (![self.currentActiveClient isKindOfClass:[ScrcpyADBClient class]]) {
        NSLog(@"❌ [ScrcpyClientWrapper] Current client is not ADB client, cannot execute ADB actions");
        if (completion) {
            completion(0, @"Current client is not ADB client");
        }
        return;
    }
    
    // 通过 ADBClient.shared 执行
    ADBClient *adbClient = [ADBClient shared];
    [adbClient executeKeySequence:keyCodes onDevice:deviceSerial interval:intervalMs completion:completion];
}

- (void)executeADBShellCommands:(NSArray<NSString *> *)commands
                       onDevice:(NSString *)deviceSerial
                       interval:(NSInteger)intervalMs
                     completion:(void(^)(BOOL success, NSString *error))completion {
    NSLog(@"💻 [ScrcpyClientWrapper] Executing ADB shell commands on device: %@", deviceSerial);
    
    // 检查当前客户端是否是 ADB 客户端
    if (![self.currentActiveClient isKindOfClass:[ScrcpyADBClient class]]) {
        NSLog(@"❌ [ScrcpyClientWrapper] Current client is not ADB client, cannot execute ADB actions");
        if (completion) {
            completion(0, @"Current client is not ADB client");
        }
        return;
    }
    
    // 通过 ADBClient.shared 执行
    ADBClient *adbClient = [ADBClient shared];
    [adbClient executeShellCommands:commands onDevice:deviceSerial interval:intervalMs completion:completion];
}

@end
