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
