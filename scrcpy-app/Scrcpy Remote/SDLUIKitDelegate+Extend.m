//
//  SDLUIKitDelegate+Extend.m
//  Scrcpy Remote
//
//  Created by Ethan on 5/10/25.
//

#import "SDLUIKitDelegate+Extend.h"

@implementation SDLUIKitDelegate (Extend)

- (void)postFinishLaunch {
    // Hihack postFinishLaunch to prevent SDL run forward_main function
    NSLog(@"SDL Hijacked -[SDLUIKitDelegate postFinishLaunch]");
}

@end

// SDL3 added SDLUIKitSceneDelegate for iOS 13+ scene-based launch. On modern
// iOS (the default since 13 and effectively required on 26+) SDL3 routes
// startup through THIS class's postFinishLaunch — not SDLUIKitDelegate's. The
// original implementation schedules a delayed self-perform that eventually
// calls a NULL SDL_main trampoline (we host SDL ourselves, so SDL_main is not
// defined). When the runloop timer fires the jump to 0x0 produces the field
// crash:
//   __NSFireDelayedPerform → -[SDLUIKitSceneDelegate postFinishLaunch]+64 → pc=0x0
//   (codesigning kills the process for an "Invalid Page" jump)
// A plain category override on SDLUIKitSceneDelegate wins reliably without
// any +load swizzle gymnastics, mirroring the existing SDLUIKitDelegate hijack.
//
// SDLUIKitSceneDelegate is declared by SDL3 internals (not exposed in any
// public header we ship). The class symbol is exported by the statically
// linked SDL3 lib, and the runtime de-dupes redeclarations the same way it
// already does for SDLUIKitDelegate (declared in ScrcpyClientWrapper.h with
// the same shape) — so adding a NSObject<UIApplicationDelegate>-shaped
// forward @interface here only gives the compiler the type info it needs;
// it does not create a second class at runtime.
@interface SDLUIKitSceneDelegate : NSObject
@end

@interface SDLUIKitSceneDelegate (ScrcpyExtend)
- (void)postFinishLaunch;
@end

@implementation SDLUIKitSceneDelegate (ScrcpyExtend)

- (void)postFinishLaunch {
    NSLog(@"SDL Hijacked -[SDLUIKitSceneDelegate postFinishLaunch]");
}

@end
