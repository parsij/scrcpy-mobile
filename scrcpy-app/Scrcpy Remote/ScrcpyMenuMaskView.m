#import "ScrcpyMenuMaskView.h"
#import <SDL3/SDL_system.h>

@implementation ScrcpyMenuMaskView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Setup view
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.alpha = 0.0;
        self.hidden = YES;
        
        // Add tap gesture recognizer
        UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] 
                                             initWithTarget:self 
                                             action:@selector(handleTap:)];
        [self addGestureRecognizer:tapGesture];
        
        // Register for orientation change notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    // Remove notification observer
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)orientationDidChange:(NSNotification *)notification {
    // Update frame when device orientation changes
    [self updateFrame];
}

- (void)showInView:(UIView *)parentView {
    // Ensure we're not already in view hierarchy
    [self removeFromSuperview];
    
    // Get the key window to ensure we cover the entire screen
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    
    // Set frame to cover the entire screen
    CGRect screenBounds = keyWindow.bounds;
    self.frame = [parentView.window convertRect:screenBounds fromWindow:keyWindow];
    
    // Add to parent view (at the bottom of hierarchy)
    [parentView insertSubview:self atIndex:0];
    
    // Show with animation
    self.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0.01; // Almost transparent but can receive events
    }];
}

- (void)hide {
    // Hide with animation
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        [self removeFromSuperview];
    }];
}

- (void)updateFrame {
    if (self.superview) {
        UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
        CGRect screenBounds = keyWindow.bounds;
        
        // Convert screen bounds to superview coordinates
        if (self.superview.window) {
            self.frame = [self.superview.window convertRect:screenBounds fromWindow:keyWindow];
        } else {
            self.frame = screenBounds;
        }
    }
}

- (void)handleTap:(UITapGestureRecognizer *)gesture {
    // Stop text input
    SDL_StopTextInput(SDL_GetKeyboardFocus());
    
    // Notify delegate
    if ([self.delegate respondsToSelector:@selector(didTapMenuMask)]) {
        [self.delegate didTapMenuMask];
    }
    
    // Hide self
    [self hide];
}

@end 