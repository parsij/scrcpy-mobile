//
//  ScrcpyMenuView.m
//  Scrcpy Remote
//
//  Core implementation of ScrcpyMenuView
//

#import "ScrcpyMenuView.h"
#import "ScrcpyMenuView+Private.h"
#import "ScrcpyMenuView+VNCGestures.h"
#import "ScrcpyMenuView+Actions.h"
#import "ScrcpyMenuView+FileTransfer.h"
#import "Scrcpy_Remote-Swift.h"
#import "ScrcpyMenuMaskView.h"
#import "ScrcpyConstants.h"
#import <SDL3/SDL_system.h>
#import <SDL3/SDL_syswm.h>
#import <SDL3/SDL_mouse.h>
#import "ScrcpyADBClient.h"
#import "ScrcpyVNCClient.h"

// Capsule View Constants
static const CGFloat kCapsuleWidth = 55.0f;
static const CGFloat kCapsuleHeight = 26.0f;
static const CGFloat kCapsuleCornerRadius = 13.0f;
static const CGFloat kCapsuleHandleIconWidth = 31.0f;
static const CGFloat kCapsuleHandleIconHeight = 20.0f;
static const CGFloat kCapsuleHandleIconX = 12.0f;
static const CGFloat kCapsuleHandleIconY = 3.0f;

// Capsule Alpha Values
static const CGFloat kCapsuleAlphaIdle = 0.3f;
static const CGFloat kCapsuleAlphaNormal = 0.8f;
static const CGFloat kCapsuleAlphaExpanded = 0.8f;

// Menu View Constants
static const CGFloat kMenuHeight = 60.0f;
static const CGFloat kMenuCornerRadius = 30.0f;
static const CGFloat kMenuHorizontalPadding = 5.0f;
static const CGFloat kMenuVerticalSpacing = 10.0f;

// Button Constants
static const CGFloat kButtonWidth = 60.0f;
static const CGFloat kButtonHeight = 60.0f;
static const CGFloat kButtonSpacing = 0.0f;

// Animation Constants
static const CGFloat kAnimationDuration = 0.15f;
static const CGFloat kMenuAnimationDuration = 0.25f;
static const CGFloat kMenuAnimationDelay = 0.0f;
static const CGFloat kMenuAnimationSpringDamping = 0.6f;
static const CGFloat kMenuAnimationSpringVelocity = 0.5f;
static const CGFloat kFadeTimerInterval = 3.0f;

// Position Constants
static const CGFloat kDefaultPositionRatioX = 0.8f;
static const CGFloat kDefaultPositionRatioY = 0.8f;

// Dynamic Island avoidance constants
static const CGFloat kDynamicIslandWidth = 100.0f;

@interface ScrcpyMenuView () <ScrcpyMenuMaskViewDelegate, ScrcpyMenuViewDelegate>

@property (nonatomic, strong) ScrcpyMenuMaskView *maskView;

@end

@implementation ScrcpyMenuView

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _isExpanded = NO;
        _currentDeviceType = ScrcpyDeviceTypeADB;
        _currentZoomScale = 1.0;
        _gestureStartZoomScale = 1.0;
        _dragStartLocation = CGPointZero;
        _currentDragOffset = CGPointZero;
        _totalDragOffset = CGPointZero;

        LOG_POSITION(@"Initializing menu view with frame: (%.1f, %.1f, %.1f, %.1f)",
                     frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);

        self.userInteractionEnabled = YES;

        // Load saved position ratio or use default
        _positionRatio = [self loadPositionRatio];
        LOG_POSITION(@"Loaded position ratio: (%.3f, %.3f)", _positionRatio.x, _positionRatio.y);

        [self setupViews];
        [self setupGestures];
        [self startFadeTimer];

        // Set initial frame size based on capsule dimensions
        self.frame = CGRectMake(0, 0, kCapsuleWidth, kCapsuleHeight);

        // Initialize gesture states
        self.isDragging = NO;
        self.isScrolling = NO;
        self.currentZoomScale = 1.0;
        self.currentDragOffset = CGPointZero;
        self.totalDragOffset = CGPointZero;

        // Register for orientation change notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // Clean up gestures
    [self removePinchGesture];
    [self removeDragGesture];
    [self removeTapGesture];
}

- (void)orientationDidChange:(NSNotification *)notification {
    LOG_POSITION(@"Device orientation changed, updating layout");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateLayout];
    });
}

#pragma mark - Position Management

- (CGPoint)loadPositionRatio {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    CGFloat savedRatioX = [defaults floatForKey:kUserDefaultsPositionRatioX];
    CGFloat savedRatioY = [defaults floatForKey:kUserDefaultsPositionRatioY];

    if (savedRatioX >= -1 && savedRatioX <= 1 && savedRatioY >= -1 && savedRatioY <= 1) {
        if (savedRatioX == 0 && savedRatioY == 0) {
            LOG_POSITION(@"No saved position, using default (%.3f, %.3f)", kDefaultPositionRatioX, kDefaultPositionRatioY);
            return CGPointMake(kDefaultPositionRatioX, kDefaultPositionRatioY);
        }
        LOG_POSITION(@"Using saved position ratio");
        return CGPointMake(savedRatioX, savedRatioY);
    } else {
        LOG_POSITION(@"Invalid saved position, using default (%.3f, %.3f)", kDefaultPositionRatioX, kDefaultPositionRatioY);
        return CGPointMake(kDefaultPositionRatioX, kDefaultPositionRatioY);
    }
}

- (void)savePositionRatio:(CGPoint)ratio {
    LOG_POSITION(@"Saving position ratio: (%.3f, %.3f)", ratio.x, ratio.y);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:ratio.x forKey:kUserDefaultsPositionRatioX];
    [defaults setFloat:ratio.y forKey:kUserDefaultsPositionRatioY];
    [defaults synchronize];
}

- (void)updatePositionFromRatio {
    UIWindow *window = [self activeWindow];
    if (!window) return;

    LOG_POSITION(@"updatePositionFromRatio called - Current ratio: (%.3f, %.3f)",
                 self.positionRatio.x, self.positionRatio.y);

    CGRect screenBounds = window.bounds;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat screenHeight = screenBounds.size.height;

    LOG_POSITION(@"Screen size: %.1f x %.1f", screenWidth, screenHeight);

    // Calculate screen center
    CGFloat screenCenterX = screenWidth / 2.0;
    CGFloat screenCenterY = screenHeight / 2.0;

    // Calculate reachable boundaries
    CGFloat minFrameX = 0;
    CGFloat maxFrameX = screenWidth - self.frame.size.width;
    CGFloat minFrameY = 0;
    CGFloat maxFrameY = screenHeight - self.frame.size.height;

    // Calculate the reachable center positions
    CGFloat minCenterX = minFrameX + self.frame.size.width / 2.0;
    CGFloat maxCenterX = maxFrameX + self.frame.size.width / 2.0;
    CGFloat minCenterY = minFrameY + self.frame.size.height / 2.0;
    CGFloat maxCenterY = maxFrameY + self.frame.size.height / 2.0;

    // Calculate maximum offsets from center
    CGFloat maxOffsetX = MAX(fabs(minCenterX - screenCenterX), fabs(maxCenterX - screenCenterX));
    CGFloat maxOffsetY = MAX(fabs(minCenterY - screenCenterY), fabs(maxCenterY - screenCenterY));

    LOG_POSITION(@"Screen center: (%.1f, %.1f), Max offsets: (%.1f, %.1f)",
                 screenCenterX, screenCenterY, maxOffsetX, maxOffsetY);

    // Calculate capsule center position using center-relative ratio
    CGFloat capsuleCenterX = screenCenterX + (maxOffsetX * self.positionRatio.x);
    CGFloat capsuleCenterY = screenCenterY + (maxOffsetY * self.positionRatio.y);

    LOG_POSITION(@"Target capsule center: (%.1f, %.1f)", capsuleCenterX, capsuleCenterY);

    // Convert center position to top-left corner position
    CGFloat x = capsuleCenterX - self.frame.size.width / 2.0;
    CGFloat y = capsuleCenterY - self.frame.size.height / 2.0;

    // Ensure position is within screen bounds
    CGFloat originalX = x, originalY = y;
    x = MAX(0, MIN(screenWidth - self.frame.size.width, x));
    y = MAX(0, MIN(screenHeight - self.frame.size.height, y));

    if (originalX != x || originalY != y) {
        LOG_POSITION(@"Position was clamped from (%.1f, %.1f) to (%.1f, %.1f)", originalX, originalY, x, y);
    }

    LOG_POSITION(@"Final position: (%.1f, %.1f)", x, y);

    // Update frame
    self.frame = CGRectMake(x, y, self.frame.size.width, self.frame.size.height);

    // Check for Dynamic Island overlap and adjust if necessary
    if ([self doesCapsuleOverlapDynamicIsland:window]) {
        LOG_POSITION(@"Position overlaps with Dynamic Island, adjusting...");
        CGPoint adjustedPosition = [self adjustPositionToAvoidDynamicIsland:window];
        self.frame = CGRectMake(adjustedPosition.x, adjustedPosition.y, self.frame.size.width, self.frame.size.height);
        LOG_POSITION(@"Position adjusted to: (%.1f, %.1f)", adjustedPosition.x, adjustedPosition.y);
    }
}

- (void)updateRatioFromPosition {
    UIWindow *window = [self activeWindow];
    if (!window) return;

    LOG_POSITION(@"updateRatioFromPosition called - Current frame: (%.1f, %.1f, %.1f, %.1f)",
                 self.frame.origin.x, self.frame.origin.y, self.frame.size.width, self.frame.size.height);

    CGRect screenBounds = window.bounds;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat screenHeight = screenBounds.size.height;

    // Calculate screen center
    CGFloat screenCenterX = screenWidth / 2.0;
    CGFloat screenCenterY = screenHeight / 2.0;

    // Calculate current capsule center
    CGFloat capsuleCenterX = self.frame.origin.x + self.frame.size.width / 2.0;
    CGFloat capsuleCenterY = self.frame.origin.y + self.frame.size.height / 2.0;

    // Calculate reachable boundaries
    CGFloat minFrameX = 0;
    CGFloat maxFrameX = screenWidth - self.frame.size.width;
    CGFloat minFrameY = 0;
    CGFloat maxFrameY = screenHeight - self.frame.size.height;

    // Calculate the reachable center positions
    CGFloat minCenterX = minFrameX + self.frame.size.width / 2.0;
    CGFloat maxCenterX = maxFrameX + self.frame.size.width / 2.0;
    CGFloat minCenterY = minFrameY + self.frame.size.height / 2.0;
    CGFloat maxCenterY = maxFrameY + self.frame.size.height / 2.0;

    // Calculate maximum offsets from center
    CGFloat maxOffsetX = MAX(fabs(minCenterX - screenCenterX), fabs(maxCenterX - screenCenterX));
    CGFloat maxOffsetY = MAX(fabs(minCenterY - screenCenterY), fabs(maxCenterY - screenCenterY));

    LOG_POSITION(@"Screen center: (%.1f, %.1f), Capsule center: (%.1f, %.1f)", screenCenterX, screenCenterY, capsuleCenterX, capsuleCenterY);
    LOG_POSITION(@"Reachable center range - X: [%.1f, %.1f], Y: [%.1f, %.1f]", minCenterX, maxCenterX, minCenterY, maxCenterY);
    LOG_POSITION(@"Max offsets: (%.1f, %.1f)", maxOffsetX, maxOffsetY);

    // Calculate center-relative ratio
    CGFloat ratioX = 0;
    CGFloat ratioY = 0;

    if (maxOffsetX > 0) {
        ratioX = (capsuleCenterX - screenCenterX) / maxOffsetX;
        ratioX = MAX(-1, MIN(1, ratioX));
    }

    if (maxOffsetY > 0) {
        ratioY = (capsuleCenterY - screenCenterY) / maxOffsetY;
        ratioY = MAX(-1, MIN(1, ratioY));
    }

    LOG_POSITION(@"Calculated center-relative ratio: (%.3f, %.3f)", ratioX, ratioY);
    LOG_POSITION(@"Previous ratio was: (%.3f, %.3f)", self.positionRatio.x, self.positionRatio.y);

    // Store the center-relative ratio
    self.positionRatio = CGPointMake(ratioX, ratioY);
    [self savePositionRatio:self.positionRatio];

    LOG_POSITION(@"Stored new center-relative ratio: (%.3f, %.3f)", ratioX, ratioY);
}

#pragma mark - Setup Views

- (void)setupViews {
    // Capsule view (container)
    self.capsuleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kCapsuleWidth, kCapsuleHeight)];
    self.capsuleView.clipsToBounds = YES;

    // Capsule background view
    self.capsuleBackgroundView = [[UIView alloc] initWithFrame:self.capsuleView.bounds];
    self.capsuleBackgroundView.layer.cornerRadius = kCapsuleCornerRadius;
    self.capsuleBackgroundView.clipsToBounds = YES;

    // Gradient layer for capsule background
    CAGradientLayer *gradientLayer = [CAGradientLayer layer];
    gradientLayer.frame = self.capsuleBackgroundView.bounds;
    gradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.85].CGColor,
        (id)[UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9].CGColor
    ];
    gradientLayer.startPoint = CGPointMake(0, 0);
    gradientLayer.endPoint = CGPointMake(1, 1);
    [self.capsuleBackgroundView.layer insertSublayer:gradientLayer atIndex:0];

    // Add handle icon to the capsule
    self.capsuleHandleIcon = [[UIImageView alloc] initWithFrame:CGRectMake(kCapsuleHandleIconX, kCapsuleHandleIconY, kCapsuleHandleIconWidth, kCapsuleHandleIconHeight)];
    self.capsuleHandleIcon.image = [UIImage systemImageNamed:kIconCapsuleHandle];
    self.capsuleHandleIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:1.0];
    self.capsuleHandleIcon.contentMode = UIViewContentModeScaleAspectFit;

    // Add subviews to capsule view
    [self.capsuleView addSubview:self.capsuleBackgroundView];
    [self.capsuleView addSubview:self.capsuleHandleIcon];
    [self addSubview:self.capsuleView];

    // Menu view (expanded state)
    UIWindow *window = [self activeWindow];
    self.activeWindow = window;

    CGFloat initialMenuWidth = 6 * kButtonWidth + 5 * kButtonSpacing + kMenuHorizontalPadding * 2;
    CGFloat maxAvailableWidth = window.bounds.size.width - (kMenuHorizontalPadding * 2);
    initialMenuWidth = MIN(initialMenuWidth, maxAvailableWidth);

    self.menuView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, initialMenuWidth, kMenuHeight)];
    self.menuView.layer.cornerRadius = kMenuCornerRadius;
    self.menuView.clipsToBounds = YES;
    self.menuView.alpha = 0;
    self.menuView.hidden = YES;

    // Gradient layer for menu
    CAGradientLayer *menuGradientLayer = [CAGradientLayer layer];
    menuGradientLayer.frame = CGRectMake(0, 0, initialMenuWidth, kMenuHeight);
    menuGradientLayer.colors = @[
        (id)[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.85].CGColor,
        (id)[UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.9].CGColor
    ];
    menuGradientLayer.startPoint = CGPointMake(0, 0);
    menuGradientLayer.endPoint = CGPointMake(1, 0);
    [self.menuView.layer insertSublayer:menuGradientLayer atIndex:0];
    self.menuView.layer.masksToBounds = YES;

    // Create buttons with temporary positions
    CGRect tempButtonFrame = CGRectMake(0, 0, kButtonWidth, kButtonHeight);

    // Back button
    self.backButton = [self createButtonWithIcon:kIconBackButton position:tempButtonFrame];
    [self.menuView addSubview:self.backButton];

    // Home button
    self.homeButton = [self createButtonWithIcon:kIconHomeButton position:tempButtonFrame];
    [self.menuView addSubview:self.homeButton];

    // Switch button
    self.switchButton = [self createButtonWithIcon:kIconSwitchButton position:tempButtonFrame];
    [self.menuView addSubview:self.switchButton];

    // Keyboard button
    self.keyboardButton = [self createButtonWithIcon:kIconKeyboardButton position:tempButtonFrame];
    [self.menuView addSubview:self.keyboardButton];

    // Actions button
    self.actionsButton = [self createButtonWithIcon:kIconActionsButton position:tempButtonFrame];

    // Remove default button event handlers for Actions button
    [self.actionsButton removeTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [self.actionsButton removeTarget:self action:@selector(buttonTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];
    [self.actionsButton removeTarget:self action:@selector(buttonTouchUpOutside:) forControlEvents:UIControlEventTouchUpOutside];
    [self.actionsButton removeTarget:self action:@selector(buttonTouchCancel:) forControlEvents:UIControlEventTouchCancel];

    // Add TapGesture to Actions button
    UITapGestureRecognizer *actionsTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(actionsButtonTappedViaGesture:)];
    actionsTapGesture.numberOfTapsRequired = 1;
    actionsTapGesture.cancelsTouchesInView = YES;
    [self.actionsButton addGestureRecognizer:actionsTapGesture];
    NSLog(@"🎯 [ScrcpyMenuView] Added TapGesture to Actions button");

    [self.menuView addSubview:self.actionsButton];

    // Clipboard Sync button (VNC only)
    self.clipboardSyncButton = [self createButtonWithIcon:kIconClipboardSyncButton position:tempButtonFrame];
    [self.menuView addSubview:self.clipboardSyncButton];

    // Disconnect button
    self.disconnectButton = [self createButtonWithIcon:kIconDisconnectButton position:tempButtonFrame];
    [self.menuView addSubview:self.disconnectButton];
}

- (UIButton *)createButtonWithIcon:(NSString *)iconName position:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;

    UIImage *icon = [UIImage systemImageNamed:iconName];
    [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.exclusiveTouch = YES;

    [button addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(buttonTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(buttonTouchUpOutside:) forControlEvents:UIControlEventTouchUpOutside];
    [button addTarget:self action:@selector(buttonTouchCancel:) forControlEvents:UIControlEventTouchCancel];

    button.accessibilityIdentifier = iconName;

    return button;
}

#pragma mark - Setup Gestures

- (void)setupGestures {
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.cancelsTouchesInView = YES;
    tapGesture.delaysTouchesEnded = YES;
    [self.capsuleView addGestureRecognizer:tapGesture];

    UIPanGestureRecognizer *panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    panGesture.cancelsTouchesInView = YES;
    panGesture.delaysTouchesEnded = YES;
    [self.capsuleView addGestureRecognizer:panGesture];

    UITapGestureRecognizer *dismissTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDismissTap:)];
    dismissTapGesture.cancelsTouchesInView = YES;
    [[self activeWindow] addGestureRecognizer:dismissTapGesture];
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    [self toggleMenuExpansion];
}

- (void)handleDismissTap:(UITapGestureRecognizer *)gesture {
    if (self.isExpanded) {
        CGPoint location = [gesture locationInView:self.window];
        if (![self.menuView pointInside:[self.menuView convertPoint:location fromView:self] withEvent:nil] &&
            ![self.capsuleView pointInside:[self.capsuleView convertPoint:location fromView:self] withEvent:nil]) {
            SDL_StopTextInput(SDL_GetKeyboardFocus());
            [self toggleMenuExpansion];
        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    self.capsuleBackgroundView.alpha = kCapsuleAlphaNormal;

    UIView *referenceView = self.superview;
    if (!referenceView) {
        referenceView = [self activeWindow];
    }

    CGPoint translation = [gesture translationInView:referenceView];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        LOG_POSITION(@"Pan gesture began at position: (%.1f, %.1f)", self.frame.origin.x, self.frame.origin.y);
        LOG_POSITION(@"Current ratio: (%.3f, %.3f)", self.positionRatio.x, self.positionRatio.y);
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGFloat newX = self.frame.origin.x + translation.x;
        CGFloat newY = self.frame.origin.y + translation.y;

        self.frame = CGRectMake(newX, newY, self.frame.size.width, self.frame.size.height);
        [gesture setTranslation:CGPointZero inView:referenceView];

        if (self.isExpanded) {
            [self updateMenuPosition];
        }

        LOG_POSITION(@"Dragging to position: (%.1f, %.1f)", newX, newY);
    } else if (gesture.state == UIGestureRecognizerStateEnded) {
        LOG_POSITION(@"Pan gesture ended, saving position");

        UIWindow *window = [self activeWindow];
        if (window && [self doesCapsuleOverlapDynamicIsland:window]) {
            LOG_POSITION(@"Dragged position overlaps with Dynamic Island, adjusting...");
            CGPoint adjustedPosition = [self adjustPositionToAvoidDynamicIsland:window];

            [UIView animateWithDuration:0.3 animations:^{
                self.frame = CGRectMake(adjustedPosition.x, adjustedPosition.y, self.frame.size.width, self.frame.size.height);
            }];

            LOG_POSITION(@"Position adjusted to: (%.1f, %.1f)", adjustedPosition.x, adjustedPosition.y);
        }

        [self updateRatioFromPosition];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isExpanded) {
                [UIView animateWithDuration:0.15 animations:^{
                    self.capsuleBackgroundView.alpha = kCapsuleAlphaIdle;
                }];
            }
        });
    }
}

#pragma mark - Menu Expansion

- (void)toggleMenuExpansion {
    if (self.isExpanded) {
        [UIView animateWithDuration:kAnimationDuration animations:^{
            self.menuView.alpha = 0;
            self.menuView.transform = CGAffineTransformMakeScale(0.5, 0.5);
            self.capsuleBackgroundView.alpha = kCapsuleAlphaIdle;
        } completion:^(BOOL finished) {
            self.menuView.hidden = YES;
            self.menuView.transform = CGAffineTransformIdentity;
            [self.menuView removeFromSuperview];
        }];

        [self.maskView hide];
    } else {
        [self updateMenuPosition];
        [self updateButtonLayout];
        self.menuView.hidden = NO;
        self.menuView.alpha = 0;
        self.menuView.transform = CGAffineTransformMakeScale(0.5, 0.5);

        if (!self.maskView) {
            UIWindow *window = [self activeWindow];
            if (window) {
                self.maskView = [[ScrcpyMenuMaskView alloc] initWithFrame:window.bounds];
                self.maskView.delegate = self;
            }
        }

        UIWindow *window = [self activeWindow];
        if (window) {
            [self.maskView showInView:window];
            [window addSubview:self.menuView];
        }

        [UIView animateWithDuration:kMenuAnimationDuration
                              delay:kMenuAnimationDelay
             usingSpringWithDamping:kMenuAnimationSpringDamping
              initialSpringVelocity:kMenuAnimationSpringVelocity
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.menuView.alpha = 1.0;
            self.menuView.transform = CGAffineTransformIdentity;
            self.capsuleBackgroundView.alpha = kCapsuleAlphaExpanded;
        } completion:nil];
    }

    self.isExpanded = !self.isExpanded;
}

- (void)updateMenuPosition {
    UIWindow *window = [self activeWindow];
    if (!window) return;

    CGRect screenBounds = window.bounds;

    NSInteger visibleButtonCount = [self visibleButtonCount];
    CGFloat totalButtonsWidth = visibleButtonCount * kButtonWidth + (visibleButtonCount - 1) * kButtonSpacing;
    CGFloat menuWidth = totalButtonsWidth + kMenuHorizontalPadding * 2;

    CGFloat maxMenuWidth = 400.0f;
    CGFloat availableWidth = screenBounds.size.width - (kMenuHorizontalPadding * 2);
    menuWidth = MIN(MIN(maxMenuWidth, availableWidth), menuWidth);

    CGFloat menuHeight = self.menuView.frame.size.height;

    CGRect capsuleFrameInWindow = [self.capsuleView convertRect:self.capsuleView.bounds toView:window];

    CGFloat spaceAbove = capsuleFrameInWindow.origin.y;
    CGFloat spaceBelow = screenBounds.size.height - (capsuleFrameInWindow.origin.y + capsuleFrameInWindow.size.height);

    CGFloat menuY;
    BOOL showAbove = (spaceAbove > spaceBelow) && (spaceAbove >= menuHeight + kMenuVerticalSpacing * 2);

    if (showAbove) {
        menuY = capsuleFrameInWindow.origin.y - menuHeight - kMenuVerticalSpacing;
    } else {
        menuY = capsuleFrameInWindow.origin.y + capsuleFrameInWindow.size.height + kMenuVerticalSpacing;
    }

    menuY = MAX(kMenuHorizontalPadding,
                MIN(screenBounds.size.height - menuHeight - kMenuHorizontalPadding, menuY));

    CGFloat menuX;
    CGFloat screenCenterX = screenBounds.size.width / 2.0f;
    CGFloat capsuleCenterX = CGRectGetMidX(capsuleFrameInWindow);

    if (menuWidth >= maxMenuWidth) {
        if (capsuleCenterX < screenCenterX) {
            menuX = capsuleFrameInWindow.origin.x;
        } else {
            menuX = capsuleFrameInWindow.origin.x + capsuleFrameInWindow.size.width - menuWidth;
        }
    } else {
        menuX = (screenBounds.size.width - menuWidth) / 2.0f;
    }

    menuX = MAX(kMenuHorizontalPadding,
                MIN(screenBounds.size.width - menuWidth - kMenuHorizontalPadding, menuX));

    CGRect dynamicIslandRect = [self getDynamicIslandRect:window];
    if (dynamicIslandRect.size.height > 0) {
        CGRect proposedMenuRect = CGRectMake(menuX, menuY, menuWidth, menuHeight);

        if (CGRectIntersectsRect(proposedMenuRect, dynamicIslandRect)) {
            LOG_POSITION(@"Menu would overlap with Dynamic Island, adjusting position");

            CGFloat dynamicIslandBottom = dynamicIslandRect.origin.y + dynamicIslandRect.size.height;
            menuY = MAX(menuY, dynamicIslandBottom + kMenuVerticalSpacing);
            menuY = MIN(menuY, screenBounds.size.height - menuHeight - kMenuHorizontalPadding);

            LOG_POSITION(@"Menu position adjusted to avoid Dynamic Island: Y = %.1f", menuY);
        }
    }

    self.menuView.frame = CGRectMake(menuX, menuY, menuWidth, menuHeight);

    if (self.menuView.layer.sublayers.count > 0 &&
        [self.menuView.layer.sublayers[0] isKindOfClass:[CAGradientLayer class]]) {
        ((CAGradientLayer *)self.menuView.layer.sublayers[0]).frame = self.menuView.bounds;
    }

    LOG_POSITION(@"🔧 updateMenuPosition completed, menu frame: (%.2f, %.2f, %.2f, %.2f)",
                 self.menuView.frame.origin.x, self.menuView.frame.origin.y,
                 self.menuView.frame.size.width, self.menuView.frame.size.height);

    if (!self.isUpdatingButtonLayout) {
        [self updateButtonLayout];
    }
}

#pragma mark - Fade Timer

- (void)startFadeTimer {
    [self.fadeTimer invalidate];
    self.fadeTimer = [NSTimer scheduledTimerWithTimeInterval:kFadeTimerInterval target:self selector:@selector(fadeCapsule) userInfo:nil repeats:NO];
}

- (void)fadeCapsule {
    if (!self.isExpanded) {
        [UIView animateWithDuration:kAnimationDuration animations:^{
            self.capsuleBackgroundView.alpha = kCapsuleAlphaIdle;
        }];
    }
}

#pragma mark - Button Actions

- (void)backButtonTapped:(UIButton *)sender {
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    if ([self.delegate respondsToSelector:@selector(didTapBackButton)]) {
        [self.delegate didTapBackButton];
    }
}

- (void)homeButtonTapped:(UIButton *)sender {
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    if ([self.delegate respondsToSelector:@selector(didTapHomeButton)]) {
        [self.delegate didTapHomeButton];
    }
}

- (void)switchButtonTapped:(UIButton *)sender {
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    if ([self.delegate respondsToSelector:@selector(didTapSwitchButton)]) {
        [self.delegate didTapSwitchButton];
    }
}

- (void)keyboardButtonTapped:(UIButton *)sender {
    if ([self.delegate respondsToSelector:@selector(didTapKeyboardButton)]) {
        [self.delegate didTapKeyboardButton];
    }
    [self toggleMenuExpansion];
}

- (void)actionsButtonTapped:(UIButton *)sender {
    NSLog(@"🚀 [ScrcpyMenuView] Actions button tapped");
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    [self showActionsMenu];
}

- (void)actionsButtonTappedViaGesture:(UITapGestureRecognizer *)gesture {
    NSLog(@"🎯🎯🎯 [ScrcpyMenuView] actionsButtonTappedViaGesture called - GESTURE WORKING!");

    UIView *targetView = gesture.view;
    [UIView animateWithDuration:0.1 animations:^{
        targetView.alpha = 0.5;
        targetView.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            targetView.alpha = 1.0;
            targetView.transform = CGAffineTransformIdentity;
        }];
    }];

    SDL_StopTextInput(SDL_GetKeyboardFocus());

    NSLog(@"🎯🎯🎯 [ScrcpyMenuView] About to call showActionsMenu via gesture");
    [self showActionsMenu];
}

- (void)disconnectButtonTapped:(UIButton *)sender {
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    if ([self.delegate respondsToSelector:@selector(didTapDisconnectButton)]) {
        [self.delegate didTapDisconnectButton];
    }
    [self toggleMenuExpansion];
}

#pragma mark - ScrcpyMenuMaskViewDelegate

- (void)didTapMenuMask {
    if (self.isExpanded) {
        [self toggleMenuExpansion];
    }
}

#pragma mark - Hit Testing

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || self.hidden || self.alpha <= 0.01) {
        return nil;
    }

    if (CGRectContainsPoint(self.capsuleView.frame, point)) {
        return self.capsuleView;
    }

    if (self.isExpanded && !self.menuView.hidden && self.menuView.superview) {
        CGPoint menuPoint = [self convertPoint:point toView:self.menuView];
        if ([self.menuView pointInside:menuPoint withEvent:event]) {
            return [self.menuView hitTest:menuPoint withEvent:event];
        }
    }

    if (self.currentDeviceType == ScrcpyDeviceTypeVNC) {
        return self;
    }

    return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(self.capsuleView.frame, point)) {
        return YES;
    }

    if (self.isExpanded && !self.menuView.hidden && self.menuView.superview) {
        CGPoint menuPoint = [self convertPoint:point toView:self.menuView];
        if ([self.menuView pointInside:menuPoint withEvent:event]) {
            return YES;
        }
    }

    if (self.currentDeviceType == ScrcpyDeviceTypeVNC) {
        return YES;
    }

    return NO;
}

#pragma mark - Window Helper

- (UIWindow *)activeWindow {
    SDL_Window *window = SDL_GetMouseFocus();
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (SDL_GetWindowWMInfo(window, &info)) {
        UIWindow *uiWindow = info.info.uikit.window;
        return uiWindow;
    }
    return [UIApplication sharedApplication].keyWindow;
}

#pragma mark - Public Methods

- (void)addToActiveWindow {
    UIWindow *window = [self activeWindow];
    if (!window) return;

    LOG_POSITION(@"addToActiveWindow called");

    [self updateLayout];

    self.userInteractionEnabled = YES;
    self.capsuleView.userInteractionEnabled = YES;
    self.menuView.userInteractionEnabled = YES;

    for (UIView *subview in self.menuView.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)subview;
            button.exclusiveTouch = YES;
        }
    }

    self.maskView = [[ScrcpyMenuMaskView alloc] initWithFrame:window.bounds];
    self.maskView.delegate = self;

    self.capsuleBackgroundView.alpha = kCapsuleAlphaIdle;

    [window addSubview:self];
}

- (void)updateLayout {
    UIWindow *window = [self activeWindow];
    if (!window) return;

    LOG_POSITION(@"updateLayout called");

    [self updatePositionFromRatio];

    if (self.isExpanded) {
        [self updateMenuPosition];
    }
}

#pragma mark - Device Type Configuration

- (NSInteger)visibleButtonCount {
    NSInteger count = 0;
    if (!self.backButton.hidden) count++;
    if (!self.homeButton.hidden) count++;
    if (!self.switchButton.hidden) count++;
    if (!self.keyboardButton.hidden) count++;
    if (!self.actionsButton.hidden) count++;
    if (!self.clipboardSyncButton.hidden) count++;
    if (!self.disconnectButton.hidden) count++;
    return count;
}

+ (ScrcpyDeviceType)deviceTypeFromString:(NSString *)deviceTypeString {
    if ([deviceTypeString.lowercaseString isEqualToString:kDeviceTypeVNC]) {
        return ScrcpyDeviceTypeVNC;
    } else if ([deviceTypeString.lowercaseString isEqualToString:kDeviceTypeADB]) {
        return ScrcpyDeviceTypeADB;
    } else {
        return ScrcpyDeviceTypeADB;
    }
}

- (void)configureForDeviceType:(ScrcpyDeviceType)deviceType {
    self.currentDeviceType = deviceType;

    if (deviceType == ScrcpyDeviceTypeADB) {
        self.backButton.hidden = NO;
        self.homeButton.hidden = NO;
        self.switchButton.hidden = NO;
        self.keyboardButton.hidden = NO;
        self.actionsButton.hidden = NO;
        self.clipboardSyncButton.hidden = YES;
        self.disconnectButton.hidden = NO;

        [self removePinchGesture];
        [self removeDragGesture];
        [self removeTapGesture];

        LOG_POSITION(@"Configured menu for ADB device - all buttons visible");
    } else if (deviceType == ScrcpyDeviceTypeVNC) {
        self.backButton.hidden = YES;
        self.homeButton.hidden = YES;
        self.switchButton.hidden = YES;
        self.keyboardButton.hidden = NO;
        self.actionsButton.hidden = NO;
        self.clipboardSyncButton.hidden = NO;
        self.disconnectButton.hidden = NO;

        LOG_POSITION(@"🐆 [ScrcpyMenuView] Scheduling VNC gestures setup with 0.3s delay");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LOG_POSITION(@"🐆 [ScrcpyMenuView] Adding VNC gestures now");
            [self addPinchGesture];
            [self addDragGesture];
            [self addTapGesture];
            [self setupGesturePriorities];
            LOG_POSITION(@"🐆 [ScrcpyMenuView] VNC gestures setup completed");
        });

        LOG_POSITION(@"Configured menu for VNC device - limited buttons visible and pinch gesture enabled");
    }

    [self updateButtonLayout];
}

- (NSArray<UIButton *> *)getVisibleButtons {
    NSMutableArray *visibleButtons = [NSMutableArray array];

    if (!self.backButton.hidden) [visibleButtons addObject:self.backButton];
    if (!self.homeButton.hidden) [visibleButtons addObject:self.homeButton];
    if (!self.switchButton.hidden) [visibleButtons addObject:self.switchButton];
    if (!self.keyboardButton.hidden) [visibleButtons addObject:self.keyboardButton];
    if (!self.actionsButton.hidden) [visibleButtons addObject:self.actionsButton];
    if (!self.clipboardSyncButton.hidden) [visibleButtons addObject:self.clipboardSyncButton];
    if (!self.disconnectButton.hidden) [visibleButtons addObject:self.disconnectButton];

    return [visibleButtons copy];
}

- (void)updateButtonLayout {
    if (!self.menuView) return;

    if (self.isUpdatingButtonLayout) {
        LOG_POSITION(@"🔧 updateButtonLayout skipped - already updating");
        return;
    }
    self.isUpdatingButtonLayout = YES;

    NSArray<UIButton *> *visibleButtons = [self getVisibleButtons];

    if (visibleButtons.count == 0) {
        LOG_POSITION(@"No visible buttons to layout");
        self.isUpdatingButtonLayout = NO;
        return;
    }

    LOG_POSITION(@"🔧 Starting updateButtonLayout - Device type: %ld", (long)self.currentDeviceType);
    LOG_POSITION(@"🔧 Visible buttons count: %ld", (long)visibleButtons.count);

    CGFloat buttonWidth = kButtonWidth;
    CGFloat buttonHeight = kButtonHeight;
    CGFloat spacing = kButtonSpacing;

    CGFloat totalButtonsWidth = visibleButtons.count * buttonWidth + (visibleButtons.count - 1) * spacing;
    CGFloat idealMenuWidth = totalButtonsWidth + kMenuHorizontalPadding * 2;

    CGRect currentFrame = self.menuView.frame;
    CGFloat menuHeight = currentFrame.size.height;

    self.menuView.frame = CGRectMake(currentFrame.origin.x, currentFrame.origin.y, idealMenuWidth, menuHeight);

    CGFloat containerStartX = kMenuHorizontalPadding;
    CGFloat containerY = (menuHeight - buttonHeight) / 2.0;

    for (NSInteger i = 0; i < (NSInteger)visibleButtons.count; i++) {
        UIButton *button = visibleButtons[i];
        CGFloat xPosition = containerStartX + i * (buttonWidth + spacing);

        button.translatesAutoresizingMaskIntoConstraints = YES;
        button.frame = CGRectMake(xPosition, containerY, buttonWidth, buttonHeight);

        [button setNeedsLayout];
        [button layoutIfNeeded];
    }

    for (CALayer *layer in self.menuView.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]]) {
            layer.frame = CGRectMake(0, 0, idealMenuWidth, menuHeight);
            break;
        }
    }

    [self.menuView setNeedsLayout];
    [self.menuView layoutIfNeeded];

    LOG_POSITION(@"Updated button layout: %ld visible buttons, menu width: %.1f, total buttons width: %.1f",
                 (long)visibleButtons.count, idealMenuWidth, totalButtonsWidth);

    self.isUpdatingButtonLayout = NO;
}

#pragma mark - Dynamic Island Avoidance

- (CGRect)getDynamicIslandRect:(UIWindow *)window {
    if (!window) return CGRectZero;

    CGRect screenBounds = window.bounds;
    CGFloat screenWidth = screenBounds.size.width;

    UIEdgeInsets safeAreaInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safeAreaInsets = window.safeAreaInsets;
    }

    CGFloat dynamicIslandHeight = safeAreaInsets.top;
    CGFloat dynamicIslandX = (screenWidth - kDynamicIslandWidth) / 2.0;
    CGFloat dynamicIslandY = 0;

    CGRect dynamicIslandRect = CGRectMake(dynamicIslandX, dynamicIslandY, kDynamicIslandWidth, dynamicIslandHeight);

    LOG_POSITION(@"Dynamic Island rect: (%.1f, %.1f, %.1f, %.1f)",
                 dynamicIslandRect.origin.x, dynamicIslandRect.origin.y,
                 dynamicIslandRect.size.width, dynamicIslandRect.size.height);

    return dynamicIslandRect;
}

- (BOOL)doesCapsuleOverlapDynamicIsland:(UIWindow *)window {
    CGRect dynamicIslandRect = [self getDynamicIslandRect:window];

    if (dynamicIslandRect.size.height <= 0) {
        return NO;
    }

    CGRect capsuleRect = self.frame;
    BOOL overlap = CGRectIntersectsRect(capsuleRect, dynamicIslandRect);

    if (overlap) {
        LOG_POSITION(@"Capsule overlaps with Dynamic Island - Capsule: (%.1f, %.1f, %.1f, %.1f), Island: (%.1f, %.1f, %.1f, %.1f)",
                     capsuleRect.origin.x, capsuleRect.origin.y, capsuleRect.size.width, capsuleRect.size.height,
                     dynamicIslandRect.origin.x, dynamicIslandRect.origin.y, dynamicIslandRect.size.width, dynamicIslandRect.size.height);
    }

    return overlap;
}

- (CGPoint)adjustPositionToAvoidDynamicIsland:(UIWindow *)window {
    CGRect dynamicIslandRect = [self getDynamicIslandRect:window];

    if (dynamicIslandRect.size.height <= 0) {
        return self.frame.origin;
    }

    CGRect capsuleRect = self.frame;
    CGRect screenBounds = window.bounds;

    CGFloat moveLeft = dynamicIslandRect.origin.x - (capsuleRect.origin.x + capsuleRect.size.width);
    CGFloat moveRight = (dynamicIslandRect.origin.x + dynamicIslandRect.size.width) - capsuleRect.origin.x;
    CGFloat moveDown = (dynamicIslandRect.origin.y + dynamicIslandRect.size.height) - capsuleRect.origin.y;

    CGFloat newX = capsuleRect.origin.x;
    CGFloat newY = capsuleRect.origin.y;

    if (fabs(moveLeft) <= fabs(moveRight)) {
        newX = capsuleRect.origin.x + moveLeft;
        LOG_POSITION(@"Avoiding Dynamic Island by moving left by %.1f", fabs(moveLeft));
    } else {
        newX = capsuleRect.origin.x + moveRight;
        LOG_POSITION(@"Avoiding Dynamic Island by moving right by %.1f", moveRight);
    }

    if (newX < 0 || newX + capsuleRect.size.width > screenBounds.size.width) {
        newX = capsuleRect.origin.x;
        newY = capsuleRect.origin.y + moveDown;
        LOG_POSITION(@"Horizontal movement out of bounds, moving down by %.1f instead", moveDown);
    }

    newX = MAX(0, MIN(screenBounds.size.width - capsuleRect.size.width, newX));
    newY = MAX(0, MIN(screenBounds.size.height - capsuleRect.size.height, newY));

    LOG_POSITION(@"Adjusted position to avoid Dynamic Island: (%.1f, %.1f) -> (%.1f, %.1f)",
                 capsuleRect.origin.x, capsuleRect.origin.y, newX, newY);

    return CGPointMake(newX, newY);
}

#pragma mark - Button Touch Event Handlers

- (void)buttonTouchDown:(UIButton *)sender {
    [self animateButton:sender pressed:YES];
}

- (void)buttonTouchUpInside:(UIButton *)sender {
    [self animateButton:sender pressed:NO];
    NSString *buttonType = sender.accessibilityIdentifier;
    [self handleButtonAction:buttonType];
}

- (void)buttonTouchUpOutside:(UIButton *)sender {
    [self animateButton:sender pressed:NO];
}

- (void)buttonTouchCancel:(UIButton *)sender {
    [self animateButton:sender pressed:NO];
}

- (void)animateButton:(UIButton *)button pressed:(BOOL)pressed {
    [UIView animateWithDuration:0.1 animations:^{
        button.alpha = pressed ? 0.5 : 1.0;
        button.transform = pressed ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
    }];
}

- (void)handleButtonAction:(NSString *)buttonType {
    if ([buttonType isEqualToString:kIconActionsButton]) {
        [self actionsButtonTapped:nil];
    } else if ([buttonType isEqualToString:kIconBackButton]) {
        [self backButtonTapped:nil];
    } else if ([buttonType isEqualToString:kIconHomeButton]) {
        [self homeButtonTapped:nil];
    } else if ([buttonType isEqualToString:kIconSwitchButton]) {
        [self switchButtonTapped:nil];
    } else if ([buttonType isEqualToString:kIconKeyboardButton]) {
        [self keyboardButtonTapped:nil];
    } else if ([buttonType isEqualToString:kIconClipboardSyncButton]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCSyncClipboardRequest object:nil];
    } else if ([buttonType isEqualToString:kIconDisconnectButton]) {
        [self disconnectButtonTapped:nil];
    }
}

@end
