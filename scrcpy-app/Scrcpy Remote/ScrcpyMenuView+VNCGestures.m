//
//  ScrcpyMenuView+VNCGestures.m
//  Scrcpy Remote
//
//  VNC gesture handling category for ScrcpyMenuView
//

#import "ScrcpyMenuView+VNCGestures.h"
#import "ScrcpyMenuView+Private.h"
#import "ScrcpyConstants.h"
#import "ScrcpyVNCClient.h"
#import <SDL3/SDL_mouse.h>

@implementation ScrcpyMenuView (VNCGestures)

#pragma mark - SDL Window Helper

- (UIWindow *)getSDLWindow {
    // Try to get window through SDL
    // SDL3 replaced SDL_GetWindowWMInfo with the per-window properties bag.
    SDL_Window *sdlWindow = SDL_GetMouseFocus();
    if (sdlWindow) {
        SDL_PropertiesID props = SDL_GetWindowProperties(sdlWindow);
        UIWindow *uiWindow = (__bridge UIWindow *)
            SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
        if (uiWindow) {
            return uiWindow;
        }
    }

    // Fallback: Find key window in active scene
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    return nil;
}

#pragma mark - VNC Pinch Gesture Management

- (void)addPinchGesture {
    // Remove existing gesture if any
    [self removePinchGesture];

    // Get SDL window
    UIWindow *sdlWindow = [self getSDLWindow];
    if (!sdlWindow) {
        LOG_POSITION(@"⚠️ Cannot add pinch gesture - SDL window not found");
        return;
    }

    // Create pinch gesture recognizer
    self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleVNCPinch:)];
    self.pinchGesture.delegate = self;

    // Configure gesture properties
    self.pinchGesture.delaysTouchesBegan = NO;
    self.pinchGesture.delaysTouchesEnded = NO;
    self.pinchGesture.cancelsTouchesInView = YES;

    // Add to SDL window
    UIViewController *rootVC = sdlWindow.rootViewController;
    if (rootVC && rootVC.view && rootVC.view.window) {
        [rootVC.view.window addGestureRecognizer:self.pinchGesture];
        LOG_POSITION(@"✅ Added pinch gesture to SDL window");
    } else {
        LOG_POSITION(@"⚠️ Cannot add pinch gesture - SDL window or root view controller not found");
    }
}

- (void)removePinchGesture {
    if (self.pinchGesture) {
        [self.pinchGesture.view removeGestureRecognizer:self.pinchGesture];
        self.pinchGesture = nil;
    }
    LOG_POSITION(@"🗑️ Removed VNC pinch gesture");
}

#pragma mark - Pinch Gesture Handler

- (void)handleVNCPinch:(UIPinchGestureRecognizer *)gesture {
    if (self.currentDeviceType != ScrcpyDeviceTypeVNC) {
        return;
    }

    CGFloat gestureScale = gesture.scale;

    // Calculate normalized touch center (0.0-1.0)
    CGPoint pinchCenter = [gesture locationInView:gesture.view];
    CGSize viewSize = gesture.view.bounds.size;
    CGFloat normalizedX = MAX(0.0, MIN(1.0, pinchCenter.x / viewSize.width));
    CGFloat normalizedY = MAX(0.0, MIN(1.0, pinchCenter.y / viewSize.height));

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            // Record zoom scale at gesture start
            self.currentZoomScale = MAX(kMinZoomScale, MIN(kMaxZoomScale, self.currentZoomScale));
            self.gestureStartZoomScale = self.currentZoomScale;
            self.gestureStartCenterX = pinchCenter.x;
            self.gestureStartCenterY = pinchCenter.y;

            CGFloat normalizedStartX = MAX(0.0, MIN(1.0, self.gestureStartCenterX / viewSize.width));
            CGFloat normalizedStartY = MAX(0.0, MIN(1.0, self.gestureStartCenterY / viewSize.height));

            LOG_POSITION(@"🔍 VNC Pinch gesture began - current zoom: %.3f, gesture scale: %.3f, center: (%.3f, %.3f)",
                         self.currentZoomScale, gestureScale, normalizedStartX, normalizedStartY);

            // Notify delegate
            if ([self.delegate respondsToSelector:@selector(didPinchWithScale:centerX:centerY:)]) {
                [self.delegate didPinchWithScale:self.currentZoomScale centerX:normalizedStartX centerY:normalizedStartY];
            } else if ([self.delegate respondsToSelector:@selector(didPinchWithScale:)]) {
                [self.delegate didPinchWithScale:self.currentZoomScale];
            }
            break;
        }

        case UIGestureRecognizerStateChanged: {
            CGFloat newScale = MAX(kMinZoomScale, MIN(kMaxZoomScale, self.gestureStartZoomScale * gestureScale));

            CGFloat normalizedStartX = MAX(0.0, MIN(1.0, self.gestureStartCenterX / viewSize.width));
            CGFloat normalizedStartY = MAX(0.0, MIN(1.0, self.gestureStartCenterY / viewSize.height));

            LOG_POSITION(@"🔍 VNC Pinch gesture changed - gesture scale: %.3f, start zoom: %.3f, new scale: %.3f, fixed center: (%.3f, %.3f)",
                         gestureScale, self.gestureStartZoomScale, newScale, normalizedStartX, normalizedStartY);

            if ([self.delegate respondsToSelector:@selector(didPinchWithScale:centerX:centerY:)]) {
                [self.delegate didPinchWithScale:newScale centerX:normalizedStartX centerY:normalizedStartY];
            } else if ([self.delegate respondsToSelector:@selector(didPinchWithScale:)]) {
                [self.delegate didPinchWithScale:newScale];
            }
            break;
        }

        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat finalScale = MAX(kMinZoomScale, MIN(kMaxZoomScale, self.gestureStartZoomScale * gestureScale));
            self.currentZoomScale = finalScale;

            CGFloat normalizedStartX = MAX(0.0, MIN(1.0, self.gestureStartCenterX / viewSize.width));
            CGFloat normalizedStartY = MAX(0.0, MIN(1.0, self.gestureStartCenterY / viewSize.height));

            LOG_POSITION(@"🔍 VNC Pinch gesture ended - gesture scale: %.3f, final scale: %.3f, fixed center: (%.3f, %.3f)",
                         gestureScale, finalScale, normalizedStartX, normalizedStartY);

            if ([self.delegate respondsToSelector:@selector(didPinchEndWithFinalScale:centerX:centerY:)]) {
                [self.delegate didPinchEndWithFinalScale:finalScale centerX:normalizedStartX centerY:normalizedStartY];
            } else if ([self.delegate respondsToSelector:@selector(didPinchEndWithFinalScale:)]) {
                [self.delegate didPinchEndWithFinalScale:finalScale];
            }
            break;
        }

        default:
            break;
    }
}

#pragma mark - Drag Gesture Management

- (void)addDragGesture {
    // Remove existing gestures if any
    [self removeDragGesture];

    // Get SDL window
    UIWindow *sdlWindow = [self getSDLWindow];
    if (!sdlWindow) {
        LOG_POSITION(@"⚠️ Cannot add drag gesture - SDL window not found");
        return;
    }

    // Create single-finger drag gesture (mouse movement)
    self.dragGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)];
    self.dragGesture.delegate = self;
    self.dragGesture.minimumNumberOfTouches = 1;
    self.dragGesture.maximumNumberOfTouches = 1;
    LOG_POSITION(@"✅ Created single-finger drag gesture: %@", self.dragGesture);

    // Create two-finger scroll gesture
    self.scrollGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleScroll:)];
    self.scrollGesture.delegate = self;
    self.scrollGesture.minimumNumberOfTouches = 2;
    self.scrollGesture.maximumNumberOfTouches = 2;
    self.scrollGesture.delaysTouchesBegan = NO;
    self.scrollGesture.delaysTouchesEnded = NO;
    self.scrollGesture.cancelsTouchesInView = NO;

    LOG_POSITION(@"✅ Created two-finger scroll gesture with priority settings: %@", self.scrollGesture);

    // Add to SDL window
    UIViewController *rootVC = sdlWindow.rootViewController;
    if (rootVC && rootVC.view && rootVC.view.window) {
        [rootVC.view.window addGestureRecognizer:self.dragGesture];
        [rootVC.view.window addGestureRecognizer:self.scrollGesture];
        LOG_POSITION(@"✅ Added drag and scroll gestures to SDL window: %@", rootVC.view.window);
    } else {
        LOG_POSITION(@"⚠️ Cannot add drag gesture - SDL window or root view controller not found");
    }
}

- (void)removeDragGesture {
    if (self.dragGesture) {
        [self.dragGesture.view removeGestureRecognizer:self.dragGesture];
        self.dragGesture = nil;
    }
    if (self.scrollGesture) {
        [self.scrollGesture.view removeGestureRecognizer:self.scrollGesture];
        self.scrollGesture = nil;
    }
    LOG_POSITION(@"🗑️ Removed VNC drag and scroll gestures");
}

- (void)resetDragOffset {
    self.currentDragOffset = CGPointZero;
    self.totalDragOffset = CGPointZero;
    self.dragStartLocation = CGPointZero;
    self.isDragging = NO;
    self.isScrolling = NO;
    LOG_POSITION(@"🔄 Reset drag offset and states to zero");
}

#pragma mark - Tap Gesture Management

- (void)addTapGesture {
    // Remove existing gestures if any
    [self removeTapGesture];

    // Get SDL window
    UIWindow *sdlWindow = [self getSDLWindow];
    if (!sdlWindow) {
        LOG_POSITION(@"⚠️ Cannot add tap gesture - SDL window not found");
        return;
    }

    // Create single-finger tap gesture (left click)
    self.vncTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleVNCTap:)];
    self.vncTapGesture.delegate = self;
    self.vncTapGesture.numberOfTapsRequired = 1;
    self.vncTapGesture.numberOfTouchesRequired = 1;

    // Create two-finger tap gesture (right click, like TrackPad)
    self.vncTwoFingerTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleVNCTwoFingerTap:)];
    self.vncTwoFingerTapGesture.delegate = self;
    self.vncTwoFingerTapGesture.numberOfTapsRequired = 1;
    self.vncTwoFingerTapGesture.numberOfTouchesRequired = 2;

    // Add to SDL window
    UIViewController *rootVC = sdlWindow.rootViewController;
    if (rootVC && rootVC.view && rootVC.view.window) {
        [rootVC.view.window addGestureRecognizer:self.vncTapGesture];
        [rootVC.view.window addGestureRecognizer:self.vncTwoFingerTapGesture];
        LOG_POSITION(@"✅ Added tap and two-finger tap gestures to SDL window");
    } else {
        LOG_POSITION(@"⚠️ Cannot add tap gesture - SDL window or root view controller not found");
    }
}

- (void)removeTapGesture {
    if (self.vncTapGesture) {
        [self.vncTapGesture.view removeGestureRecognizer:self.vncTapGesture];
        self.vncTapGesture = nil;
    }
    if (self.vncTwoFingerTapGesture) {
        [self.vncTwoFingerTapGesture.view removeGestureRecognizer:self.vncTwoFingerTapGesture];
        self.vncTwoFingerTapGesture = nil;
    }
    LOG_POSITION(@"🗑️ Removed VNC tap gestures");
}

- (void)handleVNCTap:(UITapGestureRecognizer *)gesture {
    [self handleVNCTapGesture:gesture isRightClick:NO];
}

- (void)handleVNCTwoFingerTap:(UITapGestureRecognizer *)gesture {
    [self handleVNCTapGesture:gesture isRightClick:YES];
}

// Unified VNC tap gesture handler
- (void)handleVNCTapGesture:(UITapGestureRecognizer *)gesture isRightClick:(BOOL)isRightClick {
    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }

    CGPoint location = [gesture locationInView:gesture.view];
    CGSize viewSize = gesture.view.bounds.size;

    NSLog(@"🎯 [ScrcpyMenuView] VNC %@ tap gesture at (%.1f, %.1f), view size: (%.1fx%.1f)",
          isRightClick ? @"two-finger (right click)" : @"single", location.x, location.y, viewSize.width, viewSize.height);

    // Send click event notification
    NSDictionary *userInfo = @{
        kKeyType: kMouseEventTypeClick,
        kKeyLocation: [NSValue valueWithCGPoint:location],
        kKeyIsRightClick: @(isRightClick),
        kKeyViewSize: [NSValue valueWithCGSize:viewSize]
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
}

- (void)setupGesturePriorities {
    LOG_POSITION(@"🎯 Setting up VNC gesture priorities");

    if (self.vncTapGesture) {
        LOG_POSITION(@"✅ Tap gesture has highest priority for single finger touches");
    }
}

#pragma mark - VNC Gesture Helpers

- (BOOL)isVNCGesture:(UIGestureRecognizer *)gestureRecognizer {
    return gestureRecognizer == self.pinchGesture ||
           gestureRecognizer == self.dragGesture ||
           gestureRecognizer == self.scrollGesture ||
           gestureRecognizer == self.vncTapGesture ||
           gestureRecognizer == self.vncTwoFingerTapGesture;
}

- (NSString *)gestureNameForRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.pinchGesture) return @"Pinch";
    if (gestureRecognizer == self.dragGesture) return @"Drag";
    if (gestureRecognizer == self.scrollGesture) return @"Scroll";
    if (gestureRecognizer == self.vncTapGesture) return @"Tap";
    if (gestureRecognizer == self.vncTwoFingerTapGesture) return @"TwoFingerTap";
    return @"Unknown";
}

- (CGPoint)normalizedOffsetForTranslation:(CGPoint)translation viewSize:(CGSize)viewSize {
    CGFloat normalizedOffsetX = viewSize.width > 0 ? translation.x / viewSize.width : 0;
    CGFloat normalizedOffsetY = viewSize.height > 0 ? translation.y / viewSize.height : 0;
    return CGPointMake(MAX(-1.0, MIN(1.0, normalizedOffsetX)), MAX(-1.0, MIN(1.0, normalizedOffsetY)));
}

#pragma mark - Delegate Notification Helpers

- (void)notifyDelegateWithDragState:(NSString *)state location:(CGPoint)location viewSize:(CGSize)viewSize offset:(CGPoint)offset {
    if ([self.delegate respondsToSelector:@selector(didDragWithState:location:viewSize:offset:)]) {
        [self.delegate didDragWithState:state location:location viewSize:viewSize offset:offset];
    } else if ([self.delegate respondsToSelector:@selector(didDragWithState:location:viewSize:)]) {
        [self.delegate didDragWithState:state location:location viewSize:viewSize];
    }
    [self sendDragNotificationWithState:state location:location viewSize:viewSize offset:offset];
}

- (void)notifyDelegateWithNormalizedOffset:(CGPoint)normalizedOffset viewSize:(CGSize)viewSize isEnd:(BOOL)isEnd {
    if (isEnd) {
        if ([self.delegate respondsToSelector:@selector(didDragEndWithNormalizedOffset:viewSize:)]) {
            [self.delegate didDragEndWithNormalizedOffset:normalizedOffset viewSize:viewSize];
        }
        [self sendDragEndNotificationWithNormalizedOffset:normalizedOffset viewSize:viewSize];
    } else {
        if ([self.delegate respondsToSelector:@selector(didDragWithNormalizedOffset:viewSize:)]) {
            [self.delegate didDragWithNormalizedOffset:normalizedOffset viewSize:viewSize];
        }
        [self sendDragOffsetNotificationWithNormalizedOffset:normalizedOffset viewSize:viewSize];
    }
}

#pragma mark - Drag Gesture Handler

- (void)handleDrag:(UIPanGestureRecognizer *)gesture {
    LOG_POSITION(@"🎯 [ScrcpyMenuView] handleDrag called - state: %ld, deviceType: %ld", (long)gesture.state, (long)self.currentDeviceType);

    if (self.currentDeviceType != ScrcpyDeviceTypeVNC) {
        LOG_POSITION(@"⚠️ [ScrcpyMenuView] handleDrag ignored - not VNC device");
        return;
    }

    CGPoint location = [gesture locationInView:gesture.view];
    CGSize viewSize = gesture.view.bounds.size;

    LOG_POSITION(@"🎯 VNC Single-finger drag gesture - state: %ld, location: (%.1f, %.1f)",
                 (long)gesture.state, location.x, location.y);

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragStartLocation = location;
            self.currentDragOffset = CGPointZero;
            self.isDragging = YES;

            LOG_POSITION(@"🎯 VNC Single-finger drag began - start location: (%.1f, %.1f), viewSize: (%.1f, %.1f), isDragging: %@",
                         location.x, location.y, viewSize.width, viewSize.height, self.isDragging ? @"YES" : @"NO");

            [self notifyDelegateWithDragState:kDragStateBegan location:location viewSize:viewSize offset:self.currentDragOffset];
            break;
        }

        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [gesture translationInView:gesture.view];
            self.currentDragOffset = translation;
            CGPoint normalizedOffset = [self normalizedOffsetForTranslation:translation viewSize:viewSize];

            LOG_POSITION(@"🎯 VNC Single-finger drag changed - location: (%.1f, %.1f), translation: (%.1f, %.1f), normalized offset: (%.3f, %.3f)",
                         location.x, location.y, translation.x, translation.y, normalizedOffset.x, normalizedOffset.y);

            [self notifyDelegateWithDragState:kDragStateChanged location:location viewSize:viewSize offset:self.currentDragOffset];
            [self notifyDelegateWithNormalizedOffset:normalizedOffset viewSize:viewSize isEnd:NO];
            break;
        }

        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [gesture translationInView:gesture.view];
            self.currentDragOffset = translation;
            self.totalDragOffset = CGPointMake(self.totalDragOffset.x + translation.x,
                                              self.totalDragOffset.y + translation.y);
            CGPoint normalizedOffset = [self normalizedOffsetForTranslation:translation viewSize:viewSize];

            LOG_POSITION(@"🎯 VNC Single-finger drag ended - location: (%.1f, %.1f), final translation: (%.1f, %.1f), normalized offset: (%.3f, %.3f)",
                         location.x, location.y, translation.x, translation.y, normalizedOffset.x, normalizedOffset.y);

            [self notifyDelegateWithDragState:kDragStateEnded location:location viewSize:viewSize offset:self.currentDragOffset];
            [self notifyDelegateWithNormalizedOffset:normalizedOffset viewSize:viewSize isEnd:YES];

            self.isDragging = NO;
            LOG_POSITION(@"🎯 VNC Single-finger drag ended - isDragging reset to: %@", self.isDragging ? @"YES" : @"NO");
            break;
        }

        case UIGestureRecognizerStateCancelled: {
            self.currentDragOffset = CGPointZero;

            LOG_POSITION(@"🎯 VNC Single-finger drag cancelled - location: (%.1f, %.1f)", location.x, location.y);

            [self notifyDelegateWithDragState:kDragStateCancelled location:location viewSize:viewSize offset:self.currentDragOffset];

            self.isDragging = NO;
            LOG_POSITION(@"🎯 VNC Single-finger drag cancelled - isDragging reset to: %@", self.isDragging ? @"YES" : @"NO");
            break;
        }

        default:
            break;
    }
}

#pragma mark - Scroll Gesture Handler

- (void)handleScroll:(UIPanGestureRecognizer *)gesture {
    LOG_POSITION(@"📜 [ScrcpyMenuView] handleScroll called - state: %ld, deviceType: %ld", (long)gesture.state, (long)self.currentDeviceType);

    if (self.currentDeviceType != ScrcpyDeviceTypeVNC) {
        LOG_POSITION(@"⚠️ [ScrcpyMenuView] handleScroll ignored - not VNC device");
        return;
    }

    CGPoint location = [gesture locationInView:gesture.view];
    CGSize viewSize = gesture.view.bounds.size;

    LOG_POSITION(@"📜 VNC Two-finger scroll gesture - state: %ld, location: (%.1f, %.1f)",
                 (long)gesture.state, location.x, location.y);

    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragStartLocation = location;
            self.currentDragOffset = CGPointZero;
            self.isScrolling = YES;

            LOG_POSITION(@"📜 VNC Two-finger scroll began - start location: (%.1f, %.1f), viewSize: (%.1f, %.1f), isScrolling: %@",
                         location.x, location.y, viewSize.width, viewSize.height, self.isScrolling ? @"YES" : @"NO");

            [self sendScrollNotificationWithState:kDragStateBegan
                                          location:location
                                          viewSize:viewSize
                                            offset:CGPointZero];
            break;
        }

        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [gesture translationInView:gesture.view];
            self.currentDragOffset = translation;

            LOG_POSITION(@"📜 VNC Two-finger scroll changed - location: (%.1f, %.1f), translation: (%.1f, %.1f)",
                         location.x, location.y, translation.x, translation.y);

            [self sendScrollNotificationWithState:kDragStateChanged
                                          location:location
                                          viewSize:viewSize
                                            offset:translation];
            break;
        }

        case UIGestureRecognizerStateEnded: {
            CGPoint translation = [gesture translationInView:gesture.view];
            self.currentDragOffset = translation;

            LOG_POSITION(@"📜 VNC Two-finger scroll ended - location: (%.1f, %.1f), final translation: (%.1f, %.1f)",
                         location.x, location.y, translation.x, translation.y);

            [self sendScrollNotificationWithState:kDragStateEnded
                                          location:location
                                          viewSize:viewSize
                                            offset:translation];

            self.isScrolling = NO;
            LOG_POSITION(@"📜 VNC Two-finger scroll ended - isScrolling reset to: %@", self.isScrolling ? @"YES" : @"NO");
            break;
        }

        case UIGestureRecognizerStateCancelled: {
            self.currentDragOffset = CGPointZero;

            LOG_POSITION(@"📜 VNC Two-finger scroll cancelled - location: (%.1f, %.1f)", location.x, location.y);

            [self sendScrollNotificationWithState:kDragStateCancelled
                                          location:location
                                          viewSize:viewSize
                                            offset:CGPointZero];

            self.isScrolling = NO;
            LOG_POSITION(@"📜 VNC Two-finger scroll cancelled - isScrolling reset to: %@", self.isScrolling ? @"YES" : @"NO");
            break;
        }

        default:
            break;
    }
}

#pragma mark - Notification Helpers

- (void)sendDragNotificationWithState:(NSString *)state location:(CGPoint)location viewSize:(CGSize)viewSize offset:(CGPoint)offset {
    NSDictionary *userInfo = @{
        kKeyState: state,
        kKeyLocation: [NSValue valueWithCGPoint:location],
        kKeyViewSize: [NSValue valueWithCGSize:viewSize],
        kKeyOffset: [NSValue valueWithCGPoint:offset]
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCDrag object:nil userInfo:userInfo];
}

- (void)sendDragOffsetNotificationWithNormalizedOffset:(CGPoint)normalizedOffset viewSize:(CGSize)viewSize {
    NSDictionary *userInfo = @{
        kKeyNormalizedOffset: [NSValue valueWithCGPoint:normalizedOffset],
        kKeyViewSize: [NSValue valueWithCGSize:viewSize],
        kKeyZoomScale: @(self.currentZoomScale)
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCDragOffset object:nil userInfo:userInfo];
}

- (void)sendDragEndNotificationWithNormalizedOffset:(CGPoint)normalizedOffset viewSize:(CGSize)viewSize {
    NSDictionary *userInfo = @{
        kKeyNormalizedOffset: [NSValue valueWithCGPoint:normalizedOffset],
        kKeyViewSize: [NSValue valueWithCGSize:viewSize],
        kKeyZoomScale: @(self.currentZoomScale)
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCDragOffset object:nil userInfo:userInfo];
}

- (void)sendScrollNotificationWithState:(NSString *)state location:(CGPoint)location viewSize:(CGSize)viewSize offset:(CGPoint)offset {
    CGFloat normalizedOffsetX = MAX(-1.0, MIN(1.0, offset.x / viewSize.width));
    CGFloat normalizedOffsetY = MAX(-1.0, MIN(1.0, offset.y / viewSize.height));
    CGPoint normalizedOffset = CGPointMake(normalizedOffsetX, normalizedOffsetY);

    LOG_POSITION(@"📜 [ScrcpyMenuView] Sending scroll notification - state: %@, offset: (%.1f, %.1f), normalized: (%.3f, %.3f)",
                 state, offset.x, offset.y, normalizedOffset.x, normalizedOffset.y);

    NSDictionary *userInfo = @{
        kKeyState: state,
        kKeyLocation: [NSValue valueWithCGPoint:location],
        kKeyViewSize: [NSValue valueWithCGSize:viewSize],
        kKeyOffset: [NSValue valueWithCGPoint:offset],
        kKeyNormalizedOffset: [NSValue valueWithCGPoint:normalizedOffset],
        kKeyZoomScale: @(self.currentZoomScale),
        kKeyType: kMouseEventTypeScroll
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCScrollEvent object:nil userInfo:userInfo];
}

#pragma mark - VNC Touch Event Forwarding

- (void)forwardTouchAsMouseMoveToVNC:(CGPoint)location {
    self.touchStartTime = [[NSDate date] timeIntervalSince1970];
    self.touchStartLocation = location;
    self.isDragging = NO;

    NSLog(@"🎯 [ScrcpyMenuView] Touch began at (%.1f, %.1f), forwarding as mouse move", location.x, location.y);

    NSDictionary *userInfo = @{
        kKeyType: kMouseEventTypeMove,
        kKeyLocation: [NSValue valueWithCGPoint:location],
        kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
}

- (void)forwardTouchAsMouseDragToVNC:(CGPoint)location {
    CGFloat deltaX = location.x - self.touchStartLocation.x;
    CGFloat deltaY = location.y - self.touchStartLocation.y;
    CGFloat distance = sqrt(deltaX * deltaX + deltaY * deltaY);

    const CGFloat dragThreshold = 5.0;
    if (distance > dragThreshold) {
        if (!self.isDragging) {
            self.isDragging = YES;
            NSLog(@"🎯 [ScrcpyMenuView] Drag started at (%.1f, %.1f)", self.touchStartLocation.x, self.touchStartLocation.y);

            NSDictionary *userInfo = @{
                kKeyType: kMouseEventTypeDragStart,
                kKeyLocation: [NSValue valueWithCGPoint:self.touchStartLocation],
                kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
            };
            [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
        }

        NSLog(@"🎯 [ScrcpyMenuView] Dragging to (%.1f, %.1f)", location.x, location.y);

        NSDictionary *userInfo = @{
            kKeyType: kMouseEventTypeDrag,
            kKeyLocation: [NSValue valueWithCGPoint:location],
            kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
    } else {
        [self forwardTouchAsMouseMoveToVNC:location];
    }
}

- (void)forwardTouchEndAsMouseEventToVNC:(CGPoint)location withTouch:(UITouch *)touch {
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval touchDuration = currentTime - self.touchStartTime;

    CGFloat deltaX = location.x - self.touchStartLocation.x;
    CGFloat deltaY = location.y - self.touchStartLocation.y;
    CGFloat distance = sqrt(deltaX * deltaX + deltaY * deltaY);

    const CGFloat clickThreshold = 5.0;
    const NSTimeInterval clickTimeThreshold = 0.5;

    if (self.isDragging) {
        NSLog(@"🎯 [ScrcpyMenuView] Drag ended at (%.1f, %.1f)", location.x, location.y);

        NSDictionary *userInfo = @{
            kKeyType: kMouseEventTypeDragEnd,
            kKeyLocation: [NSValue valueWithCGPoint:location],
            kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];

        self.isDragging = NO;
    } else if (distance <= clickThreshold && touchDuration <= clickTimeThreshold) {
        BOOL isRightClick = (touch.tapCount == 2);

        NSLog(@"🎯 [ScrcpyMenuView] %@ click at (%.1f, %.1f), duration: %.3fs, distance: %.1f",
              isRightClick ? kLogLabelRight : kLogLabelLeft, location.x, location.y, touchDuration, distance);

        NSDictionary *userInfo = @{
            kKeyType: kMouseEventTypeClick,
            kKeyLocation: [NSValue valueWithCGPoint:location],
            kKeyIsRightClick: @(isRightClick),
            kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
    } else {
        NSLog(@"🎯 [ScrcpyMenuView] Touch ended without click or drag (duration: %.3fs, distance: %.1f)", touchDuration, distance);
    }

    self.isDragging = NO;
    self.touchStartTime = 0;
    self.touchStartLocation = CGPointZero;
}

- (void)forwardTouchCancelToVNC:(CGPoint)location {
    if (self.isDragging) {
        NSLog(@"🎯 [ScrcpyMenuView] Touch cancelled during drag at (%.1f, %.1f)", location.x, location.y);

        NSDictionary *userInfo = @{
            kKeyType: kMouseEventTypeDragEnd,
            kKeyLocation: [NSValue valueWithCGPoint:location],
            kKeyViewSize: [NSValue valueWithCGSize:self.bounds.size]
        };
        [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationVNCMouseEvent object:nil userInfo:userInfo];
    }

    self.isDragging = NO;
    self.touchStartTime = 0;
    self.touchStartLocation = CGPointZero;
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    LOG_POSITION(@"🤝 [ScrcpyMenuView] shouldRecognizeSimultaneously - gesture1: %@, gesture2: %@",
                 gestureRecognizer.class, otherGestureRecognizer.class);

    // During drag or scroll, prevent tap gestures from recognizing simultaneously
    if (self.isDragging || self.isScrolling) {
        if (gestureRecognizer == self.vncTapGesture || gestureRecognizer == self.vncTwoFingerTapGesture ||
            otherGestureRecognizer == self.vncTapGesture || otherGestureRecognizer == self.vncTwoFingerTapGesture) {
            return NO;
        }
    }

    // Two-finger scroll and single-finger drag are mutually exclusive
    if ((gestureRecognizer == self.scrollGesture && otherGestureRecognizer == self.dragGesture) ||
        (gestureRecognizer == self.dragGesture && otherGestureRecognizer == self.scrollGesture)) {
        LOG_POSITION(@"⛔ [ScrcpyMenuView] Preventing simultaneous drag and scroll");
        return NO;
    }

    // Tap gestures don't work with drag gestures
    if ((gestureRecognizer == self.vncTapGesture && (otherGestureRecognizer == self.dragGesture || otherGestureRecognizer == self.scrollGesture)) ||
        ((gestureRecognizer == self.dragGesture || gestureRecognizer == self.scrollGesture) && otherGestureRecognizer == self.vncTapGesture)) {
        return NO;
    }

    // Two-finger tap doesn't work with drag or scroll
    if ((gestureRecognizer == self.vncTwoFingerTapGesture && (otherGestureRecognizer == self.dragGesture || otherGestureRecognizer == self.scrollGesture)) ||
        ((gestureRecognizer == self.dragGesture || gestureRecognizer == self.scrollGesture) && otherGestureRecognizer == self.vncTwoFingerTapGesture)) {
        return NO;
    }

    // Allow scroll and pinch to compete
    if ((gestureRecognizer == self.scrollGesture && otherGestureRecognizer == self.pinchGesture) ||
        (gestureRecognizer == self.pinchGesture && otherGestureRecognizer == self.scrollGesture)) {
        LOG_POSITION(@"🤝 [ScrcpyMenuView] Allowing scroll and pinch to compete");
        return YES;
    }

    // Allow pinch and single-finger drag together
    if ((gestureRecognizer == self.pinchGesture && otherGestureRecognizer == self.dragGesture) ||
        (gestureRecognizer == self.dragGesture && otherGestureRecognizer == self.pinchGesture)) {
        return YES;
    }

    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    LOG_POSITION(@"🐆 [ScrcpyMenuView] shouldReceiveTouch - gesture: %@, isDragging: %@, isScrolling: %@, deviceType: %ld",
                 gestureRecognizer.class, self.isDragging ? @"YES" : @"NO", self.isScrolling ? @"YES" : @"NO", (long)self.currentDeviceType);

    // Block tap gestures during drag or scroll
    if (self.isDragging || self.isScrolling) {
        if (gestureRecognizer == self.vncTapGesture || gestureRecognizer == self.vncTwoFingerTapGesture) {
            NSLog(@"🚫 [ScrcpyMenuView] Blocking tap gesture during drag/scroll");
            return NO;
        }
    }

    // Block single-finger drag during scroll
    if (self.isScrolling && gestureRecognizer == self.dragGesture) {
        NSLog(@"🚫 [ScrcpyMenuView] Blocking single-finger drag during scroll");
        return NO;
    }

    // Block pinch during active scroll
    if (self.isScrolling && gestureRecognizer == self.pinchGesture && self.scrollGesture.state == UIGestureRecognizerStateChanged) {
        NSLog(@"🚫 [ScrcpyMenuView] Blocking pinch gesture during active scroll");
        return NO;
    }

    // Block two-finger scroll during single-finger drag
    if (self.isDragging && gestureRecognizer == self.scrollGesture) {
        NSLog(@"🚫 [ScrcpyMenuView] Blocking two-finger scroll during drag");
        return NO;
    }

    // Ensure VNC gestures only respond for VNC devices
    if ([self isVNCGesture:gestureRecognizer]) {
        BOOL shouldReceive = (self.currentDeviceType == ScrcpyDeviceTypeVNC);
        LOG_POSITION(@"🔍 [ScrcpyMenuView] VNC gesture %@ shouldReceive: %@",
                     [self gestureNameForRecognizer:gestureRecognizer], shouldReceive ? @"YES" : @"NO");
        return shouldReceive;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    LOG_POSITION(@"⏳ [ScrcpyMenuView] shouldRequireFailure - gesture: %@, waitFor: %@",
                 gestureRecognizer.class, otherGestureRecognizer.class);

    // Let non-tap gestures wait for tap to fail
    if (otherGestureRecognizer == self.vncTapGesture) {
        if (gestureRecognizer != self.dragGesture && gestureRecognizer != self.scrollGesture) {
            LOG_POSITION(@"⏳ [ScrcpyMenuView] Gesture %@ will wait for tap to fail", gestureRecognizer.class);
            return YES;
        }
    }

    // Let pinch and scroll compete naturally
    if (gestureRecognizer == self.pinchGesture && otherGestureRecognizer == self.scrollGesture) {
        LOG_POSITION(@"🤝 [ScrcpyMenuView] Pinch and scroll gestures compete naturally");
        return NO;
    }

    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // Smart detection based on gesture characteristics
    if (gestureRecognizer == self.pinchGesture || gestureRecognizer == self.scrollGesture) {
        if (gestureRecognizer == self.pinchGesture && self.isScrolling) {
            if (gestureRecognizer.numberOfTouches >= 2) {
                LOG_POSITION(@"🤔 [ScrcpyMenuView] Pinch gesture wants to start during scroll - allowing competition");
            }
            return YES;
        }

        if (gestureRecognizer == self.scrollGesture && self.pinchGesture.state == UIGestureRecognizerStateChanged) {
            LOG_POSITION(@"🤔 [ScrcpyMenuView] Scroll gesture wants to start during pinch - allowing competition");
            return YES;
        }
    }

    return YES;
}

@end
