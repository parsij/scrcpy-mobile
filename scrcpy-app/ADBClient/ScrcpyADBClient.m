//
//  ScrcpyADBClient.m
//  Scrcpy Remote
//
//  Created by Ethan on 12/16/24.
//

#import <UIKit/UIKit.h>

#import "ScrcpyADBClient.h"
#import "ADBClient.h"
#import "ScrcpyClientWrapper.h"
#import <SDL3/SDL.h>
#import <libavutil/frame.h>
#import <libavutil/imgutils.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AVFoundation/AVFoundation.h>
#import "ScrcpyCommon.h"
#import "ScrcpyRuntime.h"

// C function implementation
// SDL3: SDL_KeyboardEvent.keysym was flattened into the event (key /
// scancode / mod); .state was replaced by .down (bool); .repeat became bool.
void ScrcpySendKeycodeEvent(SDL_Scancode scancode, SDL_Keycode keycode, SDL_Keymod keymod) {
    // Send key down event
    {
        SDL_Event event;
        SDL_memset(&event, 0, sizeof(event));
        event.type = SDL_EVENT_KEY_DOWN;
        event.key.type = SDL_EVENT_KEY_DOWN;
        event.key.scancode = scancode;
        event.key.key = keycode;
        event.key.mod = keymod;
        event.key.down = true;
        event.key.repeat = false;
        SDL_PushEvent(&event);
        NSLog(@"KEYDOWN EVENT: Post Success");
    }

    // Send key up event
    {
        SDL_Event event;
        SDL_memset(&event, 0, sizeof(event));
        event.type = SDL_EVENT_KEY_UP;
        event.key.type = SDL_EVENT_KEY_UP;
        event.key.scancode = scancode;
        event.key.key = keycode;
        event.key.mod = keymod;
        event.key.down = false;
        event.key.repeat = false;
        SDL_PushEvent(&event);
        NSLog(@"KEYUP EVENT: Post Success");
    }
}

void ScrcpyTryResetVideo(void) {
    static NSTimeInterval lastResetTime = 0;
    static int resetCountInWindow = 0;
    static NSTimeInterval windowStartTime = 0;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    // Basic cooldown: at least 1 second between resets
    if (now - lastResetTime < 1.0) {
        return;
    }

    // Rate limiting: max 3 resets per 10 seconds to avoid excessive resets
    // This prevents runaway reset loops in persistently problematic scenarios
    if (now - windowStartTime > 10.0) {
        // Start a new 10-second window
        windowStartTime = now;
        resetCountInWindow = 0;
    }

    if (resetCountInWindow >= 3) {
        // Already hit the limit for this window, skip
        static NSTimeInterval lastSkipLogTime = 0;
        if (now - lastSkipLogTime > 5.0) {
            NSLog(@"⏳ [Render] Reset rate limited, waiting for cooldown");
            lastSkipLogTime = now;
        }
        return;
    }

    // Perform the reset
    ScrcpySendKeycodeEvent(SDL_SCANCODE_R, SDLK_r, SDL_KMOD_LCTRL | SDL_KMOD_SHIFT);
    resetCountInWindow++;
    lastResetTime = now;

    NSLog(@"🔄 [Render] Video reset requested (count in window: %d/3)", resetCountInWindow);
}

@interface ScrcpyADBClient () <ScrcpyClientProtocol>

@property (nonatomic, strong)  SDLUIKitDelegate  *sdlDelegate;
@property (nonatomic, copy) void (^sessionCompletion)(enum ScrcpyStatus, NSString *);
@property (nonatomic, copy) NSDictionary  *sessionArguments;

// Property for scrcpy status
@property (nonatomic, assign) enum ScrcpyStatus scrcpyStatus;

// Background timer to control bakcground activities
@property (nonatomic, strong) NSTimer *backgroundTimer;
@property (nonatomic, assign) NSTimeInterval lastBackgroundCheckTime;

@end

@implementation ScrcpyADBClient

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onScrcpyStatusUpdated:)
                                                     name:ScrcpyStatusUpdatedNotificationName
                                                   object:nil];
        
        // Observe application enter background
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onApplicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        // Observe application enter foreground
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onApplicationDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        
        // Observe disconnect event from scrcpy menu view
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stopScrcpy)
                                                     name:ScrcpyRequestDisconnectNotification
                                                   object:nil];
        
        // Observe ADB key event execution
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(executeADBKeyEvent:)
                                                     name:@"ExecuteADBKeyEvent"
                                                   object:nil];
        
        // Observe ADB Home key execution
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(executeADBHomeKey:)
                                                     name:@"ExecuteADBHomeKey"
                                                   object:nil];
        
        // Observe ADB Switch key execution
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(executeADBSwitchKey:)
                                                     name:@"ExecuteADBSwitchKey"
                                                   object:nil];
        
        // Observe ADB input keys execution
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(executeADBInputKeys:)
                                                     name:@"ExecuteADBInputKeys"
                                                   object:nil];
        
        // Observe ADB shell commands execution
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(executeADBShellCommands:)
                                                     name:@"ExecuteADBShellCommands"
                                                   object:nil];
    }
    return self;
}

-(void)dealloc {
    if (_backgroundTimer) {
        [_backgroundTimer invalidate];
        _backgroundTimer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIWindowScene *)currentScene {
    return GetCurrentWindowScene();
}

- (void)setupScrcpyEnvs {
    // Scrcpy SCRCPY_SERVER_PATH to find scrcpy-server under main app bundle
    NSString *serverPath = [[NSBundle mainBundle] pathForResource:@"scrcpy-server" ofType:@""];
    NSLog(@"→ Scrcpy server path: %@", serverPath);
    setenv("SCRCPY_SERVER_PATH", serverPath.UTF8String, 1);
}

- (void)startWithArguments:(NSDictionary *)arguments completion:(void (^)(enum ScrcpyStatus, NSString *))completion {
    NSLog(@"🟢 Starting connect ADB device..");
    
    // Init scrcpy status
    self.scrcpyStatus = ScrcpyStatusDisconnected;
    
    [self setupScrcpyEnvs];
    
    NSString *host = arguments[@"hostReal"];
    NSString *port = arguments[@"port"];
    NSString *serial = [NSString stringWithFormat:@"%@:%@", host, port];

    // Update session completion and arguments
    self.sessionCompletion = completion;
    self.sessionArguments = arguments;
    
    // First kill the ADB server before connecting
    __weak typeof(self) weakSelf = self;
    // Now connect to the ADB device
    [ADBClient.shared executeADBCommandAsync:@[@"connect", serial] callback:^(NSString * _Nullable connectResult, int returnCode) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSLog(@"ADB Result: %@, %@", connectResult, @(returnCode));
        NSArray *connectedDevices = [ADBClient.shared adbDevices];
        NSLog(@"ADB Devices: %@", connectedDevices);
        
        NSString *authTips = @"\n\nPlease check and accpet the adb authorization request on your device.";
        
        if (returnCode != 0 || [connectResult containsString:@"failed"]) {
            NSLog(@"❌ ADB connect failed: %@", connectResult);
            ScrcpyUpdateStatus(ScrcpyStatusConnectingFailed, [connectResult stringByAppendingString:authTips].UTF8String);
            return;
        }
        
        // Check if the device is connected
        if (connectedDevices.count == 0) {
            NSLog(@"❌ No ADB devices connected");
            ScrcpyUpdateStatus(ScrcpyStatusConnectingFailed, "No ADB devices connected");
            return;
        }
        
        // Check if the serial matches the connected device
        for (ADBDevice *device in connectedDevices) {
            if ([device.serial isEqualToString:serial] && device.status != ADBDeviceStatusDevice) {
                NSLog(@"🦺 ADB device connected status: %@", device);
                NSString *errorMessage = [NSString stringWithFormat:@"Device connect status:\n%@ -> %@%@", device.serial, device.statusText, authTips];
                ScrcpyUpdateStatus(ScrcpyStatusConnectingFailed, errorMessage.UTF8String);
                return;
            }
        }
        
        // Notify completion when ADB connected
        strongSelf.sessionCompletion(ScrcpyStatusADBConnected, connectResult);
        
        // Perform selector to prevent runloop hang, this will cause view not rendering
        [self performSelectorOnMainThread:@selector(startScrcpy:) withObject:serial waitUntilDone:NO];
    }];
}

- (NSString *)optionArgumentKeyMapping:(NSString *)key {
    NSDictionary *supportedOptions = @{
        @"maxScreenSize": @"--max-size",
        @"bitRate": @"--video-bit-rate",
        @"videoBitRate": @"--video-bit-rate",
        @"maxFPS": @"--max-fps",
        @"videoCodec": @"--video-codec",
        @"videoEncoder": @"--video-encoder",
        @"audioCodec": @"--audio-codec",
        @"audioEncoder": @"--audio-encoder",
        @"videoBuffer": @"--video-buffer",
        @"turnScreenOff": @"--turn-screen-off",
        @"stayAwake": @"--stay-awake",
        @"powerOffOnClose": @"--power-off-on-close",
        @"noCleanup": @"--no-cleanup",
        @"forceAdbForward": @"--force-adb-forward",
        @"displayId": @"--display-id",
    };
    return supportedOptions[key] ?: nil;
}

- (NSString *)reverseOptionArgumentKeyMapping:(NSString *)key {
    NSDictionary *supportedOptions = @{
        @"enableAudio": @"--no-audio",
        @"enableClipboardSync": @"--no-clipboard-autosync",
    };
    return supportedOptions[key] ?: nil;
}

- (NSArray *)buildScrcpyArgs:(NSString *)serial {
    // Default arguments init
    NSMutableDictionary *args = [NSMutableDictionary dictionaryWithDictionary:@{
#ifdef DEBUG
        @"--verbosity": @"debug",
#endif
        @"--fullscreen": @(YES),
        @"--video-codec": @"h264",
        @"--video-buffer": @"0",
        @"--audio-buffer": @"150",
        @"--print-fps": @(YES),
        @"--video-bit-rate": @"4M",
        @"--serial": serial,
        @"--audio-output-buffer": @"10",
        @"--shortcut-mod": @"lctrl,rctrl,lalt,ralt",
    }];
    
    // Check if new display is enabled and add --new-display argument
    if (self.sessionArguments[@"adbOptions"][@"startNewDisplay"] && 
        [self.sessionArguments[@"adbOptions"][@"startNewDisplay"] boolValue]) {
        
        // Build new display string based on user configuration
        NSString *displayWidth = self.sessionArguments[@"adbOptions"][@"displayWidth"];
        NSString *displayHeight = self.sessionArguments[@"adbOptions"][@"displayHeight"];
        NSString *displayDPI = self.sessionArguments[@"adbOptions"][@"displayDPI"];
        
        NSMutableString *newDisplayValue = [NSMutableString string];
        
        // Add width and height if provided
        if (displayWidth && displayWidth.length > 0 && displayHeight && displayHeight.length > 0) {
            [newDisplayValue appendFormat:@"%@x%@", displayWidth, displayHeight];
        }
        
        // Add DPI if provided  
        if (displayDPI && displayDPI.length > 0) {
            if (newDisplayValue.length > 0) {
                [newDisplayValue appendFormat:@"/%@", displayDPI];
            } else {
                [newDisplayValue appendFormat:@"/%@", displayDPI];
            }
        }
        
        // Use the new display value or default if empty
        if (newDisplayValue.length > 0) {
            [args setObject:newDisplayValue forKey:@"--new-display"];
        } else {
            [args setObject:@(YES) forKey:@"--new-display"];
        }
    }
    
    // Merge with session arguments
    for (NSString *key in self.sessionArguments[@"adbOptions"]) {
        if ([@[@"id", @"startNewDisplay", @"volumeScale"] containsObject:key]) {
            continue;
        }
        
        // Skip display parameters as they are handled by --new-display
        if ([@[@"displayWidth", @"displayHeight", @"displayDPI"] containsObject:key]) {
            continue;
        }
        
        // Check reverse option which should be removed
        NSString *reverseKey = [self reverseOptionArgumentKeyMapping:key];
        if (reverseKey) {
            id reverseValue = self.sessionArguments[@"adbOptions"][key];
            if ([reverseValue isKindOfClass:[NSNumber class]] && [reverseValue boolValue] == NO) {
                [args setObject:@(YES) forKey:reverseKey];
            }
            continue;
        }
        
        NSString *argKey = [self optionArgumentKeyMapping:key];
        if (!argKey) {
            NSLog(@"⚠️ Unsupported option key: %@", key);
            continue;
        }
        
        id argValue = self.sessionArguments[@"adbOptions"][key];
        
        // Handle boolean values
        if ([argValue isKindOfClass:[NSNumber class]]) {
            if ([argValue boolValue] == YES) {
                [args setObject:@(YES) forKey:argKey];
            }
            continue;
        }
        
        // Handle string values
        if ([argValue isKindOfClass:[NSString class]] && [(NSString *)argValue length] > 0) {
            args[argKey] = argValue;
            continue;
        }
        
        // Not supported options
        NSLog(@"⚠️ Unsupported option value: %@, %@", key, argValue);
    }
    
    // Handle customFlags - add custom parameters with "--" prefix
    NSDictionary *customFlags = self.sessionArguments[@"adbOptions"][@"customFlags"];
    if ([customFlags isKindOfClass:[NSDictionary class]]) {
        NSLog(@"🔧 Processing customFlags: %@", customFlags);
        for (NSString *flagName in customFlags) {
            NSString *flagValue = customFlags[flagName];
            
            // Add "--" prefix if not present
            NSString *scrcpyFlagName = [flagName hasPrefix:@"--"] ? flagName : [NSString stringWithFormat:@"--%@", flagName];
            
            if ([flagValue isEqualToString:@"true"] || [flagValue isEqualToString:@""]) {
                // Boolean flag
                [args setObject:@(YES) forKey:scrcpyFlagName];
                NSLog(@"🔧 Added custom boolean flag: %@", scrcpyFlagName);
            } else if ([flagValue isEqualToString:@"false"]) {
                // Skip false flags
                NSLog(@"🔧 Skipping false flag: %@", scrcpyFlagName);
                continue;
            } else {
                // Value flag
                [args setObject:flagValue forKey:scrcpyFlagName];
                NSLog(@"🔧 Added custom value flag: %@=%@", scrcpyFlagName, flagValue);
            }
        }
    }
    
    NSMutableArray *argv = [NSMutableArray arrayWithArray:@[@"scrcpy"]];
    for (NSString *key in args) {
        id value = args[key];
        if ([value isKindOfClass:NSNumber.class] && [value boolValue]) {
            [argv addObject:key];
        } else {
            [argv addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        }
    }
    
    return [argv copy];
}

- (void)startScrcpy:(NSString *)serial {
    self.scrcpyStatus = ScrcpyStatusConnecting;
    ScrcpyUpdateStatus(ScrcpyStatusConnecting, "Connecting to ADB device");
    
    // Init SDL Delegate
    [self.sdlDelegate application:[UIApplication sharedApplication] didFinishLaunchingWithOptions:nil];

    // Run a runloop time slice to response UI events
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, NO);
    
    SDL_iPhoneSetEventPump(SDL_TRUE);
    
    // Flush all events include the not proccessed SERVER_DISCONNECT events
    SDL_FlushEvents(0, 0xFFFF);
    
    // Update audio volume scale if audio is enabled
    ScrcpyAudioVolumeScale(1.0);
    if (self.sessionArguments && self.sessionArguments[@"adbOptions"]) {
        id enableAudio = self.sessionArguments[@"adbOptions"][@"enableAudio"];
        id volumeScale = self.sessionArguments[@"adbOptions"][@"volumeScale"];
        if ([enableAudio isKindOfClass:[NSNumber class]] && [enableAudio boolValue] && 
            [volumeScale isKindOfClass:[NSNumber class]]) {
            double scale = [volumeScale doubleValue];
            ScrcpyAudioVolumeScale(scale);
        }
    }
    
    // Setup hardware decoding based on session settings
    BOOL enableHardwareDecoding = YES; // Default to enabled
    if (self.sessionArguments && self.sessionArguments[@"adbOptions"]) {
        id hardwareDecodingSetting = self.sessionArguments[@"adbOptions"][@"enableHardwareDecoding"];
        if ([hardwareDecodingSetting isKindOfClass:[NSNumber class]]) {
            enableHardwareDecoding = [hardwareDecodingSetting boolValue];
        }
    }
    NSLog(@"Hardware decoding enabled: %@", enableHardwareDecoding ? @"YES" : @"NO");
    SetScrcpyHardwareDecodingEnabled(enableHardwareDecoding);

    // Setup follow remote orientation based on session settings
    BOOL followRemoteOrientation = NO; // Default to disabled
    if (self.sessionArguments && self.sessionArguments[@"adbOptions"]) {
        id followOrientationSetting = self.sessionArguments[@"adbOptions"][@"followRemoteOrientation"];
        if ([followOrientationSetting isKindOfClass:[NSNumber class]]) {
            followRemoteOrientation = [followOrientationSetting boolValue];
        }
    }
    SetScrcpyFollowRemoteOrientation(followRemoteOrientation);
    
    // Setup arguments
    NSArray *startArgs = [self buildScrcpyArgs:serial];
    NSLog(@"Starting scrcpy with arguments: %@", startArgs);
    
    char *args[(int)startArgs.count];
    for (int i = 0; i < startArgs.count; i++) {
        args[i] = (char *)[startArgs[i] UTF8String];
    }
    
    scrcpy_main((int)startArgs.count, (char **)args);
    SDL_iPhoneSetEventPump(SDL_FALSE);
    
    // Remove SDL event filter to avoid blocking events
    // This caused sync clipboard from remote not working
    // See: #2    0x00000001053520dc in sc_post_to_main_thread at /Users/ethan/Src/github.com/scrcpy-mobile/scrcpy/app/src/events.c:33
    // #1    0x0000000102127528 in SDL_PushEvent at /Users/ethan/Downloads/SDL2-2.0.22/src/events/SDL_events.c:1110
    // Clipboard update event is not processed by SDL event filter
    NSLog(@"Removing SDL event filter to avoid blocking events");
    SDL_SetEventFilter(NULL, NULL);
}

-(void)stopScrcpy {
    // Call SQL_Quit to send Quit Event
    SDL_Event event;
    event.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&event);
    
    // 使用新的 ScrcpyUpdateStatus 函数发送断开连接状态通知
    ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "User disconnected from ADB client");
    
    NSLog(@"🔌 [ScrcpyADBClient] Disconnection initiated - status notification sent");
}

#pragma mark - ScrcpyClientProtocol

-(void)disconnect {
    NSLog(@"🔌 [ScrcpyADBClient] disconnect method called");
    [self stopScrcpy];
}

#pragma mark - Scrcpy Events

-(void)syncClipboard {
    NSLog(@"-> Syncing clipboard");
    SDL_Event clip_event;
    clip_event.type = SDL_EVENT_CLIPBOARD_UPDATE;

    BOOL posted = (SDL_PushEvent(&clip_event) > 0);
    NSLog(@"Clipboard event: Post %@", posted? @"Success" : @"Failed");
}

-(void)sendKeycodeEvent:(SDL_Scancode)scancode keycode:(SDL_Keycode)keycode keymod:(SDL_Keymod)keymod {
    ScrcpySendKeycodeEvent(scancode, keycode, keymod);
    NSLog(@"KEY EVENT: Post Success");
}

-(void)syncClipboardWithConnectedDevice {
    if (self.scrcpyStatus != ScrcpyStatusSDLWindowCreated) {
        return;
    }
    
    // Check if clipboard sync is enabled
    BOOL enableClipboardSync = YES;
    if (self.sessionArguments && self.sessionArguments[@"adbOptions"]) {
        id value = self.sessionArguments[@"adbOptions"][@"enableClipboardSync"];
        if ([value isKindOfClass:[NSNumber class]]) {
            enableClipboardSync = [value boolValue];
        }
    }
    
    if (enableClipboardSync) {
        [self syncClipboard];
    } else {
        NSLog(@"-> Clipboard sync is disabled");
    }
}

#pragma mark - Getters

- (SDLUIKitDelegate *)sdlDelegate {
    if (!_sdlDelegate) {
        _sdlDelegate = [[SDLUIKitDelegate alloc] init];
    }
    return _sdlDelegate;
}

#pragma mark - Notification

- (void)onScrcpyStatusUpdated:(NSNotification *)notification {
    NSLog(@"Scrcpy status updated: %@", notification.userInfo);
    enum ScrcpyStatus status = [notification.userInfo[@"status"] intValue];
    
    // Update scrcpy status
    self.scrcpyStatus = status;
    
    // Callback
    if (self.sessionCompletion) self.sessionCompletion(status, notification.userInfo[@"message"]);
    
    // Sync clipboard after connected
    [self syncClipboardWithConnectedDevice];
    
    // Make SDL Window visible after window created
    if (status != ScrcpyStatusSDLWindowCreated) {
        return;
    }
    
    // Set SDL Window to current scene on main thread
    NSLog(@"SDL Window: %@", self.sdlDelegate.window);
    self.sdlDelegate.window.windowScene = self.currentScene;
    NSLog(@"SDL Window Scene: %@", self.sdlDelegate.window.windowScene);
    [self.sdlDelegate.window makeKeyWindow];
}

- (void)onApplicationDidEnterBackground:(NSNotification *)notification {
    NSTimeInterval beginBackgroundTime = [NSDate date].timeIntervalSince1970;

    // For more time execute in background
    static void (^beginTaskHandler)(void) = nil;
    beginTaskHandler = ^{
        __block UIBackgroundTaskIdentifier taskIdentifier = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"com.mobile.scrcpy-ios.task" expirationHandler:^{
            [UIApplication.sharedApplication endBackgroundTask:taskIdentifier];
            NSLog(@"Background task expired: %lu", (unsigned long)taskIdentifier);
            
            if (NSDate.date.timeIntervalSince1970 - beginBackgroundTime < 60 * 5) {
                beginTaskHandler();
                NSLog(@"Background task expired, but still in background, restart task");
                return;
            }

            NSLog(@"Background task expired, not in background, stop session");
            [self stopScrcpy];
        }];
        NSLog(@"Application did enter background with task identifier: %lu", (unsigned long)taskIdentifier);
    };
    beginTaskHandler();
    
    // Start background timer to check if still in background
    [self startBackgroundTimer];
}

- (void)onApplicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"Application did become active, reset video");
    
    // Stop background timer first
    [self stopBackgroundTimer];
    
    if (self.scrcpyStatus != ScrcpyStatusSDLWindowCreated) {
        return;
    }
    
    // Sync clipboard
    [self syncClipboardWithConnectedDevice];
    
    // Trigger reset video when app become active
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendKeycodeEvent:SDL_SCANCODE_R keycode:SDLK_r keymod:SDL_KMOD_LCTRL | SDL_KMOD_SHIFT];
        NSLog(@"-> [2] Reset video by LCTRL+SHIFT+R");
    });
}

#pragma mark - Bacgkround Management

- (void)startBackgroundTimer {
    [self stopBackgroundTimer];
    self.lastBackgroundCheckTime = [NSDate date].timeIntervalSince1970;
    self.backgroundTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                            target:self
                                                          selector:@selector(handleBackgroundTimeout)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)handleBackgroundTimeout {
    // Check if still in background and alreay 5 minutes passed
    NSTimeInterval currentTime = [NSDate date].timeIntervalSince1970;
    NSLog(@"Background timer fired, passed %f seconds, checking status...", currentTime - self.lastBackgroundCheckTime);
    
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground &&
        currentTime - self.lastBackgroundCheckTime >= 60 * 5) {
        NSLog(@"App is still in background, stopping scrcpy");
        [self stopScrcpy];
        
        // Stop timer
        [self stopBackgroundTimer];
    } else {
        NSLog(@"App is active or not reach expire time, no action needed");
    }
}

- (void)stopBackgroundTimer {
    if (self.backgroundTimer) {
        [self.backgroundTimer invalidate];
        self.backgroundTimer = nil;
        self.lastBackgroundCheckTime = 0;
        NSLog(@"Background timer stopped");
    }
}

#pragma mark - ADB Action Execution

- (void)executeADBKeyEvent:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *action = userInfo[@"action"];
    NSNumber *keyCodeNumber = userInfo[@"keyCode"];
    
    if (![@"keyEvent" isEqualToString:action] || !keyCodeNumber) {
        NSLog(@"❌ [ScrcpyADBClient] Invalid key event notification: %@", userInfo);
        return;
    }
    
    int keyCode = [keyCodeNumber intValue];
    NSLog(@"🔘 [ScrcpyADBClient] Executing ADB shell input keyevent: %d", keyCode);
    
    // Execute adb shell input keyevent command
    NSString *keyEventCommand = [NSString stringWithFormat:@"input keyevent %d", keyCode];
    NSArray *shellArgs = @[@"shell", keyEventCommand];
    
    [ADBClient.shared executeADBCommandAsync:shellArgs callback:^(NSString * _Nullable result, int returnCode) {
        if (returnCode == 0) {
            NSLog(@"✅ [ScrcpyADBClient] Key event executed successfully: keycode %d", keyCode);
        } else {
            NSLog(@"❌ [ScrcpyADBClient] Key event failed (%d): keycode %d - %@", returnCode, keyCode, result);
        }
    }];
}

- (void)executeADBHomeKey:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *action = userInfo[@"action"];
    
    if (![@"homeKey" isEqualToString:action]) {
        NSLog(@"❌ [ScrcpyADBClient] Invalid home key notification: %@", userInfo);
        return;
    }
    
    NSLog(@"🏠 [ScrcpyADBClient] Executing ADB shell input keyevent for Home key");
    
    // Execute adb shell input keyevent 3 (KEYCODE_HOME)
    NSArray *shellArgs = @[@"shell", @"input keyevent 3"];
    
    [ADBClient.shared executeADBCommandAsync:shellArgs callback:^(NSString * _Nullable result, int returnCode) {
        if (returnCode == 0) {
            NSLog(@"✅ [ScrcpyADBClient] Home key executed successfully via ADB");
        } else {
            NSLog(@"❌ [ScrcpyADBClient] Home key failed (%d): %@", returnCode, result);
        }
    }];
}

- (void)executeADBSwitchKey:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *action = userInfo[@"action"];
    
    if (![@"switchKey" isEqualToString:action]) {
        NSLog(@"❌ [ScrcpyADBClient] Invalid switch key notification: %@", userInfo);
        return;
    }
    
    NSLog(@"🔀 [ScrcpyADBClient] Executing ADB shell input keyevent for App Switch key");
    
    // Execute adb shell input keyevent 187 (KEYCODE_APP_SWITCH)
    NSArray *shellArgs = @[@"shell", @"input keyevent 187"];
    
    [ADBClient.shared executeADBCommandAsync:shellArgs callback:^(NSString * _Nullable result, int returnCode) {
        if (returnCode == 0) {
            NSLog(@"✅ [ScrcpyADBClient] App Switch key executed successfully via ADB");
        } else {
            NSLog(@"❌ [ScrcpyADBClient] App Switch key failed (%d): %@", returnCode, result);
        }
    }];
}

- (void)executeADBInputKeys:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *action = userInfo[@"action"];
    NSArray *keys = userInfo[@"keys"];
    NSNumber *intervalMs = userInfo[@"intervalMs"];
    
    if (![@"inputKeys" isEqualToString:action] || !keys || !intervalMs) {
        NSLog(@"❌ [ScrcpyADBClient] Invalid input keys notification: %@", userInfo);
        return;
    }
    
    NSLog(@"⌨️ [ScrcpyADBClient] Executing %lu input keys via ADB shell input keyevent with %dms interval", 
          (unsigned long)keys.count, [intervalMs intValue]);
    
    dispatch_queue_t keyQueue = dispatch_queue_create("com.scrcpy.key.execution", DISPATCH_QUEUE_SERIAL);
    
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSDictionary *keyInfo = keys[i];
        NSNumber *keyCodeNumber = keyInfo[@"keyCode"];
        NSString *keyName = keyInfo[@"keyName"];
        
        if (!keyCodeNumber) {
            NSLog(@"❌ [ScrcpyADBClient] Invalid key info: %@", keyInfo);
            continue;
        }
        
        int keyCode = [keyCodeNumber intValue];
        NSTimeInterval delay = i * [intervalMs doubleValue] / 1000.0;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), keyQueue, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"🔘 [ScrcpyADBClient] Executing key %lu/%lu: %@ (keycode %d)", 
                      i + 1, (unsigned long)keys.count, keyName, keyCode);
                
                // Execute adb shell input keyevent command
                NSString *keyEventCommand = [NSString stringWithFormat:@"input keyevent %d", keyCode];
                NSArray *shellArgs = @[@"shell", keyEventCommand];
                
                [ADBClient.shared executeADBCommandAsync:shellArgs callback:^(NSString * _Nullable result, int returnCode) {
                    if (returnCode == 0) {
                        NSLog(@"✅ [ScrcpyADBClient] Key %@ (keycode %d) executed successfully", keyName, keyCode);
                    } else {
                        NSLog(@"❌ [ScrcpyADBClient] Key %@ (keycode %d) failed (%d): %@", keyName, keyCode, returnCode, result);
                    }
                }];
            });
        });
    }
    
    // Log completion
    NSTimeInterval totalTime = (keys.count - 1) * [intervalMs doubleValue] / 1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(totalTime * NSEC_PER_SEC)), keyQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"✅ [ScrcpyADBClient] Input keys sequence completed");
        });
    });
}

- (void)executeADBShellCommands:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *action = userInfo[@"action"];
    NSArray *commands = userInfo[@"commands"];
    NSNumber *intervalMs = userInfo[@"intervalMs"];
    
    if (![@"shellCommands" isEqualToString:action] || !commands || !intervalMs) {
        NSLog(@"❌ [ScrcpyADBClient] Invalid shell commands notification: %@", userInfo);
        return;
    }
    
    NSLog(@"💻 [ScrcpyADBClient] Executing %lu shell commands with %dms interval", 
          (unsigned long)commands.count, [intervalMs intValue]);
    
    dispatch_queue_t commandQueue = dispatch_queue_create("com.scrcpy.command.execution", DISPATCH_QUEUE_SERIAL);
    
    for (NSUInteger i = 0; i < commands.count; i++) {
        NSString *command = commands[i];
        NSTimeInterval delay = i * [intervalMs doubleValue] / 1000.0;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), commandQueue, ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"🔘 [ScrcpyADBClient] Executing command %lu/%lu: %@", 
                      i + 1, (unsigned long)commands.count, command);
                
                // Execute ADB shell command
                NSArray *shellArgs = @[@"shell", command];
                [ADBClient.shared executeADBCommandAsync:shellArgs callback:^(NSString * _Nullable result, int returnCode) {
                    if (returnCode == 0) {
                        NSLog(@"✅ [ScrcpyADBClient] Command executed successfully: %@", command);
                        if (result && result.length > 0) {
                            NSLog(@"📤 [ScrcpyADBClient] Command output: %@", result);
                        }
                    } else {
                        NSLog(@"❌ [ScrcpyADBClient] Command failed (%d): %@ - %@", returnCode, command, result);
                    }
                }];
            });
        });
    }
    
    // Log completion
    NSTimeInterval totalTime = (commands.count - 1) * [intervalMs doubleValue] / 1000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(totalTime * NSEC_PER_SEC)), commandQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"✅ [ScrcpyADBClient] Shell commands sequence completed");
        });
    });
}

#pragma mark - Key Code Mapping (Legacy - No longer used, kept for reference)

// NOTE: These methods are no longer used since we now use ADB shell input keyevent commands
// instead of SDL key events. They are kept for reference and potential future use.

- (SDL_Scancode)androidKeyCodeToSDLScancode:(int)androidKeyCode {
    // Comprehensive mapping of Android keycodes to SDL scancodes
    switch (androidKeyCode) {
        // System keys
        case 3: return SDL_SCANCODE_AC_HOME;        // KEYCODE_HOME
        case 4: return SDL_SCANCODE_AC_BACK;        // KEYCODE_BACK
        case 24: return SDL_SCANCODE_VOLUMEUP;      // KEYCODE_VOLUME_UP
        case 25: return SDL_SCANCODE_VOLUMEDOWN;    // KEYCODE_VOLUME_DOWN
        case 26: return SDL_SCANCODE_POWER;         // KEYCODE_POWER
        case 28: return SDL_SCANCODE_CLEAR;         // KEYCODE_CLEAR
        case 82: return SDL_SCANCODE_MENU;          // KEYCODE_MENU
        case 83: return SDL_SCANCODE_SLEEP;         // KEYCODE_NOTIFICATION
        case 84: return SDL_SCANCODE_AC_SEARCH;     // KEYCODE_SEARCH
        case 187: return SDL_SCANCODE_APPLICATION;  // KEYCODE_APP_SWITCH
        
        // Numbers
        case 7: return SDL_SCANCODE_0;              // KEYCODE_0
        case 8: return SDL_SCANCODE_1;              // KEYCODE_1
        case 9: return SDL_SCANCODE_2;              // KEYCODE_2
        case 10: return SDL_SCANCODE_3;             // KEYCODE_3
        case 11: return SDL_SCANCODE_4;             // KEYCODE_4
        case 12: return SDL_SCANCODE_5;             // KEYCODE_5
        case 13: return SDL_SCANCODE_6;             // KEYCODE_6
        case 14: return SDL_SCANCODE_7;             // KEYCODE_7
        case 15: return SDL_SCANCODE_8;             // KEYCODE_8
        case 16: return SDL_SCANCODE_9;             // KEYCODE_9
        case 17: return SDL_SCANCODE_KP_MULTIPLY;   // KEYCODE_STAR
        case 18: return SDL_SCANCODE_3;             // KEYCODE_POUND (#)
        
        // Letters
        case 29: return SDL_SCANCODE_A;             // KEYCODE_A
        case 30: return SDL_SCANCODE_B;             // KEYCODE_B
        case 31: return SDL_SCANCODE_C;             // KEYCODE_C
        case 32: return SDL_SCANCODE_D;             // KEYCODE_D
        case 33: return SDL_SCANCODE_E;             // KEYCODE_E
        case 34: return SDL_SCANCODE_F;             // KEYCODE_F
        case 35: return SDL_SCANCODE_G;             // KEYCODE_G
        case 36: return SDL_SCANCODE_H;             // KEYCODE_H
        case 37: return SDL_SCANCODE_I;             // KEYCODE_I
        case 38: return SDL_SCANCODE_J;             // KEYCODE_J
        case 39: return SDL_SCANCODE_K;             // KEYCODE_K
        case 40: return SDL_SCANCODE_L;             // KEYCODE_L
        case 41: return SDL_SCANCODE_M;             // KEYCODE_M
        case 42: return SDL_SCANCODE_N;             // KEYCODE_N
        case 43: return SDL_SCANCODE_O;             // KEYCODE_O
        case 44: return SDL_SCANCODE_P;             // KEYCODE_P
        case 45: return SDL_SCANCODE_Q;             // KEYCODE_Q
        case 46: return SDL_SCANCODE_R;             // KEYCODE_R
        case 47: return SDL_SCANCODE_S;             // KEYCODE_S
        case 48: return SDL_SCANCODE_T;             // KEYCODE_T
        case 49: return SDL_SCANCODE_U;             // KEYCODE_U
        case 50: return SDL_SCANCODE_V;             // KEYCODE_V
        case 51: return SDL_SCANCODE_W;             // KEYCODE_W
        case 52: return SDL_SCANCODE_X;             // KEYCODE_X
        case 53: return SDL_SCANCODE_Y;             // KEYCODE_Y
        case 54: return SDL_SCANCODE_Z;             // KEYCODE_Z
        
        // Navigation
        case 19: return SDL_SCANCODE_UP;            // KEYCODE_DPAD_UP
        case 20: return SDL_SCANCODE_DOWN;          // KEYCODE_DPAD_DOWN
        case 21: return SDL_SCANCODE_LEFT;          // KEYCODE_DPAD_LEFT
        case 22: return SDL_SCANCODE_RIGHT;         // KEYCODE_DPAD_RIGHT
        case 23: return SDL_SCANCODE_RETURN;        // KEYCODE_DPAD_CENTER
        
        // Punctuation and symbols
        case 55: return SDL_SCANCODE_COMMA;         // KEYCODE_COMMA
        case 56: return SDL_SCANCODE_PERIOD;        // KEYCODE_PERIOD
        case 68: return SDL_SCANCODE_GRAVE;         // KEYCODE_GRAVE
        case 69: return SDL_SCANCODE_MINUS;         // KEYCODE_MINUS
        case 70: return SDL_SCANCODE_EQUALS;        // KEYCODE_EQUALS
        case 71: return SDL_SCANCODE_LEFTBRACKET;   // KEYCODE_LEFT_BRACKET
        case 72: return SDL_SCANCODE_RIGHTBRACKET;  // KEYCODE_RIGHT_BRACKET
        case 73: return SDL_SCANCODE_BACKSLASH;     // KEYCODE_BACKSLASH
        case 74: return SDL_SCANCODE_SEMICOLON;     // KEYCODE_SEMICOLON
        case 75: return SDL_SCANCODE_APOSTROPHE;    // KEYCODE_APOSTROPHE
        case 76: return SDL_SCANCODE_SLASH;         // KEYCODE_SLASH
        case 77: return SDL_SCANCODE_2;             // KEYCODE_AT (@)
        case 81: return SDL_SCANCODE_KP_PLUS;       // KEYCODE_PLUS
        
        // Control keys
        case 61: return SDL_SCANCODE_TAB;           // KEYCODE_TAB
        case 62: return SDL_SCANCODE_SPACE;         // KEYCODE_SPACE
        case 63: return SDL_SCANCODE_SYSREQ;        // KEYCODE_SYM
        case 66: return SDL_SCANCODE_RETURN;        // KEYCODE_ENTER
        case 67: return SDL_SCANCODE_BACKSPACE;     // KEYCODE_DEL
        case 111: return SDL_SCANCODE_ESCAPE;       // KEYCODE_ESCAPE
        case 112: return SDL_SCANCODE_DELETE;       // KEYCODE_FORWARD_DEL
        case 115: return SDL_SCANCODE_CAPSLOCK;     // KEYCODE_CAPS_LOCK
        case 116: return SDL_SCANCODE_SCROLLLOCK;   // KEYCODE_SCROLL_LOCK
        case 121: return SDL_SCANCODE_PAUSE;        // KEYCODE_BREAK
        case 122: return SDL_SCANCODE_HOME;         // KEYCODE_MOVE_HOME
        case 123: return SDL_SCANCODE_END;          // KEYCODE_MOVE_END
        case 124: return SDL_SCANCODE_INSERT;       // KEYCODE_INSERT
        case 125: return SDL_SCANCODE_AC_FORWARD;   // KEYCODE_FORWARD
        
        // Hardware/Media keys
        case 91: return SDL_SCANCODE_MUTE;          // KEYCODE_MUTE
        case 92: return SDL_SCANCODE_PAGEUP;        // KEYCODE_PAGE_UP
        case 93: return SDL_SCANCODE_PAGEDOWN;      // KEYCODE_PAGE_DOWN
        
        // Additional keys
        case 277: return SDL_SCANCODE_CUT;          // KEYCODE_CUT
        case 278: return SDL_SCANCODE_COPY;         // KEYCODE_COPY
        case 279: return SDL_SCANCODE_PASTE;        // KEYCODE_PASTE
        
        default: return SDL_SCANCODE_UNKNOWN;
    }
}

- (SDL_Keycode)androidKeyCodeToSDLKeycode:(int)androidKeyCode {
    // Comprehensive mapping of Android keycodes to SDL keycodes
    switch (androidKeyCode) {
        // System keys
        case 3: return SDLK_AC_HOME;        // KEYCODE_HOME
        case 4: return SDLK_AC_BACK;        // KEYCODE_BACK
        case 24: return SDLK_VOLUMEUP;      // KEYCODE_VOLUME_UP
        case 25: return SDLK_VOLUMEDOWN;    // KEYCODE_VOLUME_DOWN
        case 26: return SDLK_POWER;         // KEYCODE_POWER
        case 28: return SDLK_CLEAR;         // KEYCODE_CLEAR
        case 82: return SDLK_MENU;          // KEYCODE_MENU
        case 83: return SDLK_SLEEP;         // KEYCODE_NOTIFICATION
        case 84: return SDLK_AC_SEARCH;     // KEYCODE_SEARCH
        case 187: return SDLK_APPLICATION;  // KEYCODE_APP_SWITCH
        
        // Numbers
        case 7: return SDLK_0;              // KEYCODE_0
        case 8: return SDLK_1;              // KEYCODE_1
        case 9: return SDLK_2;              // KEYCODE_2
        case 10: return SDLK_3;             // KEYCODE_3
        case 11: return SDLK_4;             // KEYCODE_4
        case 12: return SDLK_5;             // KEYCODE_5
        case 13: return SDLK_6;             // KEYCODE_6
        case 14: return SDLK_7;             // KEYCODE_7
        case 15: return SDLK_8;             // KEYCODE_8
        case 16: return SDLK_9;             // KEYCODE_9
        case 17: return SDLK_KP_MULTIPLY;   // KEYCODE_STAR
        case 18: return SDLK_3;             // KEYCODE_POUND (#)
        
        // Letters
        case 29: return SDLK_a;             // KEYCODE_A
        case 30: return SDLK_b;             // KEYCODE_B
        case 31: return SDLK_c;             // KEYCODE_C
        case 32: return SDLK_d;             // KEYCODE_D
        case 33: return SDLK_e;             // KEYCODE_E
        case 34: return SDLK_f;             // KEYCODE_F
        case 35: return SDLK_g;             // KEYCODE_G
        case 36: return SDLK_h;             // KEYCODE_H
        case 37: return SDLK_i;             // KEYCODE_I
        case 38: return SDLK_j;             // KEYCODE_J
        case 39: return SDLK_k;             // KEYCODE_K
        case 40: return SDLK_l;             // KEYCODE_L
        case 41: return SDLK_m;             // KEYCODE_M
        case 42: return SDLK_n;             // KEYCODE_N
        case 43: return SDLK_o;             // KEYCODE_O
        case 44: return SDLK_p;             // KEYCODE_P
        case 45: return SDLK_q;             // KEYCODE_Q
        case 46: return SDLK_r;             // KEYCODE_R
        case 47: return SDLK_s;             // KEYCODE_S
        case 48: return SDLK_t;             // KEYCODE_T
        case 49: return SDLK_u;             // KEYCODE_U
        case 50: return SDLK_v;             // KEYCODE_V
        case 51: return SDLK_w;             // KEYCODE_W
        case 52: return SDLK_x;             // KEYCODE_X
        case 53: return SDLK_y;             // KEYCODE_Y
        case 54: return SDLK_z;             // KEYCODE_Z
        
        // Navigation
        case 19: return SDLK_UP;            // KEYCODE_DPAD_UP
        case 20: return SDLK_DOWN;          // KEYCODE_DPAD_DOWN
        case 21: return SDLK_LEFT;          // KEYCODE_DPAD_LEFT
        case 22: return SDLK_RIGHT;         // KEYCODE_DPAD_RIGHT
        case 23: return SDLK_RETURN;        // KEYCODE_DPAD_CENTER
        
        // Punctuation and symbols
        case 55: return SDLK_COMMA;         // KEYCODE_COMMA
        case 56: return SDLK_PERIOD;        // KEYCODE_PERIOD
        case 68: return SDLK_BACKQUOTE;     // KEYCODE_GRAVE
        case 69: return SDLK_MINUS;         // KEYCODE_MINUS
        case 70: return SDLK_EQUALS;        // KEYCODE_EQUALS
        case 71: return SDLK_LEFTBRACKET;   // KEYCODE_LEFT_BRACKET
        case 72: return SDLK_RIGHTBRACKET;  // KEYCODE_RIGHT_BRACKET
        case 73: return SDLK_BACKSLASH;     // KEYCODE_BACKSLASH
        case 74: return SDLK_SEMICOLON;     // KEYCODE_SEMICOLON
        case 75: return SDLK_QUOTE;         // KEYCODE_APOSTROPHE
        case 76: return SDLK_SLASH;         // KEYCODE_SLASH
        case 77: return SDLK_2;             // KEYCODE_AT (@)
        case 81: return SDLK_KP_PLUS;       // KEYCODE_PLUS
        
        // Control keys
        case 61: return SDLK_TAB;           // KEYCODE_TAB
        case 62: return SDLK_SPACE;         // KEYCODE_SPACE
        case 63: return SDLK_SYSREQ;        // KEYCODE_SYM
        case 66: return SDLK_RETURN;        // KEYCODE_ENTER
        case 67: return SDLK_BACKSPACE;     // KEYCODE_DEL
        case 111: return SDLK_ESCAPE;       // KEYCODE_ESCAPE
        case 112: return SDLK_DELETE;       // KEYCODE_FORWARD_DEL
        case 115: return SDLK_CAPSLOCK;     // KEYCODE_CAPS_LOCK
        case 116: return SDLK_SCROLLLOCK;   // KEYCODE_SCROLL_LOCK
        case 121: return SDLK_PAUSE;        // KEYCODE_BREAK
        case 122: return SDLK_HOME;         // KEYCODE_MOVE_HOME
        case 123: return SDLK_END;          // KEYCODE_MOVE_END
        case 124: return SDLK_INSERT;       // KEYCODE_INSERT
        case 125: return SDLK_AC_FORWARD;   // KEYCODE_FORWARD
        
        // Hardware/Media keys
        case 91: return SDLK_MUTE;          // KEYCODE_MUTE
        case 92: return SDLK_PAGEUP;        // KEYCODE_PAGE_UP
        case 93: return SDLK_PAGEDOWN;      // KEYCODE_PAGE_DOWN
        
        // Additional keys
        case 277: return SDLK_CUT;          // KEYCODE_CUT
        case 278: return SDLK_COPY;         // KEYCODE_COPY
        case 279: return SDLK_PASTE;        // KEYCODE_PASTE
        
        default: return SDLK_UNKNOWN;
    }
}

@end
