//
//  ScrcpyRuntime.h
//  Scrcpy Remote
//
//  Created by Ethan on 1/1/25.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "ScrcpyClientWrapper.h"

// Notification posted when remote device orientation changes
// userInfo contains: @"isLandscape": @(BOOL), @"width": @(int), @"height": @(int)
extern NSString * const ScrcpyRemoteOrientationChangedNotification;

float ScrcpyAudioVolumeScale(float update_scale);
const char *ScrcpyCoreVersion(void);
void SetScrcpyHardwareDecodingEnabled(BOOL enabled);
void SetScrcpyFollowRemoteOrientation(BOOL enabled);
void ResetScrcpyOrientationTracking(void);

// Get current remote orientation state (returns YES if landscape, NO if portrait or unknown)
// Also returns frame dimensions via out parameters (pass NULL if not needed)
BOOL GetCurrentRemoteOrientation(int *outWidth, int *outHeight);
BOOL IsRemoteOrientationKnown(void);

// Request video reset (sends Ctrl+Shift+R to scrcpy to request a new keyframe)
// Used for recovering from render failures or decoder overload
void ScrcpyTryResetVideo(void);
