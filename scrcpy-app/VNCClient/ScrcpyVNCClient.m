//
//  ScrcpyVNCClient.m
//  VNCClient
//
//  Created by Ethan on 6/28/25.
//

#import "ScrcpyVNCClient.h"
#import "ScrcpyConstants.h"
#import "ScrcpyBlockWrapper.h"
#import "ScrcpyCommon.h"
#import "ScrcpyConstants.h"
#import "ScrcpyVNCRuntime.h"
#import <UIKit/UIKit.h>

// Local definition for modifier mask used to augment keys
typedef NS_OPTIONS(NSUInteger, ScrcpyModifierMask) {
    ScrcpyModifierMaskNone  = 0,
    ScrcpyModifierMaskMeta  = 1 << 0,
    ScrcpyModifierMaskCtrl  = 1 << 1,
    ScrcpyModifierMaskAlt   = 1 << 2,
    ScrcpyModifierMaskShift = 1 << 3,
};

// Uppercase mapping for letters when Shift is active
static inline int ScrcpyVNCShiftedKeysym(int keysym, BOOL shiftActive) {
    if (!shiftActive) return keysym;
    // Letters: a-z -> A-Z
    if (keysym >= XK_a && keysym <= XK_z) {
        return keysym - (XK_a - XK_A);
    }
    return keysym;
}


@interface ScrcpyVNCClient () <ScrcpyClientProtocol>
// NSOperationQueue to manange connections
@property (nonatomic, strong)   NSOperationQueue    *connectionQueue;
// Current connection operation
@property (nonatomic, strong)   NSBlockOperation    *currentConnectionOperation;
// Control force stop
@property (nonatomic, assign)   BOOL                forceStop;
// Cleanup flag to prevent multiple cleanup calls
@property (nonatomic, assign)   BOOL                isCleaningUp;

@end

@interface ScrcpyVNCClient ()
@property (nonatomic, assign) ScrcpyModifierMask lastAugmentedMask;
@property (nonatomic, assign) BOOL lockMeta, lockCtrl, lockAlt, lockShift;
@property (nonatomic, assign) BOOL candMeta, candCtrl, candAlt, candShift;
@property (nonatomic, assign) BOOL nextKeyAlreadyCombined;
// Track physical (real) modifier key down states from SDL events
@property (nonatomic, assign) BOOL physMetaDown, physCtrlDown, physAltDown, physShiftDown;
// Timestamp (CFAbsoluteTime) of last non-modifier key pressed while any modifier was active
@property (nonatomic, assign) CFAbsoluteTime lastKeyWithModifierTime;
// Timestamp of last non-modifier key press (for suppressing duplicate SDL_EVENT_TEXT_INPUT)
@property (nonatomic, assign) CFAbsoluteTime lastNonModifierKeyTime;
@end

@implementation ScrcpyVNCClient

// Throttling for high-frequency logs
static CFAbsoluteTime kVNCLogThrottleInterval = 2.0; // seconds
static CFAbsoluteTime sLastIncrementalUpdateLogTime = 0;
static NSUInteger sSuppressedIncrementalUpdateLogs = 0;

- (instancetype)init {
    self = [super init];
    if (self) {
        self.sdlDelegate = [[SDLUIKitDelegate alloc] init];
        self.imagePixelsSize = CGSizeZero;
        self.currentRenderer = NULL;
        self.currentTexture = NULL;
        self.connected = NO;
        self.scrcpyStatus = ScrcpyStatusDisconnected;
        self.isCleaningUp = NO;
        
        // 初始化鼠标坐标（屏幕中心）
        self.currentMouseX = 0;
        self.currentMouseY = 0;
        
        // 初始化滚动累积器和上一次偏移量
        self.scrollAccumulatorY = 0.0;
        self.lastScrollOffset = CGPointZero;
        
        // 初始化缩放相关属性
        self.currentZoomScale = 1.0;
        self.zoomCenterX = 0.5;
        self.zoomCenterY = 0.5;
        self.zoomUpdatePending = NO;
        
        // 初始化视图偏移量
        self.viewOffsetX = 0;
        self.viewOffsetY = 0;
        
        // 初始化渲染参数
        self.renderWidth = 0;
        self.renderHeight = 0;
        self.remoteDesktopWidth = 0;
        self.remoteDesktopHeight = 0;
        
        // 初始化连续更新状态（基于RoyalVNC实现）
        self.areContinuousUpdatesSupported = NO;
        self.areContinuousUpdatesEnabled = NO;
        self.incrementalUpdatesEnabled = NO;
        
        // Connection Queue
        self.connectionQueue = [[NSOperationQueue alloc] init];
        self.connectionQueue.maxConcurrentOperationCount = 1; // 确保串行执行连接操作
        self.connectionQueue.qualityOfService = NSQualityOfServiceUserInteractive;
        
        // 监听断开连接通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleDisconnectRequest:)
                                                     name:@"ScrcpyRequestDisconnectNotification"
                                                   object:nil];
        
        // 监听VNC鼠标事件通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCMouseEvent:)
                                                     name:kNotificationVNCMouseEvent
                                                   object:nil];
        
        // 监听VNC拖拽偏移量通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCDragOffset:)
                                                     name:kNotificationVNCDragOffset
                                                   object:nil];
        
        // 监听VNC拖拽状态通知（用于记录拖拽开始位置）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCDragState:)
                                                     name:kNotificationVNCDrag
                                                   object:nil];
        
        // 监听VNC滚动事件通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCScrollEvent:)
                                                     name:kNotificationVNCScrollEvent
                                                   object:nil];
        
        // 监听VNC缩放事件通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCZoomEvent:)
                                                     name:@"ScrcpyVNCZoomNotification"
                                                   object:nil];
        
        // 监听VNC键盘事件通知
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCKeyboardEvent:)
                                                     name:kNotificationVNCKeyboardEvent
                                                   object:nil];

        // Observe toolbar modifier state updates and next-key flag
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onModifierStateUpdated:)
                                                     name:kNotificationVNCModifierStateUpdated
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onNextKeyAlreadyCombined:)
                                                     name:kNotificationVNCNextKeyAlreadyCombined
                                                   object:nil];

        // 监听 VNC 同步剪贴板请求（由菜单触发）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleVNCSyncClipboardRequest:)
                                                     name:kNotificationVNCSyncClipboardRequest
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    NSLog(@"🔌 [ScrcpyVNCClient] dealloc called");
    
    // 取消所有操作
    if (self.connectionQueue) {
        [self.connectionQueue cancelAllOperations];
    }
    
    // 清理当前操作引用
    self.currentConnectionOperation = nil;
    
    // 移除通知观察者
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 断开VNC连接
    [self disconnect];
    
    NSLog(@"🔌 [ScrcpyVNCClient] dealloc completed");
}

- (UIWindowScene *)currentScene {
    for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return scene;
        }
    }
    return nil;
}

#pragma mark - VNC消息循环

- (void)vncMessageLoop {
    // 性能诊断
    static int sMessagesReceived = 0;
    static int sTimeouts = 0;
    static CFAbsoluteTime sLastStatTime = 0;

    while (self.connected && !self.forceStop && ![[NSThread currentThread] isCancelled]) {
        // 检查当前连接操作是否被取消
        if (self.currentConnectionOperation && self.currentConnectionOperation.isCancelled) {
            NSLog(@"🔌 [ScrcpyVNCClient] Current connection operation cancelled, stopping message loop");
            break;
        }

        // 智能超时策略：连续更新模式使用更长的超时时间
        int timeout = self.areContinuousUpdatesEnabled ? 5000 : 500;  // 5秒 vs 0.5秒

        int i = WaitForMessage(self.rfbClient, timeout);

        if (i < 0) {
            NSLog(@"🔌 [ScrcpyVNCClient] VNC message wait failed, breaking loop");
            self.connected = NO;
            self.scrcpyStatus = ScrcpyStatusDisconnected;
            ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "VNC message wait failed");
            return;
        }

        // 再次检查连接状态
        if (self.rfbClient->sock == RFB_INVALID_SOCKET) {
            break;
        }

        // 统计消息接收情况
        if (i > 0) {
            sMessagesReceived++;
        } else {
            sTimeouts++;
        }

        // 每秒输出统计
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - sLastStatTime >= 1.0) {
            if (sMessagesReceived > 0 || sTimeouts > 0) {
                NSLog(@"📈 [VNC MsgLoop] Received: %d msgs, Timeouts: %d, ContinuousUpdates: %@",
                      sMessagesReceived, sTimeouts, self.areContinuousUpdatesEnabled ? @"YES" : @"NO");
            }
            sMessagesReceived = 0;
            sTimeouts = 0;
            sLastStatTime = now;
        }

        if (i > 0) {
            CFAbsoluteTime handleStart = CFAbsoluteTimeGetCurrent();
            if (!HandleRFBServerMessage(self.rfbClient)) {
                NSLog(@"🔌 [ScrcpyVNCClient] VNC server message handling failed, breaking loop");
                self.connected = NO;
                self.scrcpyStatus = ScrcpyStatusDisconnected;
                ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "VNC server message handling failed");
                return;
            }
            CFAbsoluteTime handleEnd = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime handleTime = (handleEnd - handleStart) * 1000;
            if (handleTime > 50) {
                NSLog(@"⚠️ [VNC MsgLoop] HandleRFBServerMessage took %.1fms", handleTime);
            }
        }

        // 检查是否有连续更新相关的消息
        VNCRuntimeCheckForContinuousUpdatesMessage(self.rfbClient);

        // 在传统模式下，如果没有消息则主动请求更新
        // sendSmartFramebufferUpdateRequest 内部已有节流，无需额外日志
        if (i == 0 && !self.areContinuousUpdatesEnabled) {
            [self sendSmartFramebufferUpdateRequest];
        }
    }

    NSLog(@"🔌 [ScrcpyVNCClient] VNC message loop ended");
}

#pragma mark - SDL事件循环

- (void)SDLEventLoop {
    // 运行一小段时间等待其他UI事件
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, NO);

    // Drop any stale SDL_EVENT_QUIT still sitting in the PROCESS-GLOBAL SDL
    // event queue. SDL is linked once and shared between the ADB and VNC
    // sessions, and ADB's -stopScrcpy pushes SDL_EVENT_QUIT on disconnect. If
    // the user disconnects ADB and immediately connects VNC, that leftover
    // QUIT (or one synthesised by iOS during the previous VC's unbalanced
    // appearance transition) would be dequeued here and tear the fresh VNC
    // window down ~immediately after connect — the "connected but no picture"
    // bug. Flush it before we start honoring QUIT for this session.
    SDL_FlushEvent(SDL_EVENT_QUIT);

    SDL_SetiOSEventPump(true);
    SDL_Event e;

    // Guard window against a QUIT that slips in just after the flush — e.g.
    // the previous VC's unbalanced appearance transition can make iOS/SDL
    // emit a QUIT a few dozen ms into the new session (observed ~173ms after
    // connect). A genuine disconnect never arrives that fast; it comes via
    // -disconnect / -stopScrcpy setting forceStop directly. Ignore QUIT for
    // the first 800ms so it can't tear down a just-established session.
    const uint64_t quitGuardUntilMs = SDL_GetTicks() + 800;

    while (self.connected && !self.forceStop) {
        if (!SDL_PollEvent(&e)) {
            SDL_Delay(1);
            continue;
        }
        
        switch (e.type) {
            // SDL3 flattened display + window events: there is no
            // SDL_DISPLAYEVENT / SDL_WINDOWEVENT wrapper; each sub-kind has
            // its own e.type value. Drop the display info log and promote
            // the inner window cases to peers of e.type.

            case SDL_EVENT_WINDOW_EXPOSED:
                if (self.rfbClient) {
                    // 使用智能帧更新请求
                    [self sendSmartFramebufferUpdateRequest];
                }
                break;

            case SDL_EVENT_WINDOW_RESIZED:
                if (self.rfbClient) {
                    SendExtDesktopSize(self.rfbClient, e.window.data1, e.window.data2);
                }
                break;

            case SDL_EVENT_WINDOW_FOCUS_GAINED:
                if (SDL_HasClipboardText()) {
                    char *text = SDL_GetClipboardText();
                    if (text && self.rfbClient) {
                        rfbClientLog("sending clipboard text '%s'\n", text);
                        SendClientCutText(self.rfbClient, text, (int)strlen(text));
                        SDL_free(text);
                    }
                }
                break;

            case SDL_EVENT_WINDOW_FOCUS_LOST:
                NSLog(@"SDL_EVENT_WINDOW_FOCUS_LOST");
                break;
                
            case SDL_EVENT_QUIT:
                if (SDL_GetTicks() < quitGuardUntilMs) {
                    NSLog(@"🔌 [ScrcpyVNCClient] Ignoring early SDL_EVENT_QUIT within startup guard window");
                    break;
                }
                NSLog(@"🔌 [ScrcpyVNCClient] SDL_EVENT_QUIT event received");
                self.forceStop = YES;
                break;
                
            case SDL_EVENT_KEY_DOWN:
            case SDL_EVENT_KEY_UP:
                // 处理键盘按键事件
                [self handleSDLKeyboardEvent:&e];
                break;
                
            case SDL_EVENT_TEXT_INPUT:
                // 处理文本输入事件
                [self handleSDLTextInputEvent:&e];
                break;
                
            default:
                // 忽略其他事件，包括鼠标事件（由上层处理）
                break;
        }
    }

    // 清理全局光标纹理
    VNCRuntimeCleanupGlobalCursorTexture();
    
    // 清理SDL纹理
    if (self.currentTexture) {
        SDL_DestroyTexture(self.currentTexture);
        self.currentTexture = NULL;
    }
    
    // 清理SDL渲染器（Metal后端）
    if (self.currentRenderer) {
        SDL_DestroyRenderer(self.currentRenderer);
        self.currentRenderer = NULL;
    }
    
    // 清理VNC客户端
    if (self.rfbClient) {
        // 清理 SDL Surface
        SDL_Surface *surface = rfbClientGetClientData(self.rfbClient, SDL_Init);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SDL_DestroySurface(surface);
        });

        // 清理VNC运行时回调
        VNCRuntimeCleanupCallbacks(self.rfbClient);
        
        // 清理RFB客户端
        rfbClientCleanup(self.rfbClient);
        self.rfbClient = NULL;
    }
    
    // 退出SDL
    SDL_Quit();
    SDL_SetiOSEventPump(false);

    NSLog(@"✅ [ScrcpyVNCClient] SDL main loop ended");
}

#pragma mark - VNC Clipboard

- (void)handleVNCSyncClipboardRequest:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"📋 [ScrcpyVNCClient] Ignoring clipboard sync request: not connected");
        // 提示用户（无内容或未连接时提示）
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCClipboardSynced
                                                            object:nil
                                                          userInfo:@{ kKeyIsEmpty: @YES }];
        return;
    }
    // 复用现有的动作实现：1 = SyncClipboard
    [self executeVNCActions:@[@1] completion:^(BOOL success, NSString * _Nonnull error) {
        if (!success) {
            NSLog(@"❌ [ScrcpyVNCClient] Clipboard sync action failed: %@", error ?: @"unknown error");
        }
    }];
}

#pragma mark - VNC客户端主要方法

- (void)startWithArguments:(NSDictionary *)arguments completion:(void (^)(enum ScrcpyStatus, NSString *))completion {
    NSString *host = arguments[@"hostReal"];
    NSString *port = arguments[@"port"];
    NSString *user = arguments[@"vncOptions"][@"vncUser"];
    NSString *password = arguments[@"vncOptions"][@"vncPassword"];
    
    NSLog(@"✅ [ScrcpyVNCClient] Starting VNC client connection to %@:%@", host, port);
    
    // 确保清理之前的连接状态
    if (self.connected || self.rfbClient) {
        NSLog(@"⚠️ [ScrcpyVNCClient] Previous connection detected, cleaning up first");
        [self disconnect];
        
        // 等待清理完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self continueStartWithArguments:arguments completion:completion];
        });
        return;
    }
    
    [self continueStartWithArguments:arguments completion:completion];
}

- (void)continueStartWithArguments:(NSDictionary *)arguments completion:(void (^)(enum ScrcpyStatus, NSString *))completion {
    NSString *host = arguments[@"hostReal"];
    NSString *port = arguments[@"port"];
    NSString *user = arguments[@"vncOptions"][@"vncUser"];
    NSString *password = arguments[@"vncOptions"][@"vncPassword"];
    
    // 保存完成回调
    self.sessionCompletion = completion;
    self.sessionArguments = arguments;
    
    // 模拟ApplicationDelegate方法
    [self.sdlDelegate application:[UIApplication sharedApplication] didFinishLaunchingWithOptions:@{}];

    // 初始化SDL
    SDL_Init(SDL_INIT_VIDEO);
    atexit(SDL_Quit);
    signal(SIGINT, exit);
    
    // 更新状态
    self.scrcpyStatus = ScrcpyStatusSDLInited;
    ScrcpyUpdateStatus(ScrcpyStatusSDLInited, "SDL initialized successfully");
    
    __block SDL_Texture *sdlTexture = NULL;
    __block SDL_Renderer *sdlRenderer = NULL;
    __block SDL_Window *sdlWindow = nil;

    // 安装 libvncclient 日志捕获钩子，并清空上次的失败原因，以便本次连接
    // 失败时能拿到具体原因（密码错误 / 尝试次数过多 / 连接被拒绝等）。
    VNCRuntimeInstallLogCapture();
    VNCRuntimeResetLastFailureReason();

    // 初始化VNC客户端
    self.rfbClient = rfbGetClient(8, 3, 4);
    self.rfbClient->canHandleNewFBSize = true;
    self.rfbClient->listenPort = LISTEN_PORT_OFFSET;
    self.rfbClient->listen6Port = LISTEN_PORT_OFFSET;
    
    // 设置连接超时（30秒）
    self.rfbClient->connectTimeout = 30;
    
    // 设置读取超时（15秒）
    self.rfbClient->readTimeout = 15;
    
    // 使用远程指针:
    // - 不使用的话, 无法获取远程鼠标的位置变化, 导致发送点击事件时无法正确定位, 但好处是远程的鼠标指针会正确展示
    // - 使用的话, 可以正确获取鼠标位置, 但远程鼠标指针会被隐藏, 需要自己绘制
    self.rfbClient->appData.useRemoteCursor = true;
    
    // 设置帧缓冲区分配回调
    __weak typeof(self) weakSelf = self;
    GetSet_MallocFrameBufferBlockIMP(self.rfbClient, imp_implementationWithBlock(^rfbBool(rfbClient* client){
        // This runs on the connection (background) queue while rfbInitClient
        // is negotiating. If the ScrcpyVNCClient is being torn down at the
        // same time (user backs out / reconnects), weakSelf may already be
        // nil or in mid-dealloc. Pin it to a strong ref for the whole
        // allocation and bail out safely if it's gone — otherwise
        // VNCRuntimeMallocFrameBuffer dereferences a dead object
        // (crash: byte write to a tiny bogus address, ScrcpyVNCRuntime.m:325).
        __block rfbBool ok = FALSE;
        dispatch_sync(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.rfbClient == NULL || client == NULL) {
                NSLog(@"🔌 [ScrcpyVNCClient] MallocFrameBuffer skipped: client torn down");
                return;
            }
            ok = VNCRuntimeMallocFrameBuffer(client, strongSelf, &sdlWindow, &sdlRenderer, &sdlTexture);
        });
        return ok;
    }));
    self.rfbClient->MallocFrameBuffer = MallocFrameBufferBlock;
    
    // 设置鼠标指针位置更新回调
    self.rfbClient->HandleCursorPos = HandleCursorPosBlock;
    VNCRuntimeSetupHandleCursorPosCallback(self.rfbClient, &_currentMouseX, &_currentMouseY);
    
    // 设置认证回调
    self.rfbClient->GetPassword = GetPasswordBlock;
    VNCRuntimeSetupGetPasswordCallback(self.rfbClient, password);
    
    // 设置高级认证回调
    self.rfbClient->GetCredential = GetCredentialBlock;
    VNCRuntimeSetupGetCredentialCallback(self.rfbClient, user, password);
    
    // 设置连续更新支持
    VNCRuntimeSetupContinuousUpdatesHook(self.rfbClient);
    
    // 获取VNC选项
    NSDictionary *vncOptions = arguments[@"vncOptions"];
    NSString *compressionLevelString = vncOptions[@"compressionLevel"];
    NSString *qualityLevelString = vncOptions[@"qualityLevel"];
    
    // 准备VNC压缩等级参数
    int compressionLevel = 6; // 默认标准压缩
    if (compressionLevelString) {
        if ([compressionLevelString isEqualToString:@"none"]) {
            compressionLevel = 0;
        } else if ([compressionLevelString isEqualToString:@"standard"]) {
            compressionLevel = 6;
        } else if ([compressionLevelString isEqualToString:@"maximum"]) {
            compressionLevel = 9;
        }
    }
    
    // 准备VNC质量等级参数
    int qualityLevel = 5; // 默认标准质量
    if (qualityLevelString) {
        if ([qualityLevelString isEqualToString:@"lowest"]) {
            qualityLevel = 0;
        } else if ([qualityLevelString isEqualToString:@"low"]) {
            qualityLevel = 2;
        } else if ([qualityLevelString isEqualToString:@"standard"]) {
            qualityLevel = 5;
        } else if ([qualityLevelString isEqualToString:@"high"]) {
            qualityLevel = 7;
        } else if ([qualityLevelString isEqualToString:@"highest"]) {
            qualityLevel = 9;
        }
    }
    
    NSLog(@"✅ [ScrcpyVNCClient] Using compression level %d (%@), quality level %d (%@)", 
          compressionLevel, compressionLevelString ?: @"default", 
          qualityLevel, qualityLevelString ?: @"default");
    
    // 准备连接参数，包含压缩设置
    NSString *compressionLevelStr = [NSString stringWithFormat:@"%d", compressionLevel];
    NSString *hostPortStr = [NSString stringWithFormat:@"%@:%@", host, port];
    
    // 更新状态为连接中
    self.scrcpyStatus = ScrcpyStatusConnecting;
    ScrcpyUpdateStatus(ScrcpyStatusConnecting, [[NSString stringWithFormat:@"Connecting to %@:%@", host, port] UTF8String]);
    
    // 初始化VNC客户端连接
    NSBlockOperation *connectionOperation = [NSBlockOperation blockOperationWithBlock:^{
        // 检查操作是否已被取消
        if (connectionOperation.isCancelled) {
            NSLog(@"🔌 [ScrcpyVNCClient] Connection operation was cancelled before starting");
            return;
        }
        
        const char *argv[] = {
            "vnc",
            "-compress", compressionLevelStr.UTF8String,
            hostPortStr.UTF8String
        };
        int argc = sizeof(argv) / sizeof(char *);
        
        // 再次检查取消状态
        if (connectionOperation.isCancelled) {
            NSLog(@"🔌 [ScrcpyVNCClient] Connection operation was cancelled before rfbInitClient");
            return;
        }
        
        if (!rfbInitClient(self.rfbClient, &argc, (char **)argv)) {
            // 检查是否是由于取消操作导致的失败
            if (connectionOperation.isCancelled) {
                NSLog(@"🔌 [ScrcpyVNCClient] Connection cancelled during rfbInitClient");
                return;
            }
            
            weakSelf.rfbClient = NULL;

            // 取 libvncclient 捕获到的具体失败原因（密码错误 / 尝试次数过多 /
            // 连接被拒绝等），有则用它，否则回退到通用文案，让用户能区分
            // 是认证问题还是网络问题。
            NSString *specificReason = VNCRuntimeLocalizedFailureReason();
            NSString *userMessage = specificReason
                ?: [NSString stringWithFormat:NSLocalizedString(@"Failed to connect to VNC server %@:%@", nil), host, port];

            weakSelf.scrcpyStatus = ScrcpyStatusConnectingFailed;
            ScrcpyUpdateStatus(ScrcpyStatusConnectingFailed, userMessage.UTF8String);

            if (completion) {
                completion(ScrcpyStatusConnectingFailed, userMessage);
            }
            return;
        }
        
        // 再次检查是否被取消
        if (connectionOperation.isCancelled) {
            NSLog(@"🔌 [ScrcpyVNCClient] Connection operation cancelled after rfbInitClient success");
            if (weakSelf.rfbClient) {
                // 清理VNC运行时回调
                VNCRuntimeCleanupCallbacks(weakSelf.rfbClient);
                // 清理RFB客户端
                rfbClientCleanup(weakSelf.rfbClient);
                weakSelf.rfbClient = NULL;
            }
            return;
        }
    
        // 设置质量等级（rfbInitClient不直接支持quality参数，所以在连接后设置）
        if (weakSelf.rfbClient) {
            weakSelf.rfbClient->appData.qualityLevel = qualityLevel;
            weakSelf.rfbClient->appData.enableJPEG = (qualityLevel > 0) ? TRUE : FALSE;
            NSLog(@"✅ [ScrcpyVNCClient] Applied quality level %d after connection", qualityLevel);
        }
    
        // 标记为已连接
        weakSelf.connected = YES;
    
        // 更新状态为已连接
        weakSelf.scrcpyStatus = ScrcpyStatusConnected;
        ScrcpyUpdateStatus(ScrcpyStatusConnected, "VNC client connected successfully");
    
        NSLog(@"✅ [ScrcpyVNCClient] VNC connection established successfully");
    
        // 初始化鼠标坐标到屏幕中心（作为默认值）
        if (weakSelf.rfbClient) {
            weakSelf.currentMouseX = weakSelf.rfbClient->width / 2;
            weakSelf.currentMouseY = weakSelf.rfbClient->height / 2;
            NSLog(@"🐭 [ScrcpyVNCClient] Initialized default mouse position to center: (%d,%d)", weakSelf.currentMouseX, weakSelf.currentMouseY);
            
            // 请求当前光标位置（如果服务器支持）
            // 这将触发 GotCursorPos 回调来获取真实的光标位置
            if (weakSelf.rfbClient->canHandleNewFBSize) {
                NSLog(@"🔍 [ScrcpyVNCClient] Requesting current cursor position from VNC server");
            }
            
            // 发送一个轻微的鼠标移动来获取当前位置（某些VNC服务器需要这样做）
            SendPointerEvent(weakSelf.rfbClient, weakSelf.currentMouseX, weakSelf.currentMouseY, 0);
            
            // 延迟100ms后再次请求，确保服务器有时间响应
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf && strongSelf.rfbClient && strongSelf.connected && !connectionOperation.isCancelled) {
                    NSLog(@"🖱️ [ScrcpyVNCClient] Sending additional framebuffer update request for cursor");
                    SendFramebufferUpdateRequest(strongSelf.rfbClient, 0, 0, strongSelf.rfbClient->width, strongSelf.rfbClient->height, TRUE);
                }
            });
        }
        
        // 请求初始帧缓冲更新（使用智能策略）
        if (weakSelf.rfbClient && !connectionOperation.isCancelled) {
            [weakSelf sendSmartFramebufferUpdateRequest];
        }
        
        if (completion && !connectionOperation.isCancelled) {
            completion(ScrcpyStatusConnected, @"VNC connected successfully");
        }
        
        // 只有在没有被取消的情况下才启动消息循环
        if (!connectionOperation.isCancelled) {
            // Start audio streaming if enabled
            [weakSelf startAudioStreamingIfEnabled];

            // 在后台线程启动消息循环
            [NSThread detachNewThreadSelector:@selector(vncMessageLoop) toTarget:weakSelf withObject:nil];

            // 启动SDL事件循环
            [weakSelf performSelectorOnMainThread:@selector(SDLEventLoop) withObject:nil waitUntilDone:NO];
        } else {
            NSLog(@"🔌 [ScrcpyVNCClient] Connection operation was cancelled, not starting loops");
        }
    }];
    
    // 保存当前连接操作的引用
    self.currentConnectionOperation = connectionOperation;
    
    // 将操作添加到队列
    [self.connectionQueue addOperation:connectionOperation];
}


- (void)moveMouseToX:(int)x y:(int)y {
    if (!self.connected || !self.rfbClient) {
        return;
    }

    // 确保坐标在远程屏幕范围内
    int maxX = self.rfbClient->width - 1;
    int maxY = self.rfbClient->height - 1;

    int clampedX = MAX(0, MIN(x, maxX));
    int clampedY = MAX(0, MIN(y, maxY));

    // 发送鼠标指针事件到VNC服务器
    if (!SendPointerEvent(self.rfbClient, clampedX, clampedY, 0)) {
        return;
    }

    // 更新存储的鼠标坐标
    self.currentMouseX = clampedX;
    self.currentMouseY = clampedY;

    // 强制重新渲染以更新光标位置（即使没有VNC服务器更新）
    VNCRuntimeForceRender(self);
}

#pragma mark - VNC Audio Streaming

- (void)startAudioStreamingIfEnabled {
    // Check if audio is enabled in session options
    NSDictionary *vncOptions = self.sessionArguments[@"vncOptions"];
    BOOL enableAudio = [vncOptions[@"enableAudio"] boolValue];

    if (!enableAudio) {
        NSLog(@"🔊 [ScrcpyVNCClient] Audio streaming not enabled in session options");
        return;
    }

    NSString *host = self.sessionArguments[@"hostReal"];
    NSString *audioPortString = vncOptions[@"audioPort"];
    NSNumber *audioBufferMsNumber = vncOptions[@"audioBufferMs"];

    // Calculate audio port: use specified port or default 4901
    int audioPort;
    if (audioPortString && audioPortString.length > 0) {
        audioPort = [audioPortString intValue];
    } else {
        audioPort = 4901;  // Default PCM audio streaming port
    }

    // Get buffer time (default 100ms)
    int bufferMs = audioBufferMsNumber ? [audioBufferMsNumber intValue] : 100;

    NSLog(@"🔊 [ScrcpyVNCClient] Starting audio streaming from %@:%d (buffer: %dms)", host, audioPort, bufferMs);

    // Create and start audio player
    self.audioPlayer = [[ScrcpyVNCAudioPlayer alloc] init];
    [self.audioPlayer startWithHost:host port:audioPort bufferMs:bufferMs completion:^(BOOL success, NSString * _Nullable error) {
        if (success) {
            NSLog(@"🔊 [ScrcpyVNCClient] Audio streaming started successfully");
        } else {
            NSLog(@"❌ [ScrcpyVNCClient] Failed to start audio streaming: %@", error ?: @"Unknown error");
            // Audio failure is not critical - VNC session continues without audio
        }
    }];
}

- (void)stopAudioStreaming {
    if (self.audioPlayer) {
        NSLog(@"🔊 [ScrcpyVNCClient] Stopping audio streaming");
        [self.audioPlayer stop];
        self.audioPlayer = nil;
    }
}

#pragma mark - Mouse Events

- (void)sendMouseClickAtX:(int)x y:(int)y isRightClick:(BOOL)isRightClick {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send mouse click: VNC not connected");
        return;
    }
    
    // 确保坐标在远程屏幕范围内
    int maxX = self.rfbClient->width - 1;
    int maxY = self.rfbClient->height - 1;
    
    int clampedX = MAX(0, MIN(x, maxX));
    int clampedY = MAX(0, MIN(y, maxY));
    
    if (clampedX != x || clampedY != y) {
        NSLog(@"⚠️ [ScrcpyVNCClient] Mouse click coordinates clamped from (%d,%d) to (%d,%d) for screen size %dx%d", 
              x, y, clampedX, clampedY, self.rfbClient->width, self.rfbClient->height);
    }
    
    // 确定鼠标按钮掩码
    int buttonMask = isRightClick ? rfbButton3Mask : rfbButton1Mask;
    
    // 发送鼠标按下事件
    if (!SendPointerEvent(self.rfbClient, clampedX, clampedY, buttonMask)) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send mouse button down event");
        return;
    }
    
    // 发送鼠标松开事件
    if (!SendPointerEvent(self.rfbClient, clampedX, clampedY, 0)) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send mouse button up event");
        return;
    }
    
    NSLog(@"🖱️ [ScrcpyVNCClient] %@ mouse click sent at position (%d,%d)", 
          isRightClick ? @"Right" : @"Left", clampedX, clampedY);
}

#pragma mark - SDL键盘事件处理

- (void)handleSDLKeyboardEvent:(SDL_Event *)event {
    if (!self.connected || !self.rfbClient) {
        return;
    }
    
    // 将SDL键码转换为VNC键码
    int vncKeyCode = [self convertSDLKeyToVNCKey:event->key.key];
    if (vncKeyCode == -1) {
        NSLog(@"⚠️ [ScrcpyVNCClient] Unknown SDL key: %d", event->key.key);
        return;
    }
    
    BOOL isPressed = (event->type == SDL_EVENT_KEY_DOWN);
    SDL_Keycode sdlKey = event->key.key;

    BOOL isModifier = (sdlKey == SDLK_LCTRL || sdlKey == SDLK_RCTRL ||
                       sdlKey == SDLK_LALT  || sdlKey == SDLK_RALT  ||
                       sdlKey == SDLK_LSHIFT|| sdlKey == SDLK_RSHIFT||
                       sdlKey == SDLK_LGUI  || sdlKey == SDLK_RGUI);

    // Maintain physical modifier states
    if (isModifier) {
        if (sdlKey == SDLK_LCTRL || sdlKey == SDLK_RCTRL)   { self.physCtrlDown  = isPressed; }
        else if (sdlKey == SDLK_LALT || sdlKey == SDLK_RALT){ self.physAltDown   = isPressed; }
        else if (sdlKey == SDLK_LSHIFT || sdlKey == SDLK_RSHIFT){ self.physShiftDown = isPressed; }
        else if (sdlKey == SDLK_LGUI || sdlKey == SDLK_RGUI){ self.physMetaDown  = isPressed; }
    }

    // 当接收到非修饰键的按下事件时，通知清除一次性（候选）修饰键状态
    if (isPressed) {
        if (!isModifier) {
            // Record timestamp for any plain (non-modifier) key press
            self.lastNonModifierKeyTime = CFAbsoluteTimeGetCurrent();
            // If toolbar already combined modifiers for this key, skip augmentation
            BOOL alreadyCombined = self.nextKeyAlreadyCombined;
            self.nextKeyAlreadyCombined = NO;
            if (!alreadyCombined) {
                // Augment with active modifiers (locked + candidates)
                ScrcpyModifierMask candMask = (self.candMeta?ScrcpyModifierMaskMeta:0) |
                                              (self.candCtrl?ScrcpyModifierMaskCtrl:0) |
                                              (self.candAlt?ScrcpyModifierMaskAlt:0) |
                                              (self.candShift?ScrcpyModifierMaskShift:0);
                ScrcpyModifierMask lockMask = (self.lockMeta?ScrcpyModifierMaskMeta:0) |
                                              (self.lockCtrl?ScrcpyModifierMaskCtrl:0) |
                                              (self.lockAlt?ScrcpyModifierMaskAlt:0) |
                                              (self.lockShift?ScrcpyModifierMaskShift:0);
                ScrcpyModifierMask mask = lockMask | candMask;
                self.lastAugmentedMask = mask;

                // Press modifiers
                if (mask & ScrcpyModifierMaskMeta)  { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LGUI]  isPressed:YES]; }
                if (mask & ScrcpyModifierMaskCtrl)  { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LCTRL] isPressed:YES]; }
                if (mask & ScrcpyModifierMaskAlt)   { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LALT]  isPressed:YES]; }
                if (mask & ScrcpyModifierMaskShift) { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LSHIFT] isPressed:YES]; }

                // Post UI update for candidate clearing
                if (candMask != ScrcpyModifierMaskNone) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCClearCandidateModifiers object:nil];
                    // Clear local candidate states as well
                    self.candMeta = self.candCtrl = self.candAlt = self.candShift = NO;
                }
            } else {
                // Already combined by toolbar, do not augment; also ensure we don't release anything for it
                self.lastAugmentedMask = ScrcpyModifierMaskNone;
            }

            // Record a timestamp if any modifier is effectively active for this key
            BOOL anyModifierEffective = self.physCtrlDown || self.physAltDown || self.physShiftDown || self.physMetaDown ||
                                        self.lockMeta || self.lockCtrl || self.lockAlt || self.lockShift ||
                                        self.candMeta || self.candCtrl || self.candAlt || self.candShift ||
                                        (self.lastAugmentedMask != ScrcpyModifierMaskNone) || alreadyCombined;
            if (anyModifierEffective) {
                self.lastKeyWithModifierTime = CFAbsoluteTimeGetCurrent();
            }
        }
    }
    
    // 发送键盘事件到VNC服务器（考虑Shift影响的keysym）
    BOOL shiftActiveNow = self.physShiftDown || (self.lastAugmentedMask & ScrcpyModifierMaskShift);
    int finalKeyCode = ScrcpyVNCShiftedKeysym(vncKeyCode, shiftActiveNow);
    [self sendKeyEvent:finalKeyCode isPressed:isPressed];

    // On key up of a non-modifier, release augmented modifiers
    if (!isPressed) {
        BOOL isModifier = (sdlKey == SDLK_LCTRL || sdlKey == SDLK_RCTRL ||
                           sdlKey == SDLK_LALT  || sdlKey == SDLK_RALT  ||
                           sdlKey == SDLK_LSHIFT|| sdlKey == SDLK_RSHIFT||
                           sdlKey == SDLK_LGUI  || sdlKey == SDLK_RGUI);
        if (!isModifier) {
            // Release any modifiers we pressed for this key (locked or candidate), then clear
            ScrcpyModifierMask mask = self.lastAugmentedMask;
            if (mask & ScrcpyModifierMaskShift) { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LSHIFT] isPressed:NO]; }
            if (mask & ScrcpyModifierMaskAlt)   { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LALT]  isPressed:NO]; }
            if (mask & ScrcpyModifierMaskCtrl)  { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LCTRL] isPressed:NO]; }
            if (mask & ScrcpyModifierMaskMeta)  { [self sendKeyEvent:[self convertSDLKeyToVNCKey:SDLK_LGUI]  isPressed:NO]; }
            self.lastAugmentedMask = ScrcpyModifierMaskNone;
        }
    }
}

#pragma mark - Modifier State Notifications

- (void)onModifierStateUpdated:(NSNotification *)note {
    NSDictionary *u = note.userInfo ?: @{};
    self.lockMeta = [u[@"lockMeta"] boolValue];
    self.lockCtrl = [u[@"lockCtrl"] boolValue];
    self.lockAlt  = [u[@"lockAlt"] boolValue];
    self.lockShift= [u[@"lockShift"] boolValue];
    self.candMeta = [u[@"candMeta"] boolValue];
    self.candCtrl = [u[@"candCtrl"] boolValue];
    self.candAlt  = [u[@"candAlt"] boolValue];
    self.candShift= [u[@"candShift"] boolValue];
}

- (void)onNextKeyAlreadyCombined:(NSNotification *)note {
    self.nextKeyAlreadyCombined = YES;
}

- (void)handleSDLTextInputEvent:(SDL_Event *)event {
    if (!self.connected || !self.rfbClient) {
        return;
    }
    // If any modifiers are active (physical or toolbar), ignore text input to avoid sending bare characters
    BOOL anyModActive = self.physCtrlDown || self.physAltDown || self.physShiftDown || self.physMetaDown ||
                        self.lockMeta || self.lockCtrl || self.lockAlt || self.lockShift ||
                        self.candMeta || self.candCtrl || self.candAlt || self.candShift ||
                        (self.lastAugmentedMask != ScrcpyModifierMaskNone) || self.nextKeyAlreadyCombined;

    // Additionally, if a non-modifier key with modifiers was pressed very recently,
    // suppress the following SDL_EVENT_TEXT_INPUT once (accounts for ordering where modifiers are released first)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const CFAbsoluteTime kSuppressWindow = 0.25; // seconds
    // Suppress after a recent non-modifier key press to avoid duplicate visible characters
    if (self.lastNonModifierKeyTime > 0 && (now - self.lastNonModifierKeyTime) <= kSuppressWindow) {
        anyModActive = YES;
    }
    // Also suppress if a key was sent with modifiers very recently
    if (!anyModActive && self.lastKeyWithModifierTime > 0 && (now - self.lastKeyWithModifierTime) <= kSuppressWindow) {
        anyModActive = YES;
        // Do not clear timestamps immediately; let time window expire naturally
    }
    if (anyModActive) {
        return;
    }

    // 获取输入的文本
    NSString *text = [NSString stringWithUTF8String:event->text.text];
    if (text && text.length > 0) {
        [self sendTextInput:text];
    }
}

// 将SDL键码转换为VNC键码（X11 KeySym）
- (int)convertSDLKeyToVNCKey:(SDL_Keycode)sdlKey {
    switch (sdlKey) {
        // 字母键
        case SDLK_A: return XK_a;
        case SDLK_B: return XK_b;
        case SDLK_C: return XK_c;
        case SDLK_D: return XK_d;
        case SDLK_E: return XK_e;
        case SDLK_F: return XK_f;
        case SDLK_G: return XK_g;
        case SDLK_H: return XK_h;
        case SDLK_I: return XK_i;
        case SDLK_J: return XK_j;
        case SDLK_K: return XK_k;
        case SDLK_L: return XK_l;
        case SDLK_M: return XK_m;
        case SDLK_N: return XK_n;
        case SDLK_O: return XK_o;
        case SDLK_P: return XK_p;
        case SDLK_Q: return XK_q;
        case SDLK_R: return XK_r;
        case SDLK_S: return XK_s;
        case SDLK_T: return XK_t;
        case SDLK_U: return XK_u;
        case SDLK_V: return XK_v;
        case SDLK_W: return XK_w;
        case SDLK_X: return XK_x;
        case SDLK_Y: return XK_y;
        case SDLK_Z: return XK_z;
        
        // 数字键
        case SDLK_0: return XK_0;
        case SDLK_1: return XK_1;
        case SDLK_2: return XK_2;
        case SDLK_3: return XK_3;
        case SDLK_4: return XK_4;
        case SDLK_5: return XK_5;
        case SDLK_6: return XK_6;
        case SDLK_7: return XK_7;
        case SDLK_8: return XK_8;
        case SDLK_9: return XK_9;
        
        // 功能键
        case SDLK_F1: return XK_F1;
        case SDLK_F2: return XK_F2;
        case SDLK_F3: return XK_F3;
        case SDLK_F4: return XK_F4;
        case SDLK_F5: return XK_F5;
        case SDLK_F6: return XK_F6;
        case SDLK_F7: return XK_F7;
        case SDLK_F8: return XK_F8;
        case SDLK_F9: return XK_F9;
        case SDLK_F10: return XK_F10;
        case SDLK_F11: return XK_F11;
        case SDLK_F12: return XK_F12;
        
        // 特殊键
        case SDLK_RETURN: return XK_Return;
        case SDLK_ESCAPE: return XK_Escape;
        case SDLK_BACKSPACE: return XK_BackSpace;
        case SDLK_TAB: return XK_Tab;
        case SDLK_SPACE: return XK_space;
        case SDLK_DELETE: return XK_Delete;
        
        // 修饰键
        case SDLK_LSHIFT: return XK_Shift_L;
        case SDLK_RSHIFT: return XK_Shift_R;
        case SDLK_LCTRL: return XK_Control_L;
        case SDLK_RCTRL: return XK_Control_R;
        case SDLK_LALT: return XK_Alt_L;
        case SDLK_RALT: return XK_Alt_R;
        case SDLK_LGUI: return XK_Super_L;
        case SDLK_RGUI: return XK_Super_R;
        
        // 方向键
        case SDLK_UP: return XK_Up;
        case SDLK_DOWN: return XK_Down;
        case SDLK_LEFT: return XK_Left;
        case SDLK_RIGHT: return XK_Right;
        
        // 其他常用键
        case SDLK_INSERT: return XK_Insert;
        case SDLK_HOME: return XK_Home;
        case SDLK_END: return XK_End;
        case SDLK_PAGEUP: return XK_Page_Up;
        case SDLK_PAGEDOWN: return XK_Page_Down;
        case SDLK_CAPSLOCK: return XK_Caps_Lock;
        case SDLK_SCROLLLOCK: return XK_Scroll_Lock;
        case SDLK_NUMLOCKCLEAR: return XK_Num_Lock;
        case SDLK_PRINTSCREEN: return XK_Print;
        case SDLK_PAUSE: return XK_Pause;
        
        // 符号键
        case SDLK_MINUS: return XK_minus;
        case SDLK_EQUALS: return XK_equal;
        case SDLK_LEFTBRACKET: return XK_bracketleft;
        case SDLK_RIGHTBRACKET: return XK_bracketright;
        case SDLK_BACKSLASH: return XK_backslash;
        case SDLK_SEMICOLON: return XK_semicolon;
        case SDLK_APOSTROPHE: return XK_apostrophe;
        case SDLK_GRAVE: return XK_grave;
        case SDLK_COMMA: return XK_comma;
        case SDLK_PERIOD: return XK_period;
        case SDLK_SLASH: return XK_slash;
        
        // 数字键盘
        case SDLK_KP_0: return XK_KP_0;
        case SDLK_KP_1: return XK_KP_1;
        case SDLK_KP_2: return XK_KP_2;
        case SDLK_KP_3: return XK_KP_3;
        case SDLK_KP_4: return XK_KP_4;
        case SDLK_KP_5: return XK_KP_5;
        case SDLK_KP_6: return XK_KP_6;
        case SDLK_KP_7: return XK_KP_7;
        case SDLK_KP_8: return XK_KP_8;
        case SDLK_KP_9: return XK_KP_9;
        case SDLK_KP_DECIMAL: return XK_KP_Decimal;
        case SDLK_KP_DIVIDE: return XK_KP_Divide;
        case SDLK_KP_MULTIPLY: return XK_KP_Multiply;
        case SDLK_KP_MINUS: return XK_KP_Subtract;
        case SDLK_KP_PLUS: return XK_KP_Add;
        case SDLK_KP_ENTER: return XK_KP_Enter;
        case SDLK_KP_EQUALS: return XK_KP_Equal;
        
        default:
            return -1; // 未知键
    }
}

#pragma mark - SDL Cleanup Methods

- (void)cleanup {
    NSLog(@"🔌 [ScrcpyVNCClient] Cleanup method called");
    
    // 参考 libvncclient 的 cleanup 实现
    // 重启 SDL 视频子系统来关闭 viewer 窗口
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    SDL_InitSubSystem(SDL_INIT_VIDEO);
    
    if (self.rfbClient) {
        // 清理VNC运行时回调
        VNCRuntimeCleanupCallbacks(self.rfbClient);
        
        // 清理RFB客户端
        rfbClientCleanup(self.rfbClient);
        self.rfbClient = NULL;
    }
    
    // 标记为断开连接
    self.connected = NO;
    self.scrcpyStatus = ScrcpyStatusDisconnected;
    ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "VNC client cleaned up");
    
    // 重置清理标志
    self.isCleaningUp = NO;
    
    NSLog(@"🔌 [ScrcpyVNCClient] Cleanup completed");
}

#pragma mark - ScrcpyClientProtocol

- (void)disconnect {
    NSLog(@"🔌 [ScrcpyVNCClient] disconnect method called (ScrcpyClientProtocol)");

    // 防止重复清理
    if (self.isCleaningUp) {
        NSLog(@"⚠️ [ScrcpyVNCClient] Already cleaning up, skipping");
        return;
    }
    self.isCleaningUp = YES;

    // Stop audio streaming first
    [self stopAudioStreaming];
    
    // 首先取消所有正在进行的连接操作
    if (self.connectionQueue) {
        NSLog(@"🔌 [ScrcpyVNCClient] Cancelling all connection operations");
        [self.connectionQueue cancelAllOperations];
        NSLog(@"🔌 [ScrcpyVNCClient] All connection operations cancelled");
    }
    
    // 清理当前操作引用
    self.currentConnectionOperation = nil;
    
    // 判断当前连接状态，分别处理
    self.forceStop = YES;
    if (self.connected && self.rfbClient) {
        NSLog(@"🔌 [ScrcpyVNCClient] Connected client detected, using SDL_Quit for normal exit");
        // 如果已连接并启动了SDL事件循环
        SDL_Event event;
        event.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&event);
    } else if (self.rfbClient) {
        NSLog(@"🔌 [ScrcpyVNCClient] Connecting state detected, cancelling connection and cleaning up RFB client");
        // 清理VNC运行时回调
        VNCRuntimeCleanupCallbacks(self.rfbClient);
        
        // 清理连接队列
        [self.currentConnectionOperation cancel];
        [self.connectionQueue cancelAllOperations];
        
        // 清理RFB客户端
        self.rfbClient = NULL;
        
        NSLog(@"🔌 [ScrcpyVNCClient] RFB client cleaned up");
        
        // 手动更新状态（因为没有SDL事件循环处理）
        self.connected = NO;
        self.scrcpyStatus = ScrcpyStatusDisconnected;
        ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "VNC connection cancelled");
    } else {
        NSLog(@"🔌 [ScrcpyVNCClient] No active connection to disconnect");
    }
    
    // 清理全局光标纹理
    VNCRuntimeCleanupGlobalCursorTexture();
    
    // 重置清理标志
    self.isCleaningUp = NO;
    
    NSLog(@"🔌 [ScrcpyVNCClient] Disconnect completed");
}

#pragma mark - 通知处理

- (void)handleDisconnectRequest:(NSNotification *)notification {
    NSLog(@"🔔 [ScrcpyVNCClient] Received disconnect request notification");
    
    if (self.connected && self.scrcpyStatus != ScrcpyStatusDisconnected) {
        NSLog(@"🔌 [ScrcpyVNCClient] Stopping VNC connection due to disconnect request");
        [self disconnect];
    } else {
        NSLog(@"ℹ️ [ScrcpyVNCClient] No active VNC connection to disconnect");
    }
    
    // Clean references
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)handleVNCMouseEvent:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle mouse event: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Mouse event notification missing userInfo");
        return;
    }
    
    NSString *eventType = userInfo[kKeyType];
    
    if (!eventType) {
        NSLog(@"❌ [ScrcpyVNCClient] Mouse event notification missing event type");
        return;
    }
    
    NSLog(@"🎯 [ScrcpyVNCClient] Mouse event: %@, using stored coordinates: (%d,%d) on %dx%d screen", 
          eventType, self.currentMouseX, self.currentMouseY, self.rfbClient->width, self.rfbClient->height);
    
    if ([eventType isEqualToString:kMouseEventTypeClick]) {
        // 处理点击事件 - 忽略传入的坐标，使用存储的鼠标坐标
        NSNumber *isRightClickNumber = userInfo[kKeyIsRightClick];
        BOOL isRightClick = [isRightClickNumber boolValue];
        
        [self sendMouseClickAtX:self.currentMouseX y:self.currentMouseY isRightClick:isRightClick];
    } else if ([eventType isEqualToString:kMouseEventTypeMove]) {
        // 处理鼠标移动事件 - 可以根据需要实现额外的鼠标移动逻辑
        // 这里可以添加基于其他输入源的鼠标移动逻辑
        NSLog(@"🐭 [ScrcpyVNCClient] Mouse move event received - current position maintained at (%d,%d)", 
              self.currentMouseX, self.currentMouseY);
    }
    // 其他事件类型（拖拽等）可以在此处添加处理
}

- (void)handleVNCDragOffset:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle drag offset: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Drag offset notification missing userInfo");
        return;
    }
    
    NSValue *normalizedOffsetValue = userInfo[kKeyNormalizedOffset];
    NSValue *viewSizeValue = userInfo[kKeyViewSize];
    NSNumber *zoomScaleNumber = userInfo[kKeyZoomScale];
    
    if (!normalizedOffsetValue || !viewSizeValue) {
        NSLog(@"❌ [ScrcpyVNCClient] Drag offset notification missing required data");
        return;
    }
    
    CGPoint normalizedOffset = [normalizedOffsetValue CGPointValue];
    CGSize viewSize = [viewSizeValue CGSizeValue];
    CGFloat zoomScale = zoomScaleNumber ? [zoomScaleNumber floatValue] : 1.0;
    
    // 直接将手势移动距离乘以远程桌面的缩放系数
    // 这样可以保持手势移动距离与远程鼠标移动距离的1:1对应关系
    
    // 获取远程屏幕尺寸
    int remoteWidth = self.rfbClient->width;
    int remoteHeight = self.rfbClient->height;
    
    // 计算远程内容在本地的显示缩放比例（保持宽高比）
    CGFloat scaleX = viewSize.width / (CGFloat)remoteWidth;
    CGFloat scaleY = viewSize.height / (CGFloat)remoteHeight;
    CGFloat displayScale = MIN(scaleX, scaleY);  // 取较小值保持比例
    
    // 将归一化偏移量转换为实际像素距离
    CGFloat pixelOffsetX = normalizedOffset.x * viewSize.width;
    CGFloat pixelOffsetY = normalizedOffset.y * viewSize.height;
    
    // 将手势移动距离乘以远程桌面的缩放系数（displayScale的倒数）
    // 这样手势在屏幕上移动的距离就等于远程鼠标移动的距离
    CGFloat remoteOffsetX = pixelOffsetX / displayScale;
    CGFloat remoteOffsetY = pixelOffsetY / displayScale;
    
    // 考虑用户缩放倍数进行精细控制调整
    CGFloat finalOffsetX = remoteOffsetX / zoomScale;
    CGFloat finalOffsetY = remoteOffsetY / zoomScale;
    
    // 转换为整数像素偏移量
    int offsetX = (int)round(finalOffsetX);
    int offsetY = (int)round(finalOffsetY);
    
    // 检测是否有实际的鼠标移动
    if (offsetX != 0 || offsetY != 0) {
        // 设置鼠标移动标记，用于边缘跟随检测
        VNCRuntimeSetMouseMoved();
    }
    
    // 使用拖拽开始时的鼠标位置作为起点计算新的鼠标位置
    int newMouseX = self.dragStartMouseX + offsetX;
    int newMouseY = self.dragStartMouseY + offsetY;
    
    // 移动鼠标到新位置
    [self moveMouseToX:newMouseX y:newMouseY];
}

- (void)handleVNCDragState:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle drag state: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Drag state notification missing userInfo");
        return;
    }
    
    NSString *state = userInfo[kKeyState];
    if (!state) {
        NSLog(@"❌ [ScrcpyVNCClient] Drag state notification missing state");
        return;
    }
    
    if ([state isEqualToString:kDragStateBegan]) {
        // 拖拽开始时记录当前鼠标位置作为起点
        self.dragStartMouseX = self.currentMouseX;
        self.dragStartMouseY = self.currentMouseY;
        
        NSLog(@"🎯 [ScrcpyVNCClient] Drag began - recorded start position: (%d,%d)", 
              self.dragStartMouseX, self.dragStartMouseY);
    } else if ([state isEqualToString:kDragStateEnded] || [state isEqualToString:kDragStateCancelled]) {
        // 拖拽结束时可以进行清理（如果需要）
        NSLog(@"🎯 [ScrcpyVNCClient] Drag %@ - start position was: (%d,%d), final position: (%d,%d)", 
              state, self.dragStartMouseX, self.dragStartMouseY, self.currentMouseX, self.currentMouseY);
    }
}

- (void)handleVNCScrollEvent:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle scroll event: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Scroll event notification missing userInfo");
        return;
    }
    
    NSString *state = userInfo[kKeyState];
    NSValue *offsetValue = userInfo[kKeyOffset];
    NSValue *viewSizeValue = userInfo[kKeyViewSize];
    NSNumber *zoomScaleNumber = userInfo[kKeyZoomScale];
    
    if (!state || !offsetValue || !viewSizeValue) {
        NSLog(@"❌ [ScrcpyVNCClient] Scroll event notification missing required data");
        return;
    }
    
    CGPoint offset = [offsetValue CGPointValue];
    CGSize viewSize = [viewSizeValue CGSizeValue];
    CGFloat zoomScale = zoomScaleNumber ? [zoomScaleNumber floatValue] : 1.0;
    
    if ([state isEqualToString:kDragStateBegan]) {
        // 滚动开始，记录起点位置并重置累积器
        self.dragStartMouseX = self.currentMouseX;
        self.dragStartMouseY = self.currentMouseY;
        self.scrollAccumulatorY = 0.0;  // 重置滚动累积器
        self.lastScrollOffset = CGPointZero;  // 重置上一次偏移量
        
        NSLog(@"📜 [ScrcpyVNCClient] Scroll began - recorded start position: (%d,%d), reset accumulator and last offset", 
              self.dragStartMouseX, self.dragStartMouseY);
    } else if ([state isEqualToString:kDragStateChanged]) {
        // 滚动过程中，计算滚动量并发送滚动事件
        [self sendMouseScrollWithOffset:offset viewSize:viewSize zoomScale:zoomScale];
    } else if ([state isEqualToString:kDragStateEnded]) {
        // 滚动结束，发送最终滚动事件并重置累积器
        [self sendMouseScrollWithOffset:offset viewSize:viewSize zoomScale:zoomScale];
        
        NSLog(@"📜 [ScrcpyVNCClient] Scroll ended - final offset: (%.1f,%.1f), final accumulator: %.2f", 
              offset.x, offset.y, self.scrollAccumulatorY);
        
        // 滚动结束后重置累积器和上一次偏移量
        self.scrollAccumulatorY = 0.0;
        self.lastScrollOffset = CGPointZero;
    } else if ([state isEqualToString:kDragStateCancelled]) {
        NSLog(@"📜 [ScrcpyVNCClient] Scroll cancelled - resetting accumulator and last offset");
        // 滚动取消时也重置累积器
        self.scrollAccumulatorY = 0.0;
        self.lastScrollOffset = CGPointZero;
    }
}

- (void)sendMouseScrollWithOffset:(CGPoint)offset viewSize:(CGSize)viewSize zoomScale:(CGFloat)zoomScale {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send mouse scroll: VNC not connected");
        return;
    }
    
    // 获取远程屏幕尺寸
    int remoteWidth = self.rfbClient->width;
    int remoteHeight = self.rfbClient->height;
    
    // 计算远程内容在本地的显示缩放比例（保持宽高比）
    CGFloat scaleX = viewSize.width / (CGFloat)remoteWidth;
    CGFloat scaleY = viewSize.height / (CGFloat)remoteHeight;
    CGFloat displayScale = MIN(scaleX, scaleY);  // 取较小值保持比例
    
    // 优化滚动偏移量计算，使用增量计算和累积器实现平滑滚动
    // 基础滚动敏感度系数
    static const CGFloat kScrollSensitivity = 0.5;  // 滚动敏感度
    static const CGFloat kScrollThreshold = 12.0;   // 滚动阈值（累积到这个值才触发滚动）
    
    // 计算增量偏移（当前偏移 - 上一次偏移）
    CGFloat deltaY = offset.y - self.lastScrollOffset.y;
    
    // 将增量手势偏移转换为远程坐标偏移（考虑显示缩放）
    CGFloat remoteDeltaY = deltaY / displayScale;
    
    // 考虑用户缩放倍数（zoomScale越大，滚动越精细）
    CGFloat adjustedDeltaY = remoteDeltaY / zoomScale;
    
    // 应用滚动敏感度并累积到累积器中（只累积增量）
    self.scrollAccumulatorY += adjustedDeltaY * kScrollSensitivity;
    
    // 更新上一次偏移量
    self.lastScrollOffset = offset;
    
    // 计算需要执行的滚动步数
    int scrollSteps = 0;
    int scrollButton = 0;
    int scrollButtonMask = 0;
    
    if (fabs(self.scrollAccumulatorY) >= kScrollThreshold) {
        // 确定滚动方向, Nature 自然滚动方向, 跟着手势方向滚动
        BOOL scrollUp = (self.scrollAccumulatorY > 0);
        scrollButton = scrollUp ? 4 : 5;  // 按钮4：向上滚动，按钮5：向下滚动
        scrollButtonMask = scrollUp ? (1 << 3) : (1 << 4);  // rfbButton4Mask or rfbButton5Mask
        
        // 计算滚动步数
        scrollSteps = (int)(fabs(self.scrollAccumulatorY) / kScrollThreshold);
        scrollSteps = MIN(scrollSteps, 5);  // 限制最大滚动步数
        
        // 从累积器中减去已处理的滚动量
        CGFloat processedScroll = scrollSteps * kScrollThreshold;
        if (self.scrollAccumulatorY > 0) {
            self.scrollAccumulatorY -= processedScroll;
        } else {
            self.scrollAccumulatorY += processedScroll;
        }
    }
    
    NSLog(@"📜 [ScrcpyVNCClient] Incremental scroll calculation:");
    NSLog(@"   Remote: %dx%d, View: %.0fx%.0f, DisplayScale: %.3f, ZoomScale: %.3f", 
          remoteWidth, remoteHeight, viewSize.width, viewSize.height, displayScale, zoomScale);
    NSLog(@"   CurrentOffset: %.1f, LastOffset: %.1f -> DeltaY: %.1f", 
          offset.y, self.lastScrollOffset.y, deltaY);
    NSLog(@"   RemoteDelta: %.1f -> AdjustedDelta: %.1f -> Accumulator: %.2f", 
          remoteDeltaY, adjustedDeltaY, self.scrollAccumulatorY);
    NSLog(@"   Threshold: %.1f, Steps: %d, Button: %d", 
          kScrollThreshold, scrollSteps, scrollButton);
    
    // 只在累积器超过阈值时才发送滚动事件
    if (scrollSteps > 0) {
        // 发送滚动事件（使用当前鼠标位置）
        for (int i = 0; i < scrollSteps; i++) {
            // 发送滚动按钮按下事件
            if (!SendPointerEvent(self.rfbClient, self.currentMouseX, self.currentMouseY, scrollButtonMask)) {
                NSLog(@"❌ [ScrcpyVNCClient] Failed to send scroll button down event (step %d)", i + 1);
                return;
            }
            
            // 发送滚动按钮松开事件
            if (!SendPointerEvent(self.rfbClient, self.currentMouseX, self.currentMouseY, 0)) {
                NSLog(@"❌ [ScrcpyVNCClient] Failed to send scroll button up event (step %d)", i + 1);
                return;
            }
            
            // 滚动事件之间的小延迟，保证服务器能正确处理
            usleep(8000);  // 8ms延迟，提高响应速度
        }
        
        NSLog(@"📜 [ScrcpyVNCClient] Scroll event sent: %d steps %@ at position (%d,%d), remaining accumulator: %.2f", 
              scrollSteps, (scrollButton == 4) ? @"UP" : @"DOWN", self.currentMouseX, self.currentMouseY, self.scrollAccumulatorY);
    } else {
        NSLog(@"📜 [ScrcpyVNCClient] Scroll accumulating: %.2f (threshold: %.1f)", 
              self.scrollAccumulatorY, kScrollThreshold);
    }
}

- (void)handleVNCZoomEvent:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle zoom event: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Zoom event notification missing userInfo");
        return;
    }
    
    NSNumber *scaleNumber = userInfo[@"scale"];
    NSNumber *centerXNumber = userInfo[@"centerX"];
    NSNumber *centerYNumber = userInfo[@"centerY"];
    NSNumber *isFinishedNumber = userInfo[@"isFinished"];
    
    if (!scaleNumber || !centerXNumber || !centerYNumber || !isFinishedNumber) {
        NSLog(@"❌ [ScrcpyVNCClient] Zoom event notification missing required data");
        return;
    }
    
    CGFloat scale = [scaleNumber floatValue];
    CGFloat centerX = [centerXNumber floatValue];
    CGFloat centerY = [centerYNumber floatValue];
    BOOL isFinished = [isFinishedNumber boolValue];
    
    NSLog(@"🔍 [ScrcpyVNCClient] Zoom event - scale: %.2f, center: (%.3f, %.3f), finished: %@", 
          scale, centerX, centerY, isFinished ? @"YES" : @"NO");
    
    // 这里应该实现实际的缩放逻辑，比如调整SDL视图的缩放
    // 由于VNC协议本身不支持缩放，这里需要在客户端实现视图缩放
    // 可以通过修改SDL渲染的视口和缩放来实现
    
    // 发送缩放更新到SDL渲染层
    [self applyZoomScale:scale withCenterX:centerX centerY:centerY isFinished:isFinished];
}

- (void)applyZoomScale:(CGFloat)scale withCenterX:(CGFloat)centerX centerY:(CGFloat)centerY isFinished:(BOOL)isFinished {
    NSLog(@"🔍 [ScrcpyVNCClient] Setting zoom scale: %.2f at center (%.3f, %.3f), finished: %@", 
          scale, centerX, centerY, isFinished ? @"YES" : @"NO");
    
    // 更新缩放参数
    self.currentZoomScale = scale;
    self.zoomCenterX = centerX;
    self.zoomCenterY = centerY;
    self.zoomUpdatePending = YES;
    
    // 请求帧缓冲更新以触发重新渲染（使用智能策略）
    if (self.rfbClient && self.connected) {
        [self sendSmartFramebufferUpdateRequest];
        NSLog(@"🔍 [ScrcpyVNCClient] Requested framebuffer update for zoom application");
    }
}

#pragma mark - 键盘事件处理

- (void)sendKeyEvent:(int)keyCode isPressed:(BOOL)isPressed {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send key event: VNC not connected");
        return;
    }
    
    // 发送键盘事件到VNC服务器
    if (!SendKeyEvent(self.rfbClient, keyCode, isPressed)) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send key event: keyCode=%d, pressed=%@", keyCode, isPressed ? @"YES" : @"NO");
        return;
    }
    
    NSLog(@"⌨️ [ScrcpyVNCClient] Key event sent: keyCode=%d, pressed=%@", keyCode, isPressed ? @"YES" : @"NO");
}

- (void)sendTextInput:(NSString *)text {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send text input: VNC not connected");
        return;
    }
    
    if (!text || text.length == 0) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send empty text input");
        return;
    }
    // 将文本作为一系列按键事件发送（而非剪贴板），确保远程输入框能直接显示字符
    // 处理基本ASCII与BMP字符：ASCII直接发送对应keysym；BMP和代理对使用Unicode keysym编码
    // 参考 X11/keysym 约定：Unicode keysym = 0x01000000 | UCS-4 码点
    NSUInteger i = 0;
    while (i < text.length) {
        unichar high = [text characterAtIndex:i++];
        uint32_t codepoint = 0;
        if (CFStringIsSurrogateHighCharacter(high)) {
            if (i < text.length) {
                unichar low = [text characterAtIndex:i];
                if (CFStringIsSurrogateLowCharacter(low)) {
                    codepoint = CFStringGetLongCharacterForSurrogatePair(high, low);
                    i++; // 消耗低位代理项
                } else {
                    // 非法代理对，跳过该字符
                    continue;
                }
            } else {
                // 字符串结尾的孤立高位代理，跳过
                continue;
            }
        } else {
            codepoint = (uint32_t)high;
        }

        uint32_t keysym;
        // 特殊控制字符映射
        if (codepoint == '\n' || codepoint == '\r') {
            keysym = XK_Return;
        } else if (codepoint == '\t') {
            keysym = XK_Tab;
        } else if (codepoint == 0x08) { // Backspace
            keysym = XK_BackSpace;
        } else if (codepoint <= 0x007F) {
            // ASCII 直接作为 keysym 发送
            keysym = codepoint;
        } else if (codepoint <= 0xFFFF) {
            // BMP 范围使用 Unicode keysym 编码
            keysym = 0x01000000u | codepoint;
        } else {
            // 超出BMP（如部分emoji），同样使用 Unicode keysym 编码
            keysym = 0x01000000u | codepoint;
        }

        if (!SendKeyEvent(self.rfbClient, keysym, TRUE)) {
            NSLog(@"❌ [ScrcpyVNCClient] Failed to send key down for codepoint U+%04X", codepoint);
            continue;
        }
        if (!SendKeyEvent(self.rfbClient, keysym, FALSE)) {
            NSLog(@"❌ [ScrcpyVNCClient] Failed to send key up for codepoint U+%04X", codepoint);
            continue;
        }
    }

    NSLog(@"📝 [ScrcpyVNCClient] Text input typed: %@", text);
}

- (void)handleVNCKeyboardEvent:(NSNotification *)notification {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle keyboard event: VNC not connected");
        return;
    }
    
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        NSLog(@"❌ [ScrcpyVNCClient] Keyboard event notification missing userInfo");
        return;
    }
    
    NSString *eventType = userInfo[kKeyType];
    if (!eventType) {
        NSLog(@"❌ [ScrcpyVNCClient] Keyboard event notification missing event type");
        return;
    }
    
    NSLog(@"⌨️ [ScrcpyVNCClient] Keyboard event received: %@", eventType);
    
    if ([eventType isEqualToString:kKeyboardEventTypeKeyDown]) {
        // 处理按键按下事件
        NSNumber *keyCodeNumber = userInfo[kKeyKeyCode];
        if (keyCodeNumber) {
            int keyCode = [keyCodeNumber intValue];
            [self sendKeyEvent:keyCode isPressed:YES];
        }
    } else if ([eventType isEqualToString:kKeyboardEventTypeKeyUp]) {
        // 处理按键释放事件
        NSNumber *keyCodeNumber = userInfo[kKeyKeyCode];
        if (keyCodeNumber) {
            int keyCode = [keyCodeNumber intValue];
            [self sendKeyEvent:keyCode isPressed:NO];
        }
    } else if ([eventType isEqualToString:kKeyboardEventTypeTextInput]) {
        // 处理文本输入事件
        NSString *text = userInfo[kKeyText];
        if (text) {
            [self sendTextInput:text];
        }
    }
}

#pragma mark - 连续更新支持

- (void)sendEnableContinuousUpdates:(BOOL)enable x:(int)x y:(int)y width:(int)width height:(int)height {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot send continuous updates message: VNC not connected");
        return;
    }
    
    // 构建EnableContinuousUpdates消息（消息类型150）
    uint8_t messageType = 150;
    uint8_t enableFlag = enable ? 1 : 0;
    uint16_t xPos = htons((uint16_t)x);
    uint16_t yPos = htons((uint16_t)y);
    uint16_t msgWidth = htons((uint16_t)width);
    uint16_t msgHeight = htons((uint16_t)height);
    
    // 构建10字节的消息
    uint8_t message[10] = {
        messageType,           // 1字节：消息类型
        enableFlag,           // 1字节：启用标志
        (uint8_t)(xPos >> 8), (uint8_t)(xPos & 0xFF),         // 2字节：X坐标
        (uint8_t)(yPos >> 8), (uint8_t)(yPos & 0xFF),         // 2字节：Y坐标
        (uint8_t)(msgWidth >> 8), (uint8_t)(msgWidth & 0xFF), // 2字节：宽度
        (uint8_t)(msgHeight >> 8), (uint8_t)(msgHeight & 0xFF) // 2字节：高度
    };
    
    // 发送消息到VNC服务器
    if (!WriteToRFBServer(self.rfbClient, (char*)message, sizeof(message))) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send EnableContinuousUpdates message");
        return;
    }
    
    NSLog(@"📡 [ScrcpyVNCClient] Sent EnableContinuousUpdates: enable=%@, region=(%d,%d,%d,%d)", 
          enable ? @"YES" : @"NO", x, y, width, height);
}

// 帧缓冲更新请求节流
static CFAbsoluteTime sLastFramebufferRequestTime = 0;
static const CFAbsoluteTime kMinFramebufferRequestInterval = 0.033;  // 最多30fps请求

- (void)sendSmartFramebufferUpdateRequest {
    if (!self.connected || !self.rfbClient) {
        return;
    }

    // 检查socket是否有效
    if (self.rfbClient->sock == RFB_INVALID_SOCKET) {
        return;
    }

    // 如果连续更新已启用，则不发送传统的更新请求
    if (self.areContinuousUpdatesEnabled) {
        return;
    }

    // 节流：限制请求频率
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - sLastFramebufferRequestTime < kMinFramebufferRequestInterval) {
        return;
    }
    sLastFramebufferRequestTime = now;

    // 使用增量更新标志（首次为全量，后续为增量）
    BOOL incremental = self.incrementalUpdatesEnabled;

    if (!SendFramebufferUpdateRequest(self.rfbClient, 0, 0, self.rfbClient->width, self.rfbClient->height, incremental)) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send framebuffer update request");
        return;
    }
    
    // 首次发送后启用增量更新
    if (!incremental) {
        self.incrementalUpdatesEnabled = YES;
        NSLog(@"🔄 [ScrcpyVNCClient] Sent full framebuffer update request, enabling incremental updates");
    } else {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if ((now - sLastIncrementalUpdateLogTime) >= kVNCLogThrottleInterval) {
            if (sSuppressedIncrementalUpdateLogs > 0) {
                NSLog(@"🔄 [ScrcpyVNCClient] Sent incremental framebuffer update request (suppressed %lu repeats)", (unsigned long)sSuppressedIncrementalUpdateLogs);
                sSuppressedIncrementalUpdateLogs = 0;
            } else {
                NSLog(@"🔄 [ScrcpyVNCClient] Sent incremental framebuffer update request");
            }
            sLastIncrementalUpdateLogTime = now;
        } else {
            sSuppressedIncrementalUpdateLogs++;
        }
    }
}

- (void)handleEndOfContinuousUpdates {
    if (!self.connected || !self.rfbClient) {
        NSLog(@"❌ [ScrcpyVNCClient] Cannot handle EndOfContinuousUpdates: VNC not connected");
        return;
    }
    
    // 检查是否是首次收到该消息
    BOOL isFirstTime = !self.areContinuousUpdatesSupported;
    
    // 标记服务器支持连续更新
    self.areContinuousUpdatesSupported = YES;
    
    if (isFirstTime) {
        // 首次收到 - 启用连续更新模式
        self.areContinuousUpdatesEnabled = YES;
        NSLog(@"✅ [ScrcpyVNCClient] Server supports continuous updates - enabling continuous mode");
        
        // 发送启用连续更新的消息
        [self sendEnableContinuousUpdates:YES 
                                        x:0 
                                        y:0 
                                    width:self.rfbClient->width 
                                   height:self.rfbClient->height];
    } else {
        // 非首次收到 - 禁用连续更新，回退到传统模式
        self.areContinuousUpdatesEnabled = NO;
        NSLog(@"⚠️ [ScrcpyVNCClient] Continuous updates disabled by server - falling back to traditional mode");
        
        // 立即发送传统的帧缓冲更新请求以确保连续性
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self sendSmartFramebufferUpdateRequest];
        });
    }
}

// MARK: - VNC Quick Actions

- (void)executeVNCActions:(NSArray<NSNumber *> *)vncActions completion:(void(^)(BOOL success, NSString *error))completion {
    if (!self.connected || !self.rfbClient) {
        if (completion) completion(NO, @"VNC not connected");
        return;
    }

    // Swift 侧映射：0 = InputKeys, 1 = SyncClipboard
    for (NSNumber *actionNum in vncActions) {
        NSInteger action = actionNum.integerValue;
        switch (action) {
            case 0: { // InputKeys
                // 键动作通过 SessionConnectionManager 直接以通知方式发送到本类
                // 这里无需处理，留作兼容占位以避免崩溃
                NSLog(@"🧩 [ScrcpyVNCClient] executeVNCActions: InputKeys placeholder (handled via notifications)");
                break;
            }
            case 1: { // SyncClipboard -> 将本地剪贴板同步到远端
                NSString *clip = [UIPasteboard generalPasteboard].string;
                if (clip.length == 0) {
                    NSLog(@"📋 [ScrcpyVNCClient] Local clipboard empty, notifying UI");
                    // 通知 UI 显示无本地剪贴板内容的提示
                    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCClipboardSynced
                                                                        object:nil
                                                                      userInfo:@{ kKeyIsEmpty: @YES }];
                    break;
                }
                const char *utf8 = [clip UTF8String];
                if (!SendClientCutText(self.rfbClient, (char *)utf8, (int)strlen(utf8))) {
                    if (completion) completion(NO, @"Failed to sync clipboard to VNC server");
                    return;
                }
                NSLog(@"📋 [ScrcpyVNCClient] Synced clipboard to server (%lu bytes)", (unsigned long)strlen(utf8));
                // 通知 UI 层显示提示（不展示内容，仅提示成功）
                [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCClipboardSynced
                                                                    object:nil
                                                                  userInfo:@{ kKeyIsEmpty: @NO }];
                break;
            }
            default:
                NSLog(@"⚠️ [ScrcpyVNCClient] Unknown VNC action: %ld", (long)action);
                break;
        }
    }

    if (completion) completion(YES, nil);
}

@end
