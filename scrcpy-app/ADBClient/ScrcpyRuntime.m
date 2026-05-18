//
//  ScrcpyRuntime.m
//  Scrcpy Remote
//
//  Created by Ethan on 1/1/25.
//
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>
#import <libavutil/frame.h>
#import "ScrcpyRuntime.h"
#import "scrcpy-porting.h"
#import "app/config.h"

typedef enum : NSUInteger {
    // 0: disable hardware decoding
    ScrcpyHardwareDecodingDisabled = 0,
    // 1: enable hardware decoding with layer render
    ScrcpyHardwareDecodingLayerRender = 1,
    // 2: enable hardware decoding with sdl render
    ScrcpyHardwareDecodingSDLRender = 2,
} ScrcpyHardwareDecodingType;

static ScrcpyHardwareDecodingType bScrcpyHardwareDecodingEnabled = ScrcpyHardwareDecodingLayerRender;

// Follow remote orientation change feature
static BOOL bFollowRemoteOrientation = NO;
static int lastFrameWidth = 0;
static int lastFrameHeight = 0;
static BOOL lastWasLandscape = NO;

// Notification name for remote orientation change
NSString * const ScrcpyRemoteOrientationChangedNotification = @"ScrcpyRemoteOrientationChangedNotification";

// Render recovery statistics
static int g_consecutiveDropCount = 0;
static int g_totalDropCount = 0;
static CFAbsoluteTime g_lastRecoveryTime = 0;
static const int kMaxConsecutiveDropsBeforeRecovery = 5;  // Trigger recovery after this many consecutive drops
static const CFAbsoluteTime kRecoveryCooldownSeconds = 1.0;  // Minimum time between recovery attempts

const char *ScrcpyCoreVersion(void)
{
    return SCRCPY_VERSION;
}

float ScrcpyRenderScreenScale(void)
{
    return [UIScreen mainScreen].nativeScale;
}

void SetScrcpyHardwareDecodingEnabled(BOOL enabled) {
    bScrcpyHardwareDecodingEnabled = enabled ? ScrcpyHardwareDecodingLayerRender : ScrcpyHardwareDecodingDisabled;
}

void SetScrcpyFollowRemoteOrientation(BOOL enabled) {
    bFollowRemoteOrientation = enabled;
    // Reset tracking state when setting changes
    lastFrameWidth = 0;
    lastFrameHeight = 0;
    lastWasLandscape = NO;
    NSLog(@"📱 [ScrcpyRuntime] Follow remote orientation: %@", enabled ? @"YES" : @"NO");
}

void ResetScrcpyOrientationTracking(void) {
    // Reset orientation tracking state (called when disconnecting)
    lastFrameWidth = 0;
    lastFrameHeight = 0;
    lastWasLandscape = NO;
    NSLog(@"📱 [ScrcpyRuntime] Orientation tracking state reset");
}

BOOL IsRemoteOrientationKnown(void) {
    return (lastFrameWidth > 0 && lastFrameHeight > 0);
}

BOOL GetCurrentRemoteOrientation(int *outWidth, int *outHeight) {
    if (outWidth) *outWidth = lastFrameWidth;
    if (outHeight) *outHeight = lastFrameHeight;

    // Return YES if landscape (width > height), NO otherwise
    if (lastFrameWidth > 0 && lastFrameHeight > 0) {
        return (lastFrameWidth > lastFrameHeight);
    }
    return NO; // Unknown, default to portrait
}

static void CheckAndNotifyOrientationChange(int width, int height) {
    if (!bFollowRemoteOrientation) {
        return;
    }

    // Skip if dimensions are invalid
    if (width <= 0 || height <= 0) {
        return;
    }

    // Determine if current frame is landscape (width > height)
    BOOL isLandscape = (width > height);

    // Check if this is the first frame or if orientation changed
    BOOL isFirstFrame = (lastFrameWidth == 0 && lastFrameHeight == 0);
    BOOL orientationChanged = (!isFirstFrame && isLandscape != lastWasLandscape);

    // Update tracking state
    lastFrameWidth = width;
    lastFrameHeight = height;
    lastWasLandscape = isLandscape;

    // Notify on first frame OR when orientation changed
    // First frame notification ensures we set correct initial orientation
    if (isFirstFrame || orientationChanged) {
        NSLog(@"📱 [ScrcpyRuntime] Remote orientation %@: %@ (%dx%d)",
              isFirstFrame ? @"initial" : @"changed",
              isLandscape ? @"Landscape" : @"Portrait", width, height);

        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *userInfo = @{
                @"isLandscape": @(isLandscape),
                @"width": @(width),
                @"height": @(height),
                @"isFirstFrame": @(isFirstFrame)
            };
            [[NSNotificationCenter defaultCenter] postNotificationName:ScrcpyRemoteOrientationChangedNotification
                                                                object:nil
                                                              userInfo:userInfo];
        });
    }
}

int ScrcpyEnableHardwareDecoding(void)
{
    // To enable hardware decoding if target not simulator
#if TARGET_OS_SIMULATOR
    return ScrcpyHardwareDecodingDisabled
#else
    return (int)bScrcpyHardwareDecodingEnabled;
#endif
}

float ScrcpyAudioVolumeScale(float update_scale)
{
    static float volume_scale = 1.0f;
    volume_scale = update_scale > 0 ? update_scale : volume_scale;
    return volume_scale;
}

AVSampleBufferDisplayLayer *GetSampleBufferDisplayLayer(void)
{
    @autoreleasepool {
        static AVSampleBufferDisplayLayer *displayLayer = nil;
        if (displayLayer != nil && displayLayer.superlayer != nil) {
            return displayLayer;
        }
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                [displayLayer removeFromSuperlayer];
                displayLayer = [AVSampleBufferDisplayLayer layer];
                displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
                
                UIWindow *sdlWindow = GetCurrentWindowScene().keyWindow;
                
                // Skip when no SDL window found
                if (sdlWindow == nil) {
                    return;
                }
                
                displayLayer.frame = sdlWindow.rootViewController.view.bounds;
                [sdlWindow.rootViewController.view.layer addSublayer:displayLayer];
                sdlWindow.rootViewController.view.backgroundColor = UIColor.blackColor;
                // sometimes failed to set background color, so we append to next runloop
                displayLayer.backgroundColor = UIColor.blackColor.CGColor;
            }
        });

        return displayLayer;
    }
}

void RenderPixelBufferFrame(CVPixelBufferRef pixelBuffer) {
    @autoreleasepool {
        if (pixelBuffer == NULL) { return; }

        // Check for orientation change based on frame dimensions
        int frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
        int frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
        CheckAndNotifyOrientationChange(frameWidth, frameHeight);

        // Get rendering layer first to check its status
        AVSampleBufferDisplayLayer *displayLayer = GetSampleBufferDisplayLayer();
        if (!displayLayer) {
            return;
        }

        // Check 1: Handle render failure status
        AVQueuedSampleBufferRenderingStatus status = displayLayer.status;
        if (status == AVQueuedSampleBufferRenderingStatusFailed) {
            NSError *error = displayLayer.error;
            NSLog(@"⚠️ [Render] Display layer failed: %@", error.localizedDescription);

            [displayLayer flush];

            // Request video reset with cooldown to avoid spam
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - g_lastRecoveryTime > kRecoveryCooldownSeconds) {
                NSLog(@"🔄 [Render] Requesting video reset after failure");
                ScrcpyTryResetVideo();
                g_lastRecoveryTime = now;
            }
            return;  // Skip this frame, wait for recovery
        }

        // Check 2: Handle buffer full (decoder overload in high-contrast scenes)
        if (!displayLayer.isReadyForMoreMediaData) {
            g_consecutiveDropCount++;
            g_totalDropCount++;

            // Log periodically to avoid spam
            if (g_consecutiveDropCount == 1 || g_consecutiveDropCount % 30 == 0) {
                NSLog(@"⚠️ [Render] Buffer full, dropped %d frames (total: %d)",
                      g_consecutiveDropCount, g_totalDropCount);
            }

            // Too many consecutive drops indicate decoder cannot keep up
            if (g_consecutiveDropCount >= kMaxConsecutiveDropsBeforeRecovery) {
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - g_lastRecoveryTime > kRecoveryCooldownSeconds) {
                    NSLog(@"🔄 [Render] Too many dropped frames (%d), requesting recovery",
                          g_consecutiveDropCount);
                    [displayLayer flush];
                    ScrcpyTryResetVideo();
                    g_lastRecoveryTime = now;
                    g_consecutiveDropCount = 0;
                }
            }
            return;  // Skip this frame
        }

        // Reset consecutive drop count on successful buffer availability
        g_consecutiveDropCount = 0;

        // Create sample buffer for rendering
        CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
        CMVideoFormatDescriptionRef videoInfo = NULL;
        OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &videoInfo);

        if (result != noErr || videoInfo == NULL) {
            NSLog(@"❌ [Render] Failed to create video format description: %d", (int)result);
            return;
        }

        CMSampleBufferRef sampleBuffer = NULL;
        result = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, videoInfo, &timing, &sampleBuffer);

        if (sampleBuffer == NULL) {
            CFRelease(videoInfo);
            return;
        }

        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);

        // Render the sample buffer
        if (@available(iOS 17.0, *)) {
            [displayLayer.sampleBufferRenderer enqueueSampleBuffer:sampleBuffer];
        } else {
            [displayLayer enqueueSampleBuffer:sampleBuffer];
        }

        // Post-render check: handle any failure that occurred during enqueue
        if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            NSLog(@"⚠️ [Render] Render failed after enqueue, flushing");
            [displayLayer flush];
        }

        CFRelease(videoInfo);
        CFRelease(sampleBuffer);
    }
}

AVFrame * ScrcpyHandleFrame(AVFrame *frame) {
    if (!frame) {
        return frame;
    }
    
    // Get CVImageBufferRef
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)frame->data[3];
    if (!pixelBuffer) {
        return frame;
    }
   
    if (ScrcpyEnableHardwareDecoding() == ScrcpyHardwareDecodingLayerRender) {
        RenderPixelBufferFrame(pixelBuffer);
        return frame;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // Set frame format to YUV420P
    frame->format = AV_PIX_FMT_YUV420P;
    
    uint8_t* y_plane = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    int y_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    
    uint8_t* uv_plane = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    int uv_stride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    
    static uint8_t* u_plane = NULL;
    if (!u_plane) u_plane = (uint8_t*)malloc((frame->width * frame->height) / 4);
    static uint8_t* v_plane = NULL;
    if (!v_plane) v_plane = (uint8_t*)malloc((frame->width * frame->height) / 4);

    if (!u_plane || !v_plane) {
        if (u_plane) free(u_plane);
        if (v_plane) free(v_plane);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return frame;
    }
    
    for (int i = 0; i < frame->height/2; i++) {
        for (int j = 0; j < frame->width/2; j++) {
            u_plane[i * (frame->width/2) + j] = uv_plane[i * uv_stride + j * 2];
            v_plane[i * (frame->width/2) + j] = uv_plane[i * uv_stride + j * 2 + 1];
        }
    }

    // Update to frame
    frame->data[0] = y_plane;
    frame->data[1] = u_plane;
    frame->data[2] = v_plane;
    frame->linesize[0] = y_stride;
    frame->linesize[1] = frame->width / 2;
    frame->linesize[2] = frame->width / 2;
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // Release frame->data[3] to prevent memory leak
    frame->data[3] = NULL;

    return frame;
}
