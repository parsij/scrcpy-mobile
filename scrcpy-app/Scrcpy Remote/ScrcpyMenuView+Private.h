//
//  ScrcpyMenuView+Private.h
//  Scrcpy Remote
//
//  Private interface for ScrcpyMenuView categories
//

#import "ScrcpyMenuView.h"
#import <SDL3/SDL.h>
#import <SDL3/SDL_system.h>
#import "ScrcpyActionsBridge.h"

NS_ASSUME_NONNULL_BEGIN

// Logging macro
#define LOG_POSITION(fmt, ...) NSLog(@"[ScrcpyMenuView] " fmt, ##__VA_ARGS__)

// Zoom scale constants
#define kMinZoomScale   1.0
#define kMaxZoomScale   4.0

@interface ScrcpyMenuView ()

// UI Elements
@property (nonatomic, strong) UIView *capsuleView;
@property (nonatomic, strong) UIView *capsuleBackgroundView;
@property (nonatomic, strong) UIImageView *capsuleHandleIcon;
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, strong) UIButton *backButton;
@property (nonatomic, strong) UIButton *homeButton;
@property (nonatomic, strong) UIButton *switchButton;
@property (nonatomic, strong) UIButton *keyboardButton;
@property (nonatomic, strong) UIButton *actionsButton;
@property (nonatomic, strong) UIButton *clipboardSyncButton;
@property (nonatomic, strong) UIButton *disconnectButton;

// State
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) CGPoint positionRatio;
@property (nonatomic, strong, nullable) NSTimer *fadeTimer;
@property (nonatomic, weak, nullable) UIWindow *activeWindow;
@property (nonatomic, assign) ScrcpyDeviceType currentDeviceType;
@property (nonatomic, assign) BOOL isUpdatingButtonLayout;

// VNC Pinch Gesture Properties
@property (nonatomic, assign) CGFloat currentZoomScale;
@property (nonatomic, assign) CGFloat gestureStartZoomScale;
@property (nonatomic, strong, nullable) UIPinchGestureRecognizer *pinchGesture;
@property (nonatomic, assign) CGFloat gestureStartCenterX;
@property (nonatomic, assign) CGFloat gestureStartCenterY;

// VNC Drag Gesture Properties
@property (nonatomic, strong, nullable) UIPanGestureRecognizer *dragGesture;
@property (nonatomic, strong, nullable) UIPanGestureRecognizer *scrollGesture;
@property (nonatomic, assign) CGPoint dragStartLocation;
@property (nonatomic, assign) CGPoint currentDragOffset;
@property (nonatomic, assign) CGPoint totalDragOffset;
@property (nonatomic, assign) BOOL isScrolling;

// VNC Tap Gesture Properties
@property (nonatomic, strong, nullable) UITapGestureRecognizer *vncTapGesture;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *vncTwoFingerTapGesture;

// VNC Touch Event Tracking
@property (nonatomic, assign) NSTimeInterval touchStartTime;
@property (nonatomic, assign) CGPoint touchStartLocation;
@property (nonatomic, assign) BOOL isDragging;

// Actions Popup Properties
@property (nonatomic, strong, nullable) UIView *actionsPopupView;
@property (nonatomic, strong, nullable) UITableView *actionsTableView;
@property (nonatomic, strong, nullable) NSArray<ScrcpyActionData *> *actionsData;
@property (nonatomic, strong, nullable) UITapGestureRecognizer *dismissGestureRecognizer;
@property (nonatomic, strong, nullable) UIView *actionConfirmationView;

// File Transfer Properties
@property (nonatomic, strong, nullable) UIView *fileTransferPopupView;
@property (nonatomic, strong, nullable) UIScrollView *fileTransferScrollView;
@property (nonatomic, strong, nullable) NSMutableArray<NSURL *> *pendingFileURLs;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, UIProgressView *> *fileProgressViews;
@property (nonatomic, strong, nullable) NSMutableDictionary<NSString *, UILabel *> *fileStatusLabels;
@property (nonatomic, assign) BOOL isFileTransferCancelled;
@property (nonatomic, assign) NSInteger currentTransferIndex;
@property (nonatomic, assign) BOOL hasFileTransferError;
@property (nonatomic, strong, nullable) UIButton *fileTransferCloseButton;
@property (nonatomic, strong, nullable) UILabel *fileTransferHeaderLabel;

// Helper Methods
- (UIWindow *)activeWindow;
- (void)updateMenuPosition;
- (void)updateButtonLayout;
- (void)toggleMenuExpansion;

// Fit Device Window Size
- (void)showFitDeviceWindowConfirmation;
- (void)fitDeviceWindowSize;

@end

NS_ASSUME_NONNULL_END
