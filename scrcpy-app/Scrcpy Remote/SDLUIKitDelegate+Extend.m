//
//  SDLUIKitDelegate+Extend.m
//  Scrcpy Remote
//
//  Created by Ethan on 5/10/25.
//

#import <objc/runtime.h>
#import "SDLUIKitDelegate+Extend.h"

@implementation SDLUIKitDelegate (Extend)

// Force the original SDL3 -[SDLUIKitDelegate postFinishLaunch] to be replaced
// by our no-op stub at +load time. As a plain category override the resolution
// depends on link order — on iOS 26 (and in TestFlight Release builds) the
// SDL3 implementation can win, and that implementation schedules itself via
// `performSelector:withObject:afterDelay:` and later jumps to a SDL_main
// trampoline whose function pointer is NULL in our embedding, producing the
// crash:
//   __NSFireDelayedPerform → -[SDLUIKitDelegate postFinishLaunch]+64 → pc=0x0
// Swizzling in +load guarantees the no-op runs no matter the link order.
+ (void)load {
    Class cls = NSClassFromString(@"SDLUIKitDelegate");
    if (!cls) {
        return;
    }
    SEL sel = @selector(postFinishLaunch);
    Method ourMethod = class_getInstanceMethod([self class], sel);
    if (!ourMethod) {
        return;
    }
    IMP ourImp = method_getImplementation(ourMethod);
    const char *types = method_getTypeEncoding(ourMethod);
    class_replaceMethod(cls, sel, ourImp, types);
}

- (void)postFinishLaunch {
    // Hihack postFinishLaunch to prevent SDL run forward_main function
    NSLog(@"SDL Hijacked -[SDLUIKitDelegate postFinishLaunch]");

    // Belt-and-suspenders: even with the IMP replaced, SDL3 may have already
    // scheduled a delayed self-perform via -[NSObject performSelector:...
    // afterDelay:]. Cancel any pending perform so we don't fire again into a
    // partially-initialised SDL world.
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                              selector:_cmd
                                                object:nil];
}

@end
