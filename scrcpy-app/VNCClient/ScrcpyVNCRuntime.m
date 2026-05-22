//
//  ScrcpyVNCRuntime.m
//  VNCClient
//
//  Created by Ethan on 6/28/25.
//

#import "ScrcpyVNCRuntime.h"
#import "ScrcpyCommon.h"
#import "ScrcpyConstants.h"
#import <SDL3/SDL.h>
#import <rfb/rfbclient.h>
#import <arpa/inet.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdatomic.h>
#import <unistd.h>
#import "ScrcpyVNCClient.h"

// 光标边缘跟随常量定义
static const int CURSOR_EDGE_THRESHOLD = 20;     // 边缘阈值（像素）- 光标距离屏幕边缘多近时触发跟随
static const int CURSOR_FOLLOW_DISTANCE = 60;    // 边缘跟随移动距离 - 增加以更快追赶快速移动的光标
static const int CURSOR_FOLLOW_COOLDOWN = 1;     // 冷却时间（帧数）- 降低为1帧以实现更快响应

// 快速移动时的追赶常量
static const int CURSOR_FAST_FOLLOW_MULTIPLIER = 3;  // 光标超出边界时的追赶倍数
static const int CURSOR_MAX_FOLLOW_DISTANCE = 200;   // 单次最大追赶距离

// 旧版本的常量定义（用于旧函数，后续将移除）
static const int CURSOR_FOLLOW_SPEED = 8;        // 每帧移动速度（像素）- 平滑连续移动
static const float CURSOR_FOLLOW_ACCELERATION = 1.5f; // 加速系数 - 距离边缘越近移动越快

// 光标位置跟踪变量 - 用于检测移动方向和防振荡
static int g_lastScreenMouseX = -1;
static int g_lastScreenMouseY = -1;
static int g_lastRemoteMouseX = -1;   // 上次的远程鼠标X坐标
static int g_lastRemoteMouseY = -1;   // 上次的远程鼠标Y坐标
static int g_lastViewOffsetX = 0;
static int g_lastViewOffsetY = 0;
static int g_edgeFollowCooldown = 0;  // 防振荡冷却计数器
static BOOL g_mouseMovedThisFrame = NO;  // 标记本帧是否由于鼠标移动产生位置变化
static BOOL g_mouseIsMoving = NO;     // 标记鼠标是否正在移动
static BOOL g_mouseJustStopped = NO;  // 标记鼠标是否刚刚停止移动（用于边界情况）
static int g_mouseStopCounter = 0;    // 鼠标停止移动计数器
static const int MOUSE_STOP_THRESHOLD = 3;  // 鼠标停止移动阈值（帧数）

// ============================================================================
// VNC渲染优化 - 基于libVNC SDLvncviewer示例和Metal/iOS最佳实践
// ============================================================================
//
// 关键优化策略：
// 1. 参考libVNC官方示例：update()回调应该简单直接，立即更新纹理并渲染
// 2. SDL_UpdateTexture在已有像素数据时比SDL_LockTexture更快（减少一次拷贝）
// 3. 使用dispatch_async避免阻塞VNC消息循环，但需要拷贝像素数据到缓冲区
// 4. 帧合并：多个小矩形更新合并为一次RenderPresent调用
//
// 参考资料：
// - https://libvnc.github.io/doc/html/_s_d_lvncviewer_8c-example.html
// - https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/
// ============================================================================

// ============================================================================
// 渲染策略 - 主线程纹理更新 + 同步呈现
// ============================================================================
//
// Metal/SDL要求：
// - SDL_UpdateTexture必须在主线程调用（Metal命令缓冲区不是线程安全的）
// - SDL_RenderPresent也必须在主线程调用
//
// 新策略：
// 1. GotFrameBufferUpdate复制像素数据，然后dispatch到主线程更新纹理
// 2. 使用dispatch_sync确保所有纹理更新在FinishedFrameBufferUpdate前完成
// 3. FinishedFrameBufferUpdate在主线程触发呈现
//
// 关键：使用信号量确保所有纹理更新完成后才呈现
// ============================================================================

// 帧更新计数器 - 追踪当前帧的矩形更新数量
static _Atomic int g_frameUpdateCount = 0;
static _Atomic int g_frameUpdatesCompleted = 0;

// 渲染呈现节流 - 限制SDL_RenderPresent调用频率
static CFAbsoluteTime g_lastPresentTime = 0;
static const CFAbsoluteTime kMinPresentInterval = 1.0 / 60.0;  // 60fps上限

// 渲染串行队列 - 仅用于呈现操作
static dispatch_queue_t g_renderQueue = NULL;

// 渲染锁 - 防止同时进行VNC帧渲染和光标渲染导致Metal阻塞
static _Atomic int g_presentInProgress = 0;

// 保存SDL渲染对象用于强制重渲染
static SDL_Renderer* g_savedRenderer = NULL;
static SDL_Texture* g_savedTexture = NULL;
static SDL_Window* g_savedWindow = NULL;

// 纹理尺寸
static int g_textureWidth = 0;
static int g_textureHeight = 0;

static dispatch_queue_t VNCGetRenderQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 创建目标为主线程的串行队列
        g_renderQueue = dispatch_queue_create("com.scrcpy.vnc.render", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(g_renderQueue, dispatch_get_main_queue());
    });
    return g_renderQueue;
}


// 前向声明
void VNCRuntimeDrawMacOSCursor(SDL_Renderer* renderer, int x, int y, float scale);
void VNCRuntimeSetMouseMoved(void);
static void VNCRuntimeCheckCursorEdgeFollow(ScrcpyVNCClient* vncClient, int screenMouseX, int screenMouseY,
                                          int remoteMouseX, int remoteMouseY,
                                          int renderWidth, int renderHeight, int* offsetX, int* offsetY,
                                          int scaledWidth, int scaledHeight, int textureWidth, int textureHeight, float finalScale);

// 连续更新相关的前向声明
static rfbBool VNCRuntimeHandleServerMessage(rfbClient* client, rfbServerToClientMsg* message);
static rfbBool (*originalHandleRFBServerMessage)(rfbClient* client) = NULL;

/**
 * 自定义的SetFormatAndEncodings函数，确保包含光标编码
 */
static rfbBool CustomSetFormatAndEncodings(rfbClient* client) {
    // 首先调用原始的SetFormatAndEncodings函数
    rfbBool result = SetFormatAndEncodings(client);
    
    if (!result) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to set format and encodings");
        return FALSE;
    }
    
    // 发送额外的编码设置，确保包含光标编码和连续更新支持
    uint32_t encodings[] = {
        rfbEncodingZlib,
        rfbEncodingZRLE,
        rfbEncodingHextile,
        rfbEncodingCoRRE,
        rfbEncodingRRE,
        rfbEncodingTight,
        rfbEncodingRaw,
        rfbEncodingCopyRect,
        rfbEncodingXCursor,      // 添加X光标编码
        rfbEncodingRichCursor,   // 添加富光标编码
        rfbEncodingPointerPos,   // 添加指针位置编码
        (uint32_t)-313           // 添加连续更新伪编码（Continuous Updates）
    };
    
    int numEncodings = sizeof(encodings) / sizeof(encodings[0]);
    
    // 发送SetEncodings消息
    rfbSetEncodingsMsg msg;
    msg.type = rfbSetEncodings;
    msg.pad = 0;
    msg.nEncodings = htons(numEncodings);
    
    if (!WriteToRFBServer(client, (char *)&msg, sz_rfbSetEncodingsMsg)) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to send SetEncodings message header");
        return FALSE;
    }
    
    // 发送编码列表
    for (int i = 0; i < numEncodings; i++) {
        uint32_t encoding = htonl(encodings[i]);
        if (!WriteToRFBServer(client, (char *)&encoding, sizeof(encoding))) {
            NSLog(@"❌ [ScrcpyVNCClient] Failed to send encoding %d", encodings[i]);
            return FALSE;
        }
    }
    
    NSLog(@"✅ [ScrcpyVNCClient] Successfully set encodings including cursor encodings");
    return TRUE;
}


// VNC runtime callback implementations

rfbBool VNCRuntimeMallocFrameBuffer(rfbClient* client, ScrcpyVNCClient *vncClient, SDL_Window **sdlWindow, SDL_Renderer **sdlRenderer, SDL_Texture **sdlTexture) {
    int width = client->width, height = client->height, depth = client->format.bitsPerPixel;

    // 保存VNC客户端实例引用，以便在回调中访问
    rfbClientSetClientData(client, (void*)0x1234, (__bridge void*)vncClient);

    // 保存原始尺寸（仅在第一次时保存）
    if (vncClient.imagePixelsSize.width == 0 && vncClient.imagePixelsSize.height == 0) {
        vncClient.imagePixelsSize = CGSizeMake(width, height);
        NSLog(@"🔍 [ScrcpyVNCClient] VNC remote screen size: %.0fx%.0f", (double)width, (double)height);
    }
    
    // 释放旧surface并创建新的
    // SDL3: SDL_CreateRGBSurface(flags, w, h, depth, Rmask, Gmask, Bmask, Amask)
    // is gone; use SDL_CreateSurface(w, h, format). Pick a packed pixel format
    // matching the requested depth.
    SDL_DestroySurface(rfbClientGetClientData(client, SDL_Init));
    SDL_PixelFormat pf = (depth == 32) ? SDL_PIXELFORMAT_ARGB8888
                                       : (depth == 24) ? SDL_PIXELFORMAT_RGB24
                                                       : SDL_PIXELFORMAT_RGB565;
    SDL_Surface* sdl = SDL_CreateSurface(width, height, pf);
    if (!sdl) {
        rfbClientErr("resize: error creating surface: %s\n", SDL_GetError());
        return FALSE;
    }

    rfbClientSetClientData(client, SDL_Init, sdl);
    client->width = sdl->pitch / (depth / 8);
    client->frameBuffer = sdl->pixels;

    // 设置像素格式
    // SDL3: surface->format is now an SDL_PixelFormat enum, not a pointer to
    // SDL_PixelFormatDetails. Get the shift/mask info via
    // SDL_GetPixelFormatDetails().
    const SDL_PixelFormatDetails *pfd = SDL_GetPixelFormatDetails(sdl->format);
    client->format.bitsPerPixel = depth;
    client->format.redShift = pfd ? pfd->Rshift : 0;
    client->format.greenShift = pfd ? pfd->Gshift : 0;
    client->format.blueShift = pfd ? pfd->Bshift : 0;
    client->format.redMax = pfd ? (pfd->Rmask >> client->format.redShift) : 0;
    client->format.greenMax = pfd ? (pfd->Gmask >> client->format.greenShift) : 0;
    client->format.blueMax = pfd ? (pfd->Bmask >> client->format.blueShift) : 0;
    
    CustomSetFormatAndEncodings(client);

    // 获取设备屏幕尺寸（考虑Retina缩放）
    // SDL3: SDL_GetCurrentDisplayMode(displayID) returns a pointer.
    int screenWidth = 0, screenHeight = 0;
    SDL_DisplayID primary = SDL_GetPrimaryDisplay();
    const SDL_DisplayMode *dm = SDL_GetCurrentDisplayMode(primary);
    if (dm) {
        NSLog(@"[VNCScreenDebug] SDL DisplayMode: %dx%d", dm->w, dm->h);
        screenWidth = dm->w;
        screenHeight = dm->h;
    }
    
    NSLog(@"[VNCScreenDebug] Final screen size: %dx%d", screenWidth, screenHeight);
    NSLog(@"[VNCScreenDebug] Remote screen size: %dx%d", width, height);
    
    // 计算缩放比例，保持宽高比
    float scaleX = (float)screenWidth / width;
    float scaleY = (float)screenHeight / height;
    float scale = fminf(scaleX, scaleY);
    
    NSLog(@"[VNCScreenDebug] Scale calculation: scaleX=%.3f, scaleY=%.3f, final scale=%.3f", scaleX, scaleY, scale);
    
    int scaledWidth = (int)(width * scale);
    int scaledHeight = (int)(height * scale);
    
    NSLog(@"[VNCScreenDebug] Scaled remote size: %dx%d", scaledWidth, scaledHeight);
    
    // 创建全屏窗口（使用设备屏幕尺寸）
    // SDL3: SDL_CreateWindow signature dropped the x/y args.
    int sdlFlags = SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_FULLSCREEN;
    *sdlWindow = SDL_CreateWindow(client->desktopName,
                                  screenWidth,
                                  screenHeight,
                                  sdlFlags);
                                 
    NSLog(@"[VNCScreenDebug] Created SDL window with size: %dx%d", screenWidth, screenHeight);
    if (!sdlWindow) {
        rfbClientErr("resize: error creating window: %s\n", SDL_GetError());
        return FALSE;
    }
    
    // 检查实际创建的窗口尺寸
    int actualWidth, actualHeight;
    SDL_GetWindowSize(*sdlWindow, &actualWidth, &actualHeight);
    NSLog(@"[VNCScreenDebug] Actual SDL window size: %dx%d", actualWidth, actualHeight);
    
    // 检查窗口标志
    Uint32 windowFlags = SDL_GetWindowFlags(*sdlWindow);
    NSLog(@"[VNCScreenDebug] Window flags: 0x%x (fullscreen: %s)",
          windowFlags, (windowFlags & SDL_WINDOW_FULLSCREEN) ? "YES" : "NO");

    // 更新状态
    vncClient.scrcpyStatus = ScrcpyStatusSDLWindowCreated;
    ScrcpyUpdateStatus(ScrcpyStatusSDLWindowCreated, "SDL window created successfully");

    // 使用VSync以避免画面撕裂，但配置Metal使用更多缓冲区减少阻塞
    // displaySyncEnabled=0 允许Metal不等待VBlank，但仍使用缓冲区避免撕裂
    SDL_SetHint(SDL_HINT_RENDER_METAL_PREFER_LOW_POWER_DEVICE, "0");

    // 创建渲染器，启用VSync以避免撕裂
    // SDL3: SDL_CreateRenderer(window, name); the index/flags args from SDL2
    // are gone, accelerated is implicit, and VSync is set after creation via
    // SDL_SetRenderVSync().
    *sdlRenderer = SDL_CreateRenderer(*sdlWindow, NULL);
    if (!*sdlRenderer) {
        rfbClientErr("resize: error creating renderer: %s\n", SDL_GetError());
        return FALSE;
    }
    SDL_SetRenderVSync(*sdlRenderer, 1);
    // SDL3 removed SDL_HINT_RENDER_SCALE_QUALITY; texture filtering is
    // configured per-texture via SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR)
    // at creation time, which the cursor texture below already does.
    
    // 获取设备缩放因子并设置SDL渲染器缩放
    float deviceScale = UIScreen.mainScreen.nativeScale;
    NSLog(@"[VNCScreenDebug] Device scale factor: %.2f", deviceScale);
    SDL_SetRenderScale(*sdlRenderer, deviceScale, deviceScale);
    
    // 保存渲染器
    vncClient.currentRenderer = *sdlRenderer;
    
    // 设置SDL窗口
    vncClient.sdlDelegate.window.windowScene = vncClient.currentScene;
    [vncClient.sdlDelegate.window makeKeyWindow];

    // 创建纹理
    *sdlTexture = SDL_CreateTexture(*sdlRenderer, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, width, height);
    if (!*sdlTexture) {
        rfbClientErr("resize: error creating texture: %s\n", SDL_GetError());
        return FALSE;
    }

    // 保存纹理尺寸
    g_textureWidth = width;
    g_textureHeight = height;

    // 保存纹理
    vncClient.currentTexture = *sdlTexture;

    // 设置帧缓冲区更新回调（在SDL对象创建后）
    vncClient.rfbClient->GotFrameBufferUpdate = GotFrameBufferUpdateBlock;
    VNCRuntimeSetupGotFrameBufferUpdateCallback(vncClient.rfbClient, *sdlTexture, *sdlRenderer, *sdlWindow);

    // 设置帧缓冲区更新完成回调（在所有矩形更新完成后调用，触发呈现）
    VNCRuntimeSetupFinishedFrameBufferUpdateCallback(vncClient.rfbClient, *sdlTexture, *sdlRenderer, *sdlWindow);

    return TRUE;
}

// 日志前缀定义
#define VNC_RENDER_LOG_PREFIX @"[VNCRender]"

static inline void VNCRuntimeGotFrameBufferUpdate(rfbClient* cl, int x, int y, int w, int h, SDL_Texture* sdlTexture, SDL_Renderer* sdlRenderer, SDL_Window* sdlWindow) {
    if (!sdlTexture || !sdlRenderer || !sdlWindow) {
        NSLog(@"%@ ❌ Invalid SDL objects: texture=%p, renderer=%p, window=%p", VNC_RENDER_LOG_PREFIX, sdlTexture, sdlRenderer, sdlWindow);
        return;
    }

    SDL_Surface *sdl = rfbClientGetClientData(cl, SDL_Init);
    if (!sdl || !sdl->pixels) {
        NSLog(@"%@ ❌ Invalid SDL surface or pixels", VNC_RENDER_LOG_PREFIX);
        return;
    }

    // ========================================================================
    // 主线程纹理更新策略
    // ========================================================================
    // Metal要求SDL_UpdateTexture在主线程调用
    // 我们在VNC线程复制像素数据，然后dispatch_sync到主线程更新纹理
    // 使用dispatch_sync确保更新完成后再返回，这样FinishedFrameBufferUpdate
    // 被调用时所有更新都已完成
    // ========================================================================

    SDL_Rect updateRect = {x, y, w, h};
    int srcPitch = sdl->pitch;
    void *srcPixels = sdl->pixels;

    // 计算像素数据大小并复制（必须在dispatch前完成，因为VNC可能会修改frameBuffer）
    int bytesPerRow = w * 4;  // ARGB8888
    size_t bufferSize = (size_t)bytesPerRow * h;

    // 分配临时缓冲区并复制像素数据
    void *pixelData = malloc(bufferSize);
    if (!pixelData) {
        NSLog(@"%@ ❌ Failed to allocate pixel buffer", VNC_RENDER_LOG_PREFIX);
        return;
    }

    uint8_t *src = (uint8_t *)srcPixels + y * srcPitch + x * 4;
    uint8_t *dst = (uint8_t *)pixelData;
    for (int row = 0; row < h; row++) {
        memcpy(dst, src, bytesPerRow);
        src += srcPitch;
        dst += bytesPerRow;
    }

    // 增加帧更新计数
    atomic_fetch_add(&g_frameUpdateCount, 1);

    // 在主线程更新纹理 - 使用dispatch_sync确保更新完成
    dispatch_sync(VNCGetRenderQueue(), ^{
        if (SDL_UpdateTexture(sdlTexture, &updateRect, pixelData, bytesPerRow) < 0) {
            NSLog(@"%@ ❌ SDL_UpdateTexture failed: %s", VNC_RENDER_LOG_PREFIX, SDL_GetError());
        }
        free(pixelData);

        // 增加完成计数
        atomic_fetch_add(&g_frameUpdatesCompleted, 1);
    });

    // NSLog(@"%@ 📦 Texture updated: rect(%d,%d,%d,%d)", VNC_RENDER_LOG_PREFIX, x, y, w, h);
}

// FinishedFrameBufferUpdate回调 - 在所有矩形更新完成后调用
// 由于GotFrameBufferUpdate使用dispatch_sync，此时所有纹理更新已完成
static inline void VNCRuntimeFinishedFrameBufferUpdate(rfbClient* cl, SDL_Texture* sdlTexture, SDL_Renderer* sdlRenderer, SDL_Window* sdlWindow) {
    if (!sdlTexture || !sdlRenderer || !sdlWindow) {
        return;
    }

    // 获取并重置帧更新计数
    int updateCount = atomic_exchange(&g_frameUpdateCount, 0);
    int completedCount = atomic_exchange(&g_frameUpdatesCompleted, 0);

    // 检查是否有更新
    if (updateCount == 0) {
        // 没有纹理更新，跳过呈现
        return;
    }

    // 验证所有更新都已完成（dispatch_sync保证这一点，这里只是安全检查）
    if (completedCount != updateCount) {
        NSLog(@"%@ ⚠️ Update count mismatch: expected %d, completed %d", VNC_RENDER_LOG_PREFIX, updateCount, completedCount);
    }

    // 获取VNC客户端实例
    ScrcpyVNCClient *vncClient = (__bridge ScrcpyVNCClient*)rfbClientGetClientData(cl, (void*)0x1234);
    BOOL isFirstFrame = vncClient && vncClient.scrcpyStatus <= ScrcpyStatusConnected;

    // 获取窗口和纹理尺寸用于渲染
    int windowWidth, windowHeight;
    SDL_GetWindowSize(sdlWindow, &windowWidth, &windowHeight);

    // SDL3: SDL_QueryTexture is gone; read .w / .h directly off the texture.
    int textureWidth = sdlTexture ? sdlTexture->w : 0;
    int textureHeight = sdlTexture ? sdlTexture->h : 0;

    // SDL3: SDL_RenderGetLogicalSize -> SDL_GetRenderLogicalPresentation
    // returns w/h plus the presentation mode.
    int logicalWidth = 0, logicalHeight = 0;
    SDL_RendererLogicalPresentation logicalMode = SDL_LOGICAL_PRESENTATION_DISABLED;
    SDL_GetRenderLogicalPresentation(sdlRenderer, &logicalWidth, &logicalHeight, &logicalMode);

    int renderWidth = logicalWidth > 0 ? logicalWidth : windowWidth;
    int renderHeight = logicalHeight > 0 ? logicalHeight : windowHeight;

    // 计算缩放和偏移
    float baseScaleX = (float)renderWidth / textureWidth;
    float baseScaleY = (float)renderHeight / textureHeight;
    float baseScale = fminf(baseScaleX, baseScaleY);

    float userZoomScale = vncClient ? vncClient.currentZoomScale : 1.0f;
    float zoomCenterX = vncClient ? vncClient.zoomCenterX : 0.5f;
    float zoomCenterY = vncClient ? vncClient.zoomCenterY : 0.5f;

    float finalScale = baseScale * userZoomScale;
    int scaledWidth = (int)(textureWidth * finalScale);
    int scaledHeight = (int)(textureHeight * finalScale);

    int centerX = (int)(renderWidth * zoomCenterX);
    int centerY = (int)(renderHeight * zoomCenterY);
    int offsetX = centerX - (int)(scaledWidth * zoomCenterX) + (vncClient ? vncClient.viewOffsetX : 0);
    int offsetY = centerY - (int)(scaledHeight * zoomCenterY) + (vncClient ? vncClient.viewOffsetY : 0);

    if (scaledWidth <= renderWidth) {
        offsetX = (renderWidth - scaledWidth) / 2;
    } else {
        if (offsetX > 0) offsetX = 0;
        if (offsetX + scaledWidth < renderWidth) offsetX = renderWidth - scaledWidth;
    }
    if (scaledHeight <= renderHeight) {
        offsetY = (renderHeight - scaledHeight) / 2;
    } else {
        if (offsetY > 0) offsetY = 0;
        if (offsetY + scaledHeight < renderHeight) offsetY = renderHeight - scaledHeight;
    }

    // 计算光标位置（用于边缘跟随检测）
    BOOL shouldDrawCursor = vncClient && cl->appData.useRemoteCursor;
    int cursorScreenX = 0, cursorScreenY = 0;
    float cursorScale = finalScale;

    if (shouldDrawCursor) {
        int remoteMouseX = vncClient.currentMouseX;
        int remoteMouseY = vncClient.currentMouseY;

        // 先计算光标的屏幕位置（用于边缘跟随检测）
        int tempCursorScreenX = offsetX + (remoteMouseX * scaledWidth) / textureWidth;
        int tempCursorScreenY = offsetY + (remoteMouseY * scaledHeight) / textureHeight;

        // 🔄 边缘跟随检测和视图偏移调整
        if (g_mouseMovedThisFrame && vncClient) {
            VNCRuntimeCheckCursorEdgeFollow(vncClient, tempCursorScreenX, tempCursorScreenY,
                                          remoteMouseX, remoteMouseY,
                                          renderWidth, renderHeight, &offsetX, &offsetY,
                                          scaledWidth, scaledHeight, textureWidth, textureHeight, finalScale);

            // 更新VNC客户端的视图偏移量
            vncClient.viewOffsetX = offsetX - (centerX - (int)(scaledWidth * zoomCenterX));
            vncClient.viewOffsetY = offsetY - (centerY - (int)(scaledHeight * zoomCenterY));

            // 重置鼠标移动标记
            g_mouseMovedThisFrame = NO;
        }

        // 使用（可能已调整的）offsetX/Y重新计算光标屏幕位置
        cursorScreenX = offsetX + (remoteMouseX * scaledWidth) / textureWidth;
        cursorScreenY = offsetY + (remoteMouseY * scaledHeight) / textureHeight;

        const int CURSOR_EDGE_MARGIN = 5;
        if (cursorScreenX < CURSOR_EDGE_MARGIN) cursorScreenX = CURSOR_EDGE_MARGIN;
        else if (cursorScreenX > renderWidth - CURSOR_EDGE_MARGIN) cursorScreenX = renderWidth - CURSOR_EDGE_MARGIN;
        if (cursorScreenY < CURSOR_EDGE_MARGIN) cursorScreenY = CURSOR_EDGE_MARGIN;
        else if (cursorScreenY > renderHeight - CURSOR_EDGE_MARGIN) cursorScreenY = renderHeight - CURSOR_EDGE_MARGIN;
    }

    SDL_FRect dstRect = {(float)offsetX, (float)offsetY, (float)scaledWidth, (float)scaledHeight};

    // NSLog(@"%@ 🖼️ FinishedFrameBufferUpdate - presenting frame, dstRect(%d,%d,%d,%d)",
    //       VNC_RENDER_LOG_PREFIX, offsetX, offsetY, scaledWidth, scaledHeight);

    // 在主线程呈现 - SDL_RenderPresent必须在主线程调用
    dispatch_async(VNCGetRenderQueue(), ^{
        // 检查是否需要节流呈现
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime elapsed = now - g_lastPresentTime;

        if (elapsed < kMinPresentInterval && !isFirstFrame) {
            // NSLog(@"%@ ⏳ Throttled: elapsed=%.3fms < min=%.3fms",
            //       VNC_RENDER_LOG_PREFIX, elapsed * 1000, kMinPresentInterval * 1000);
            return;
        }

        int expected = 0;
        if (!atomic_compare_exchange_strong(&g_presentInProgress, &expected, 1)) {
            NSLog(@"%@ ⚠️ Present already in progress, skipping", VNC_RENDER_LOG_PREFIX);
            return;
        }

        // 准备渲染
        SDL_SetRenderDrawColor(sdlRenderer, 0, 0, 0, 255);
        SDL_RenderClear(sdlRenderer);
        SDL_RenderTexture(sdlRenderer, sdlTexture, NULL, &dstRect);

        if (shouldDrawCursor) {
            VNCRuntimeDrawMacOSCursor(sdlRenderer, cursorScreenX, cursorScreenY, cursorScale);
        }

        SDL_RenderPresent(sdlRenderer);
        g_lastPresentTime = CFAbsoluteTimeGetCurrent();
        atomic_store(&g_presentInProgress, 0);

        // NSLog(@"%@ ✅ Frame presented successfully", VNC_RENDER_LOG_PREFIX);

        if (isFirstFrame && vncClient) {
            vncClient.scrcpyStatus = ScrcpyStatusSDLWindowAppeared;
            ScrcpyUpdateStatus(ScrcpyStatusSDLWindowAppeared, "First frame rendered");
        }
    });

    // 请求下一帧更新（传统模式）
    if (vncClient && !vncClient.areContinuousUpdatesEnabled) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [vncClient sendSmartFramebufferUpdateRequest];
        });
    }
}

static inline rfbBool VNCRuntimeHandleCursorPos(rfbClient* cl, int x, int y, int* currentMouseX, int* currentMouseY) {
    NSLog(@"🖱️ [ScrcpyVNCClient] Received cursor position: (%d, %d)", x, y);
    
    // 更新VNC服务器报告的光标位置
    *currentMouseX = x;
    *currentMouseY = y;
    
    NSLog(@"🖱️ [ScrcpyVNCClient] Cursor position updated from server: (%d, %d)", x, y);
    return TRUE;
}

static inline char* VNCRuntimeGetPassword(rfbClient* cl, NSString* password) {
    NSLog(@"🔐 [ScrcpyVNCClient] GetPassword callback invoked");
    
    if (!password || password.length == 0) {
        NSLog(@"❌ [ScrcpyVNCClient] Password is empty for VNC authentication");
        return NULL;
    }
    
    size_t passwordLength = password.length + 1;
    char *passwordCStr = malloc(passwordLength);
    if (!passwordCStr) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to allocate memory for VNC password");
        return NULL;
    }
    
    strncpy(passwordCStr, password.UTF8String, passwordLength - 1);
    passwordCStr[passwordLength - 1] = '\0';
    passwordCStr[strcspn(passwordCStr, "\n")] = '\0';
    
    NSLog(@"🔐 [ScrcpyVNCClient] Password provided for VNC authentication");
    return passwordCStr;
}

static inline rfbCredential* VNCRuntimeGetCredential(rfbClient* cl, int credentialType, NSString* user, NSString* password) {
    NSLog(@"🔐 [ScrcpyVNCClient] GetCredential callback invoked, type: %d", credentialType);
    
    rfbCredential *c = malloc(sizeof(rfbCredential));
    if (!c) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to allocate memory for VNC credential");
        return NULL;
    }
    
    if (credentialType != rfbCredentialTypeUser) {
        NSLog(@"❌ [ScrcpyVNCClient] Unsupported credential type: %d", credentialType);
        free(c);
        return NULL;
    }
    
    // 分配并复制用户名
    c->userCredential.username = malloc(RFB_BUF_SIZE);
    if (!c->userCredential.username) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to allocate memory for VNC username");
        free(c);
        return NULL;
    }
    strncpy(c->userCredential.username, user ? user.UTF8String : "", RFB_BUF_SIZE - 1);
    c->userCredential.username[RFB_BUF_SIZE - 1] = '\0';
    
    // 分配并复制密码
    c->userCredential.password = malloc(RFB_BUF_SIZE);
    if (!c->userCredential.password) {
        NSLog(@"❌ [ScrcpyVNCClient] Failed to allocate memory for VNC password");
        free(c->userCredential.username);
        free(c);
        return NULL;
    }
    strncpy(c->userCredential.password, password ? password.UTF8String : "", RFB_BUF_SIZE - 1);
    c->userCredential.password[RFB_BUF_SIZE - 1] = '\0';

    NSLog(@"🔐 [ScrcpyVNCClient] VNC credentials prepared");

    // 移除尾随换行符
    c->userCredential.username[strcspn(c->userCredential.username, "\n")] = '\0';
    c->userCredential.password[strcspn(c->userCredential.password, "\n")] = '\0';

    return c;
}

// Public interface functions

void VNCRuntimeSetupGotFrameBufferUpdateCallback(rfbClient* client, SDL_Texture* sdlTexture, SDL_Renderer* sdlRenderer, SDL_Window* sdlWindow) {
    // 保存SDL对象用于强制重渲染
    g_savedRenderer = sdlRenderer;
    g_savedTexture = sdlTexture;
    g_savedWindow = sdlWindow;

    GetSet_GotFrameBufferUpdateBlockIMP(client, imp_implementationWithBlock(^void(rfbClient* cl, int x, int y, int w, int h){
        VNCRuntimeGotFrameBufferUpdate(cl, x, y, w, h, sdlTexture, sdlRenderer, sdlWindow);
    }));
}

void VNCRuntimeSetupFinishedFrameBufferUpdateCallback(rfbClient* client, SDL_Texture* sdlTexture, SDL_Renderer* sdlRenderer, SDL_Window* sdlWindow) {
    // 设置FinishedFrameBufferUpdate回调
    client->FinishedFrameBufferUpdate = FinishedFrameBufferUpdateBlock;

    GetSet_FinishedFrameBufferUpdateBlockIMP(client, imp_implementationWithBlock(^void(rfbClient* cl){
        VNCRuntimeFinishedFrameBufferUpdate(cl, sdlTexture, sdlRenderer, sdlWindow);
    }));
}

void VNCRuntimeSetupHandleCursorPosCallback(rfbClient* client, int* currentMouseX, int* currentMouseY) {
    GetSet_HandleCursorPosBlockIMP(client, imp_implementationWithBlock(^rfbBool(rfbClient* cl, int x, int y){
        return VNCRuntimeHandleCursorPos(cl, x, y, currentMouseX, currentMouseY);
    }));
}

void VNCRuntimeSetupGetPasswordCallback(rfbClient* client, NSString* password) {
    GetSet_GetPasswordBlockIMP(client, imp_implementationWithBlock(^char *(rfbClient* cl){
        return VNCRuntimeGetPassword(cl, password);
    }));
}

void VNCRuntimeSetupGetCredentialCallback(rfbClient* client, NSString* user, NSString* password) {
    GetSet_GetCredentialBlockIMP(client, imp_implementationWithBlock(^rfbCredential *(rfbClient* cl, int credentialType){
        return VNCRuntimeGetCredential(cl, credentialType, user, password);
    }));
}

void VNCRuntimeCleanupCallbacks(rfbClient* client) {
    GetSet_GetCredentialBlockIMP(client, nil);
    GetSet_GotFrameBufferUpdateBlockIMP(client, nil);
    GetSet_FinishedFrameBufferUpdateBlockIMP(client, nil);
    GetSet_HandleCursorPosBlockIMP(client, nil);
    GetSet_GetPasswordBlockIMP(client, nil);

    // 清除保存的SDL对象
    g_savedRenderer = NULL;
    g_savedTexture = NULL;
    g_savedWindow = NULL;

    // 重置纹理尺寸
    g_textureWidth = 0;
    g_textureHeight = 0;

    // 重置原子计数器
    atomic_store(&g_frameUpdateCount, 0);
    atomic_store(&g_frameUpdatesCompleted, 0);
    atomic_store(&g_presentInProgress, 0);
}

// 光标尺寸常量定义 - 支持Retina显示
static const int CURSOR_TEXTURE_SIZE = 128;      // 光标纹理尺寸（Retina）
static const int CURSOR_BASE_SIZE = 5;           // 光标基础显示尺寸（8的2/3约等于5）
static const int CURSOR_RADIUS = 12;             // 光标圆点半径（在128x128纹理中）
static const int CURSOR_BORDER_WIDTH = 4;        // 光标白色边框宽度（增加以改善锐度）
static const int CURSOR_MIN_SIZE = 10;            // 光标最小显示尺寸
static const int CURSOR_MAX_SIZE = 10;           // 光标最大显示尺寸


// 全局光标纹理变量
static SDL_Texture* g_cursorTexture = NULL;
static SDL_Renderer* g_cursorRenderer = NULL;



typedef struct {
    SDL_Texture* texture;
    int width, height;
    float alpha;
} CustomCursor;

static CustomCursor* createCustomCursor(SDL_Renderer* renderer) {
    CustomCursor* cursor = malloc(sizeof(CustomCursor));
    if (!cursor) return NULL;
    
    // 创建光标纹理
    // SDL3: explicit RGBA masks are no longer required; pick a known
    // packed format. SDL_CreateSurface takes (w, h, format).
    SDL_Surface* surface = SDL_CreateSurface(CURSOR_TEXTURE_SIZE,
                                             CURSOR_TEXTURE_SIZE,
                                             SDL_PIXELFORMAT_ARGB8888);

    if (!surface) {
        free(cursor);
        return NULL;
    }

    // SDL3: SDL_MapRGBA takes (format_details, palette, r, g, b, a).
    const SDL_PixelFormatDetails *cursorPfd = SDL_GetPixelFormatDetails(surface->format);

    // 清空背景（透明）
    SDL_FillSurfaceRect(surface, NULL, SDL_MapRGBA(cursorPfd, NULL, 0, 0, 0, 0));
    
    Uint32* pixels = (Uint32*)surface->pixels;
    const int size = CURSOR_TEXTURE_SIZE;
    const int centerX = size / 2;  // 中心点 X 坐标
    const int centerY = size / 2;  // 中心点 Y 坐标
    const int radius = CURSOR_RADIUS;
    
    // 绘制高质量抗锯齿圆形光标
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            // 使用子像素采样进行抗锯齿处理
            float totalAlpha = 0.0f;
            float totalWhiteAlpha = 0.0f;
            const int samples = 4; // 2x2子像素采样
            
            for (int sy = 0; sy < samples; sy++) {
                for (int sx = 0; sx < samples; sx++) {
                    // 计算子像素位置
                    float subX = x + (sx + 0.5f) / samples - 0.5f;
                    float subY = y + (sy + 0.5f) / samples - 0.5f;
                    
                    // 计算到圆心的距离
                    float dx = subX - centerX;
                    float dy = subY - centerY;
                    float distance = sqrtf(dx * dx + dy * dy);
                    
                    // 内圆（黑色部分）- 使用平滑过渡
                    float innerRadius = radius - CURSOR_BORDER_WIDTH;
                    if (distance <= innerRadius) {
                        totalAlpha += 1.0f;
                    } else if (distance <= innerRadius + 1.0f) {
                        // 内圆边缘的平滑过渡
                        totalAlpha += (innerRadius + 1.0f - distance);
                    }
                    
                    // 外圆（白色边框）- 使用平滑过渡
                    float outerRadius = radius + CURSOR_BORDER_WIDTH;
                    if (distance >= radius - 0.5f && distance <= outerRadius) {
                        if (distance <= radius + 0.5f) {
                            // 边框内侧的平滑过渡
                            totalWhiteAlpha += 1.0f;
                        } else if (distance <= outerRadius) {
                            // 边框外侧的平滑过渡
                            totalWhiteAlpha += (outerRadius - distance) / CURSOR_BORDER_WIDTH;
                        }
                    }
                }
            }
            
            // 计算最终的alpha值
            totalAlpha /= (samples * samples);
            totalWhiteAlpha /= (samples * samples);
            
            // 应用颜色
            if (totalAlpha > 0.0f) {
                // 黑色圆心
                int alpha = (int)(255 * totalAlpha);
                if (alpha > 255) alpha = 255;
                pixels[y * size + x] = SDL_MapRGBA(cursorPfd, NULL, 0, 0, 0, alpha);
            } else if (totalWhiteAlpha > 0.0f) {
                // 白色边框
                int alpha = (int)(200 * totalWhiteAlpha); // 稍微降低白色边框的不透明度
                if (alpha > 200) alpha = 200;
                pixels[y * size + x] = SDL_MapRGBA(cursorPfd, NULL, 255, 255, 255, alpha);
            }
        }
    }
    
    cursor->texture = SDL_CreateTextureFromSurface(renderer, surface);
    SDL_SetTextureBlendMode(cursor->texture, SDL_BLENDMODE_BLEND);
    
    cursor->width = CURSOR_TEXTURE_SIZE;
    cursor->height = CURSOR_TEXTURE_SIZE;
    cursor->alpha = 1.0f;
    
    SDL_DestroySurface(surface);
    return cursor;
}

static void freeCustomCursor(CustomCursor* cursor) {
    if (cursor) {
        if (cursor->texture) {
            SDL_DestroyTexture(cursor->texture);
        }
        free(cursor);
    }
}

void VNCRuntimeDrawMacOSCursor(SDL_Renderer* renderer, int x, int y, float scale) {
    if (!renderer) return;
    
    // 确保光标纹理已创建
    if (!g_cursorTexture || g_cursorRenderer != renderer) {
        if (g_cursorTexture && g_cursorRenderer != renderer) {
            g_cursorTexture = NULL;
        }
        
        CustomCursor* cursor = createCustomCursor(renderer);
        if (cursor) {
            g_cursorTexture = cursor->texture;
            g_cursorRenderer = renderer;
            // 不释放纹理，只释放结构体
            free(cursor);
        }
    }
    
    if (!g_cursorTexture) return;
    
    // 获取设备缩放因子以支持Retina显示
    float deviceScale = [[UIScreen mainScreen] nativeScale];
    
    // 使用固定光标尺寸，不受内容缩放影响
    // 这样光标在任何缩放级别下都保持相同的视觉大小，便于用户识别和使用
    int cursorSize = (int)(CURSOR_BASE_SIZE * deviceScale); // 只应用设备缩放以支持Retina
    
    // 确保光标尺寸在合理范围内（现在最小和最大值相同，保持固定尺寸）
    if (cursorSize < (int)(CURSOR_MIN_SIZE * deviceScale)) cursorSize = (int)(CURSOR_MIN_SIZE * deviceScale);
    if (cursorSize > (int)(CURSOR_MAX_SIZE * deviceScale)) cursorSize = (int)(CURSOR_MAX_SIZE * deviceScale);
    
    // 设置透明度
    SDL_SetTextureAlphaMod(g_cursorTexture, (Uint8)(255));
    
    // 圆形光标热点在中心位置
    // SDL3 SDL_RenderTexture takes SDL_FRect (floats).
    SDL_FRect destRect = {
        (float)(x - cursorSize / 2),  // 圆心对准实际点击位置
        (float)(y - cursorSize / 2),
        (float)cursorSize,
        (float)cursorSize
    };

    // 使用高质量纹理过滤（但不启用VSync以避免阻塞）
    SDL_SetTextureScaleMode(g_cursorTexture, SDL_SCALEMODE_LINEAR);

    SDL_RenderTexture(renderer, g_cursorTexture, NULL, &destRect);
    
    // 可选：添加调试信息显示当前鼠标位置（仅在调试模式下）
    #ifdef DEBUG_CURSOR
    SDL_SetRenderDrawColor(renderer, 255, 0, 0, 128);
    SDL_Rect debugPoint = {x - 1, y - 1, 2, 2};
    SDL_RenderFillRect(renderer, &debugPoint);
    #endif
}

// 光标边缘跟随逻辑实现 - 支持连续平滑移动并检测移动方向
static void VNCRuntimeCheckCursorEdgeFollow(ScrcpyVNCClient* vncClient, int screenMouseX, int screenMouseY,
                                          int remoteMouseX, int remoteMouseY,
                                          int renderWidth, int renderHeight, int* offsetX, int* offsetY,
                                          int scaledWidth, int scaledHeight, int textureWidth, int textureHeight, float finalScale) {

    // 只有在内容被放大（scaledWidth > renderWidth 或 scaledHeight > renderHeight）时才需要边缘跟随
    if (scaledWidth <= renderWidth && scaledHeight <= renderHeight) {
        // 重置上一帧位置
        g_lastScreenMouseX = screenMouseX;
        g_lastScreenMouseY = screenMouseY;
        g_lastRemoteMouseX = remoteMouseX;
        g_lastRemoteMouseY = remoteMouseY;
        return; // 内容完全可见，无需跟随
    }

    // 🔑 使用远程鼠标坐标计算移动方向（避免viewOffset变化影响）
    int mouseDeltaX = 0;
    int mouseDeltaY = 0;

    if (g_lastRemoteMouseX >= 0 && g_lastRemoteMouseY >= 0) {
        mouseDeltaX = remoteMouseX - g_lastRemoteMouseX;
        mouseDeltaY = remoteMouseY - g_lastRemoteMouseY;
    }
    
    // 详细日志：当前鼠标状态
    NSLog(@"🔍 [EdgeFollow] Mouse position: (%d,%d), last: (%d,%d), delta: (%d,%d)", 
          screenMouseX, screenMouseY, g_lastScreenMouseX, g_lastScreenMouseY, mouseDeltaX, mouseDeltaY);
    NSLog(@"🔍 [EdgeFollow] Screen size: %dx%d, Content size: %dx%d, Offset: (%d,%d)", 
          renderWidth, renderHeight, scaledWidth, scaledHeight, *offsetX, *offsetY);
    
    // 标记是否需要更新视图
    BOOL needsUpdate = NO;
    int newOffsetX = *offsetX;
    int newOffsetY = *offsetY;
    
    // 检查水平边缘跟随 - 连续性移动且考虑移动方向
    if (scaledWidth > renderWidth) {
        // 详细分析左边缘条件
        BOOL leftEdgeInThreshold = (screenMouseX < CURSOR_EDGE_THRESHOLD);
        BOOL leftCanMoveRight = (newOffsetX < 0);
        BOOL leftMovingTowardEdge = (mouseDeltaX <= 0);
        
        NSLog(@"🔍 [EdgeFollow] LEFT conditions: inThreshold=%d (x=%d<%d), canMove=%d (offset=%d<0), movingToward=%d (delta=%d<=0)", 
              leftEdgeInThreshold, screenMouseX, CURSOR_EDGE_THRESHOLD, leftCanMoveRight, newOffsetX, leftMovingTowardEdge, mouseDeltaX);
        
        if (leftEdgeInThreshold && leftCanMoveRight && leftMovingTowardEdge) {
            // 计算距离边缘的比例，越近移动越快
            // 对于负值坐标，使用绝对值计算距离比例
            float edgeDistance = (screenMouseX < 0) ? (float)(-screenMouseX) : (float)(CURSOR_EDGE_THRESHOLD - screenMouseX);
            float edgeRatio = MIN(1.0f, edgeDistance / CURSOR_EDGE_THRESHOLD);
            edgeRatio = powf(edgeRatio, CURSOR_FOLLOW_ACCELERATION); // 应用加速
            
            int moveDistance = (int)(CURSOR_FOLLOW_SPEED * edgeRatio);
            newOffsetX = MIN(0, newOffsetX + moveDistance);
            needsUpdate = YES;
            
            NSLog(@"🔄 [VNCRuntime] ✅ LEFT edge follow triggered: edgeRatio=%.2f, moving view right by %d", 
                  edgeRatio, moveDistance);
        } else {
            NSLog(@"🔍 [EdgeFollow] ❌ LEFT edge follow NOT triggered");
        }
        
        // 详细分析右边缘条件
        BOOL rightEdgeInThreshold = (screenMouseX > (renderWidth - CURSOR_EDGE_THRESHOLD));
        BOOL rightCanMoveLeft = ((newOffsetX + scaledWidth) > renderWidth);
        BOOL rightMovingTowardEdge = (mouseDeltaX >= 0);
        
        NSLog(@"🔍 [EdgeFollow] RIGHT conditions: inThreshold=%d (x=%d>%d), canMove=%d (%d+%d>%d), movingToward=%d (delta=%d>=0)", 
              rightEdgeInThreshold, screenMouseX, (renderWidth - CURSOR_EDGE_THRESHOLD), 
              rightCanMoveLeft, newOffsetX, scaledWidth, renderWidth, rightMovingTowardEdge, mouseDeltaX);
        
        if (rightEdgeInThreshold && rightCanMoveLeft && rightMovingTowardEdge) {
            // 计算距离边缘的比例，越近移动越快
            float edgeRatio = ((float)(screenMouseX - (renderWidth - CURSOR_EDGE_THRESHOLD))) / CURSOR_EDGE_THRESHOLD;
            edgeRatio = powf(edgeRatio, CURSOR_FOLLOW_ACCELERATION); // 应用加速
            
            int moveDistance = (int)(CURSOR_FOLLOW_SPEED * edgeRatio);
            newOffsetX = MAX(renderWidth - scaledWidth, newOffsetX - moveDistance);
            needsUpdate = YES;
            
            NSLog(@"🔄 [VNCRuntime] ✅ RIGHT edge follow triggered: edgeRatio=%.2f, moving view left by %d", 
                  edgeRatio, moveDistance);
        } else {
            NSLog(@"🔍 [EdgeFollow] ❌ RIGHT edge follow NOT triggered");
        }
    }
    
    // 检查垂直边缘跟随 - 连续性移动且考虑移动方向
    if (scaledHeight > renderHeight) {
        // 详细分析上边缘条件
        BOOL topEdgeInThreshold = (screenMouseY < CURSOR_EDGE_THRESHOLD);
        BOOL topCanMoveDown = (newOffsetY < 0);
        BOOL topMovingTowardEdge = (mouseDeltaY <= 0);
        
        NSLog(@"🔍 [EdgeFollow] TOP conditions: inThreshold=%d (y=%d<%d), canMove=%d (offset=%d<0), movingToward=%d (delta=%d<=0)", 
              topEdgeInThreshold, screenMouseY, CURSOR_EDGE_THRESHOLD, topCanMoveDown, newOffsetY, topMovingTowardEdge, mouseDeltaY);
        
        if (topEdgeInThreshold && topCanMoveDown && topMovingTowardEdge) {
            // 计算距离边缘的比例，越近移动越快
            // 对于负值坐标，使用绝对值计算距离比例
            float edgeDistance = (screenMouseY < 0) ? (float)(-screenMouseY) : (float)(CURSOR_EDGE_THRESHOLD - screenMouseY);
            float edgeRatio = MIN(1.0f, edgeDistance / CURSOR_EDGE_THRESHOLD);
            edgeRatio = powf(edgeRatio, CURSOR_FOLLOW_ACCELERATION); // 应用加速
            
            int moveDistance = (int)(CURSOR_FOLLOW_SPEED * edgeRatio);
            newOffsetY = MIN(0, newOffsetY + moveDistance);
            needsUpdate = YES;
            
            NSLog(@"🔄 [VNCRuntime] ✅ TOP edge follow triggered: edgeRatio=%.2f, moving view down by %d", 
                  edgeRatio, moveDistance);
        } else {
            NSLog(@"🔍 [EdgeFollow] ❌ TOP edge follow NOT triggered");
        }
        
        // 详细分析下边缘条件
        BOOL bottomEdgeInThreshold = (screenMouseY > (renderHeight - CURSOR_EDGE_THRESHOLD));
        BOOL bottomCanMoveUp = ((newOffsetY + scaledHeight) > renderHeight);
        BOOL bottomMovingTowardEdge = (mouseDeltaY >= 0);
        
        NSLog(@"🔍 [EdgeFollow] BOTTOM conditions: inThreshold=%d (y=%d>%d), canMove=%d (%d+%d>%d), movingToward=%d (delta=%d>=0)", 
              bottomEdgeInThreshold, screenMouseY, (renderHeight - CURSOR_EDGE_THRESHOLD), 
              bottomCanMoveUp, newOffsetY, scaledHeight, renderHeight, bottomMovingTowardEdge, mouseDeltaY);
        
        if (bottomEdgeInThreshold && bottomCanMoveUp && bottomMovingTowardEdge) {
            // 计算距离边缘的比例，越近移动越快
            float edgeRatio = ((float)(screenMouseY - (renderHeight - CURSOR_EDGE_THRESHOLD))) / CURSOR_EDGE_THRESHOLD;
            edgeRatio = powf(edgeRatio, CURSOR_FOLLOW_ACCELERATION); // 应用加速
            
            int moveDistance = (int)(CURSOR_FOLLOW_SPEED * edgeRatio);
            newOffsetY = MAX(renderHeight - scaledHeight, newOffsetY - moveDistance);
            needsUpdate = YES;
            
            NSLog(@"🔄 [VNCRuntime] ✅ BOTTOM edge follow triggered: edgeRatio=%.2f, moving view up by %d", 
                  edgeRatio, moveDistance);
        } else {
            NSLog(@"🔍 [EdgeFollow] ❌ BOTTOM edge follow NOT triggered");
        }
    }
    
    // 如果需要更新，应用新的偏移量
    if (needsUpdate) {
        *offsetX = newOffsetX;
        *offsetY = newOffsetY;

        NSLog(@"🔄 [VNCRuntime] View offset smoothly updated to (%d, %d) due to cursor edge follow", newOffsetX, newOffsetY);
    }

    // 更新上一帧位置 - 移到函数末尾确保delta计算正确
    g_lastScreenMouseX = screenMouseX;
    g_lastScreenMouseY = screenMouseY;
    g_lastRemoteMouseX = remoteMouseX;
    g_lastRemoteMouseY = remoteMouseY;
}

// 设置鼠标移动标记的函数，供外部调用
void VNCRuntimeSetMouseMoved(void) {
    g_mouseMovedThisFrame = YES;
    g_mouseIsMoving = YES;
    g_mouseStopCounter = 0;  // 重置停止计数器
    g_mouseJustStopped = NO; // 重置刚停止标记（鼠标重新开始移动）
}

// 强制渲染节流 - 光标渲染使用独立的时间戳
static CFAbsoluteTime g_lastCursorRenderTime = 0;
static const CFAbsoluteTime kMinCursorRenderInterval = 1.0 / 120.0;  // 光标渲染最多120fps（更高响应）

// 强制重新渲染当前帧（用于光标位置更新时无VNC更新的情况）
void VNCRuntimeForceRender(ScrcpyVNCClient* vncClient) {
    if (!vncClient || !g_savedRenderer || !g_savedTexture || !g_savedWindow) {
        return;
    }

    // 光标独立节流：使用独立的时间戳，不受VNC帧更新影响
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime elapsed = now - g_lastCursorRenderTime;
    if (elapsed < kMinCursorRenderInterval) {
        return;  // 跳过过于频繁的光标渲染请求
    }
    g_lastCursorRenderTime = now;

    // 在渲染队列中执行（确保主线程）
    dispatch_async(VNCGetRenderQueue(), ^{
        SDL_Renderer* sdlRenderer = g_savedRenderer;
        SDL_Texture* sdlTexture = g_savedTexture;
        SDL_Window* sdlWindow = g_savedWindow;

        if (!sdlRenderer || !sdlTexture || !sdlWindow) {
            return;
        }

        // 获取窗口和纹理尺寸
        int windowWidth, windowHeight;
        SDL_GetWindowSize(sdlWindow, &windowWidth, &windowHeight);

        int textureWidth = sdlTexture ? sdlTexture->w : 0;
        int textureHeight = sdlTexture ? sdlTexture->h : 0;

        // 获取渲染器的逻辑尺寸
        int logicalWidth = 0, logicalHeight = 0;
        SDL_RendererLogicalPresentation logicalMode = SDL_LOGICAL_PRESENTATION_DISABLED;
        SDL_GetRenderLogicalPresentation(sdlRenderer, &logicalWidth, &logicalHeight, &logicalMode);

        int renderWidth = logicalWidth > 0 ? logicalWidth : windowWidth;
        int renderHeight = logicalHeight > 0 ? logicalHeight : windowHeight;

        // 计算缩放
        float baseScaleX = (float)renderWidth / textureWidth;
        float baseScaleY = (float)renderHeight / textureHeight;
        float baseScale = fminf(baseScaleX, baseScaleY);

        float userZoomScale = vncClient.currentZoomScale;
        float zoomCenterX = vncClient.zoomCenterX;
        float zoomCenterY = vncClient.zoomCenterY;

        float finalScale = baseScale * userZoomScale;
        int scaledWidth = (int)(textureWidth * finalScale);
        int scaledHeight = (int)(textureHeight * finalScale);

        // 计算偏移量
        int centerX = (int)(renderWidth * zoomCenterX);
        int centerY = (int)(renderHeight * zoomCenterY);
        int offsetX = centerX - (int)(scaledWidth * zoomCenterX) + vncClient.viewOffsetX;
        int offsetY = centerY - (int)(scaledHeight * zoomCenterY) + vncClient.viewOffsetY;

        // 边界检查
        if (scaledWidth <= renderWidth) {
            offsetX = (renderWidth - scaledWidth) / 2;
        } else {
            if (offsetX > 0) offsetX = 0;
            if (offsetX + scaledWidth < renderWidth) offsetX = renderWidth - scaledWidth;
        }
        if (scaledHeight <= renderHeight) {
            offsetY = (renderHeight - scaledHeight) / 2;
        } else {
            if (offsetY > 0) offsetY = 0;
            if (offsetY + scaledHeight < renderHeight) offsetY = renderHeight - scaledHeight;
        }

        // 计算光标位置（用于边缘跟随检测）
        int remoteMouseX = vncClient.currentMouseX;
        int remoteMouseY = vncClient.currentMouseY;

        // 先计算光标的屏幕位置（用于边缘跟随检测）
        int tempCursorScreenX = offsetX + (remoteMouseX * scaledWidth) / textureWidth;
        int tempCursorScreenY = offsetY + (remoteMouseY * scaledHeight) / textureHeight;

        // 🔄 边缘跟随检测和视图偏移调整
        if (g_mouseMovedThisFrame) {
            VNCRuntimeCheckCursorEdgeFollow(vncClient, tempCursorScreenX, tempCursorScreenY,
                                          remoteMouseX, remoteMouseY,
                                          renderWidth, renderHeight, &offsetX, &offsetY,
                                          scaledWidth, scaledHeight, textureWidth, textureHeight, finalScale);

            // 更新VNC客户端的视图偏移量
            vncClient.viewOffsetX = offsetX - (centerX - (int)(scaledWidth * zoomCenterX));
            vncClient.viewOffsetY = offsetY - (centerY - (int)(scaledHeight * zoomCenterY));

            // 重置鼠标移动标记
            g_mouseMovedThisFrame = NO;
        }

        SDL_FRect dstRect = {(float)offsetX, (float)offsetY, (float)scaledWidth, (float)scaledHeight};

        // 使用（可能已调整的）offsetX/Y重新计算光标屏幕位置
        int cursorScreenX = dstRect.x + (remoteMouseX * scaledWidth) / textureWidth;
        int cursorScreenY = dstRect.y + (remoteMouseY * scaledHeight) / textureHeight;

        // 限制光标在屏幕边缘
        const int CURSOR_EDGE_MARGIN = 5;
        if (cursorScreenX < CURSOR_EDGE_MARGIN) {
            cursorScreenX = CURSOR_EDGE_MARGIN;
        } else if (cursorScreenX > renderWidth - CURSOR_EDGE_MARGIN) {
            cursorScreenX = renderWidth - CURSOR_EDGE_MARGIN;
        }
        if (cursorScreenY < CURSOR_EDGE_MARGIN) {
            cursorScreenY = CURSOR_EDGE_MARGIN;
        } else if (cursorScreenY > renderHeight - CURSOR_EDGE_MARGIN) {
            cursorScreenY = renderHeight - CURSOR_EDGE_MARGIN;
        }

        // 检查是否有正在进行的present（原子操作）
        if (atomic_load(&g_presentInProgress)) {
            return;  // 渲染正在进行，无需独立渲染
        }

        // 检查节流 - 避免过度渲染
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime elapsed = now - g_lastPresentTime;
        if (elapsed < kMinPresentInterval) {
            return;  // 距离上次渲染太近，跳过
        }

        // VNC空闲时，光标独立渲染（使用原子CAS确保只有一个渲染线程）
        int expected = 0;
        if (!atomic_compare_exchange_strong(&g_presentInProgress, &expected, 1)) {
            return;  // 另一个渲染正在进行
        }

        SDL_SetRenderDrawColor(sdlRenderer, 0, 0, 0, 255);
        SDL_RenderClear(sdlRenderer);
        SDL_RenderTexture(sdlRenderer, sdlTexture, NULL, &dstRect);
        VNCRuntimeDrawMacOSCursor(sdlRenderer, cursorScreenX, cursorScreenY, finalScale);
        SDL_RenderPresent(sdlRenderer);

        g_lastPresentTime = CFAbsoluteTimeGetCurrent();
        atomic_store(&g_presentInProgress, 0);
    });
}

// 清理全局光标纹理资源
void VNCRuntimeCleanupGlobalCursorTexture(void) {
    if (g_cursorTexture) {
        SDL_DestroyTexture(g_cursorTexture);
        g_cursorTexture = NULL;
        g_cursorRenderer = NULL;
        NSLog(@"🧹 [VNCRuntime] Global cursor texture cleaned up");
    }
}

#pragma mark - 连续更新消息处理支持

/**
 * 自定义的服务器消息处理函数，用于拦截EndOfContinuousUpdates消息
 */
static rfbBool VNCRuntimeHandleServerMessage(rfbClient* client, rfbServerToClientMsg* message) {
    // 检查是否是EndOfContinuousUpdates消息（类型150）
    if (message->type == 150) {
        NSLog(@"📡 [VNCRuntime] Received EndOfContinuousUpdates message from server");
        
        // 获取VNC客户端实例
        ScrcpyVNCClient *vncClient = (__bridge ScrcpyVNCClient*)rfbClientGetClientData(client, (void*)0x1234);
        if (vncClient) {
            // 在主线程处理连续更新状态
            dispatch_async(dispatch_get_main_queue(), ^{
                [vncClient handleEndOfContinuousUpdates];
            });
        }
        
        return TRUE; // 消息已处理
    }
    
    // 对于其他消息，调用原始处理函数
    // 注意：这里我们需要手动读取和处理消息，因为libvncclient的架构问题
    return TRUE;
}

/**
 * 设置连续更新消息拦截
 */
void VNCRuntimeSetupContinuousUpdatesHook(rfbClient* client) {
    if (!client) return;
    
    // 目前libvncclient不直接支持自定义服务器消息处理
    // 我们需要在HandleRFBServerMessage调用后检查是否有自定义消息
    NSLog(@"✅ [VNCRuntime] Continuous updates hook setup completed");
}

/**
 * 检查并处理可能的连续更新消息
 * 这个函数应该在每次接收到服务器消息后调用
 */
void VNCRuntimeCheckForContinuousUpdatesMessage(rfbClient* client) {
    if (!client) return;
    
    // 获取VNC客户端实例
    ScrcpyVNCClient *vncClient = (__bridge ScrcpyVNCClient*)rfbClientGetClientData(client, (void*)0x1234);
    if (!vncClient) return;
    
    // 这里我们可以添加更复杂的消息检测逻辑
    // 目前先使用简单的状态检查
    
    static BOOL hasCheckedForSupport = NO;
    if (!hasCheckedForSupport && vncClient.connected) {
        hasCheckedForSupport = YES;
        
        // 延迟检查服务器是否支持连续更新
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (vncClient.connected && !vncClient.areContinuousUpdatesSupported) {
                NSLog(@"🔍 [VNCRuntime] Server may not support continuous updates, using traditional mode");
            }
        });
    }
}
