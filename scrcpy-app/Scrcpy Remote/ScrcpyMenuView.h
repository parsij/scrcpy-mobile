#import <UIKit/UIKit.h>
#import <SDL3/SDL.h>

NS_ASSUME_NONNULL_BEGIN

// 设备类型枚举
typedef NS_ENUM(NSInteger, ScrcpyDeviceType) {
    ScrcpyDeviceTypeADB = 0,
    ScrcpyDeviceTypeVNC = 1
};

@protocol ScrcpyMenuViewDelegate <NSObject>

@optional
// 原有的代理方法
- (void)didTapBackButton;
- (void)didTapHomeButton;
- (void)didTapSwitchButton;
- (void)didTapKeyboardButton;
- (void)didTapActionsButton;
- (void)didTapDisconnectButton;

// 新增：缩放相关的代理方法
// VNC缩放代理方法（兼容旧版本）
- (void)didPinchWithScale:(CGFloat)scale;
- (void)didPinchEndWithFinalScale:(CGFloat)finalScale;

// VNC缩放代理方法（包含中心点信息）
- (void)didPinchWithScale:(CGFloat)scale centerX:(CGFloat)centerX centerY:(CGFloat)centerY;
- (void)didPinchEndWithFinalScale:(CGFloat)finalScale centerX:(CGFloat)centerX centerY:(CGFloat)centerY;

// VNC拖拽手势代理方法
- (void)didDragWithState:(NSString *)state location:(CGPoint)location viewSize:(CGSize)viewSize;

// VNC拖拽手势代理方法（包含偏移量信息）
- (void)didDragWithState:(NSString *)state location:(CGPoint)location viewSize:(CGSize)viewSize offset:(CGPoint)offset;

// VNC拖拽渲染Rect控制代理方法（使用归一化偏移量）
- (void)didDragWithNormalizedOffset:(CGPoint)normalizedOffset viewSize:(CGSize)viewSize;
- (void)didDragEndWithNormalizedOffset:(CGPoint)normalizedOffset viewSize:(CGSize)viewSize;

@end

@interface ScrcpyMenuView : UIView <UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>

@property (nonatomic, weak) id<ScrcpyMenuViewDelegate> delegate;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)addToActiveWindow;
- (void)updateLayout;

// 新增：配置设备类型相关的按钮显示
- (void)configureForDeviceType:(ScrcpyDeviceType)deviceType;

// 新增：从字符串创建设备类型的便利方法
+ (ScrcpyDeviceType)deviceTypeFromString:(NSString *)deviceTypeString;

// 新增：VNC缩放相关方法
- (void)addPinchGesture;
- (void)removePinchGesture;

// 新增：VNC拖拽相关方法
- (void)addDragGesture;
- (void)removeDragGesture;
- (void)resetDragOffset;

@end

NS_ASSUME_NONNULL_END 
