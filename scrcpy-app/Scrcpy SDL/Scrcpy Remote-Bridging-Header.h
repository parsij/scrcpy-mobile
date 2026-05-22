//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <SDL3/SDL.h>
// Intentionally do NOT import <SDL3/SDL_main.h>: in SDL3 that header
// generates an inline `int main(int, char**)` that calls SDL_RunApp +
// SDL_main, which conflicts with our SwiftUI host (the iOS app drives SDL
// through SDLUIKitDelegate / the porting layer).

#import "ScrcpyClientWrapper.h"
#import "ADBLatencyTester.h"
#import "TCPLatencyTester.h"
#import "ADBClient.h"
#import "ScrcpyCommon.h"
#import "ScrcpyRuntime.h"
#import "ADBMediaDetector.h"

// Import Tailscale library
#import "libtsnet-forwarder.h"
