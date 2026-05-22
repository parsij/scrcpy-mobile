//
//  ScrcpyADBClient.h
//  Scrcpy Remote
//
//  Created by Ethan on 12/16/24.
//

#import <Foundation/Foundation.h>
#import "scrcpy-porting.h"
#import <SDL3/SDL.h>

NS_ASSUME_NONNULL_BEGIN

// Notification name for disconnect scrcpy request
#define ScrcpyRequestDisconnectNotification @"ScrcpyRequestDisconnectNotification"

// C function declaration
#ifdef __cplusplus
extern "C" {
#endif

/**
 * Send a keyboard event to the scrcpy window
 * @param scancode The SDL scancode for the key
 * @param keycode The SDL keycode for the key
 * @param keymod The SDL key modifier flags
 */
void ScrcpySendKeycodeEvent(SDL_Scancode scancode, SDL_Keycode keycode, SDL_Keymod keymod);

#ifdef __cplusplus
}
#endif

@interface ScrcpyADBClient : NSObject
@end

NS_ASSUME_NONNULL_END
