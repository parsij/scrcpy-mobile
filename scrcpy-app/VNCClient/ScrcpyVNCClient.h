//
//  ScrcpyVNCClient.h
//  VNCClient
//
//  Created by Ethan on 6/28/25.
//

#import <Foundation/Foundation.h>
#import "ScrcpyClientWrapper.h"
#import "ScrcpyCommon.h"
#import "ScrcpyVNCAudioPlayer.h"
#import <SDL3/SDL.h>
#import <rfb/rfbclient.h>
#import <rfb/keysym.h>
#import <stdlib.h>
#import <arpa/inet.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScrcpyVNCClient : NSObject <ScrcpyClientProtocol>

@property (nonatomic, strong) SDLUIKitDelegate *sdlDelegate;
@property (nonatomic, copy) void (^sessionCompletion)(enum ScrcpyStatus, NSString *);
@property (nonatomic, copy) NSDictionary *sessionArguments;

// VNC客户端状态
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign, nullable) rfbClient *rfbClient;
@property (nonatomic, assign) enum ScrcpyStatus scrcpyStatus;

// VNC远程桌面的图像像素大小
@property (nonatomic, assign) CGSize imagePixelsSize;

// SDL渲染对象
@property (nonatomic, assign, nullable) SDL_Renderer *currentRenderer;
@property (nonatomic, assign, nullable) SDL_Texture *currentTexture;

// 鼠标坐标管理
@property (nonatomic, assign) int currentMouseX;
@property (nonatomic, assign) int currentMouseY;

// 拖拽开始时的鼠标位置（用于计算拖拽偏移的起点）
@property (nonatomic, assign) int dragStartMouseX;
@property (nonatomic, assign) int dragStartMouseY;

// 滚动累积值（用于平滑滚动）
@property (nonatomic, assign) CGFloat scrollAccumulatorY;

// 上一次滚动的偏移量（用于计算增量）
@property (nonatomic, assign) CGPoint lastScrollOffset;

// 缩放相关属性
@property (nonatomic, assign) CGFloat currentZoomScale;
@property (nonatomic, assign) CGFloat zoomCenterX;
@property (nonatomic, assign) CGFloat zoomCenterY;
@property (nonatomic, assign) BOOL zoomUpdatePending;

// 视图偏移量（用于边缘跟随）
@property (nonatomic, assign) int viewOffsetX;
@property (nonatomic, assign) int viewOffsetY;

// 渲染参数（用于边缘跟随计算）
@property (nonatomic, assign) int renderWidth;
@property (nonatomic, assign) int renderHeight;
@property (nonatomic, assign) int remoteDesktopWidth;
@property (nonatomic, assign) int remoteDesktopHeight;

// 连续更新状态管理（基于RoyalVNC实现）
@property (nonatomic, assign) BOOL areContinuousUpdatesSupported;  // 服务器是否支持连续更新
@property (nonatomic, assign) BOOL areContinuousUpdatesEnabled;    // 连续更新是否当前启用
@property (nonatomic, assign) BOOL incrementalUpdatesEnabled;      // 增量更新是否启用

// VNC Audio Streaming Player
@property (nonatomic, strong, nullable) ScrcpyVNCAudioPlayer *audioPlayer;

- (UIWindowScene *)currentScene;

/// 启动VNC连接并显示
/// @param arguments 连接参数，包含主机、端口、用户名、密码等信息
/// @param completion 连接完成回调
- (void)startWithArguments:(NSDictionary *)arguments completion:(void (^)(enum ScrcpyStatus, NSString *))completion;


/// 移动远程鼠标到指定位置
/// @param x 目标X坐标
/// @param y 目标Y坐标
- (void)moveMouseToX:(int)x y:(int)y;

/// 发送鼠标点击事件到远程桌面
/// @param x 点击X坐标
/// @param y 点击Y坐标
/// @param isRightClick 是否为右键点击
- (void)sendMouseClickAtX:(int)x y:(int)y isRightClick:(BOOL)isRightClick;

/// 发送鼠标滚动事件到远程桌面
/// @param offset 滚动偏移量
/// @param viewSize 视图尺寸
/// @param zoomScale 缩放倍数
- (void)sendMouseScrollWithOffset:(CGPoint)offset viewSize:(CGSize)viewSize zoomScale:(CGFloat)zoomScale;

/// 应用缩放设置到SDL渲染层
/// @param scale 缩放比例
/// @param centerX 缩放中心X坐标（归一化）
/// @param centerY 缩放中心Y坐标（归一化）
/// @param isFinished 是否为最终缩放
- (void)applyZoomScale:(CGFloat)scale withCenterX:(CGFloat)centerX centerY:(CGFloat)centerY isFinished:(BOOL)isFinished;

/// 发送键盘按键事件到远程桌面
/// @param keyCode 按键码
/// @param isPressed 是否按下（YES为按下，NO为释放）
- (void)sendKeyEvent:(int)keyCode isPressed:(BOOL)isPressed;

/// 发送文本输入到远程桌面
/// @param text 要输入的文本
- (void)sendTextInput:(NSString *)text;

/// 发送启用连续更新消息到VNC服务器
/// @param enable 是否启用连续更新
/// @param x X坐标
/// @param y Y坐标
/// @param width 宽度
/// @param height 高度
- (void)sendEnableContinuousUpdates:(BOOL)enable x:(int)x y:(int)y width:(int)width height:(int)height;

/// 智能发送帧缓冲更新请求（考虑连续更新状态）
- (void)sendSmartFramebufferUpdateRequest;

/// 处理连续更新结束消息
- (void)handleEndOfContinuousUpdates;

/// 执行VNC动作序列
/// @param vncActions 动作数组
/// @param completion 执行完成回调
- (void)executeVNCActions:(NSArray<NSNumber *> *)vncActions completion:(void(^)(BOOL success, NSString *error))completion;

@end

NS_ASSUME_NONNULL_END
