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

// Application background state. Written from the main thread (app lifecycle),
// read from scrcpy's decoder/demuxer thread, so it is _Atomic.
static _Atomic(BOOL) bApplicationInBackground = NO;

// Follow remote orientation change feature
static BOOL bFollowRemoteOrientation = NO;
static int lastFrameWidth = 0;
static int lastFrameHeight = 0;
static BOOL lastWasLandscape = NO;

// Notification name for remote orientation change
NSString * const ScrcpyRemoteOrientationChangedNotification = @"ScrcpyRemoteOrientationChangedNotification";

// Render recovery statistics
//
// A full AVSampleBufferDisplayLayer queue is normal back-pressure, not a
// failure: a high-contrast scene change (or any hard cut) produces a burst of
// large frames, and the layer briefly reports !isReadyForMoreMediaData while it
// drains. Dropping those frames is the correct response and the picture keeps
// moving.
//
// Escalating that to [flush] + reset-video is not: flush empties the queue
// (instant black) and reset-video restarts the *server-side encoder*, so
// nothing can be shown until a fresh IDR arrives. If the post-restart keyframe
// burst fills the queue again the cycle repeats, and once ScrcpyTryResetVideo()
// hits its rate limit the picture stays black until the limiter's window
// expires — the reported "black for ~5s, then slowly brightens".
//
// So only escalate on a *sustained* stall: the queue must stay full
// continuously for kStallBeforeRecoverySeconds. A counter of consecutive drops
// cannot express that, because its meaning depends on frame rate (5 frames is
// ~83ms at 60fps but ~200ms at 25fps). Time is the honest unit here.
static int g_consecutiveDropCount = 0;
static int g_totalDropCount = 0;
static CFAbsoluteTime g_lastRecoveryTime = 0;
// Throttle for the display-layer-failed log below. The failure status is sticky
// until the layer is flushed and a frame is accepted again, so without this the
// message prints once per decoded frame — tens of lines a second, straight into
// the redirected log file.
static CFAbsoluteTime g_lastLayerFailLogTime = 0;
static int g_layerFailCountSinceLog = 0;
static const CFAbsoluteTime kLayerFailLogIntervalSeconds = 5.0;
static CFAbsoluteTime g_stallStartTime = 0;  // when the queue first went full (0 = not stalled)
// Start of the current black-picture episode, kept across the flush+reset that
// g_stallStartTime is rebased by, so the recovery log can report the total time
// the user actually spent looking at a black screen.
static CFAbsoluteTime g_episodeStartTime = 0;
static int g_episodeDropCount = 0;   // frames dropped during this episode
static int g_episodeResetCount = 0;  // resets attempted during this episode
// Sustained stall required before restarting the encoder. Comfortably longer
// than the transient bursts a scene change produces, short enough that a real
// decode stall still recovers quickly.
static const CFAbsoluteTime kStallBeforeRecoverySeconds = 2.0;
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

void SetApplicationBackgroundState(BOOL inBackground) {
    bApplicationInBackground = inBackground;
    NSLog(@"[ScrcpyRuntime] SetApplicationBackgroundState → %@", inBackground ? @"background" : @"foreground");
}

// Read the cached background flag. When `update` is true, refresh it from the
// live UIApplication state first (safe to call from any thread). Used by
// decoder-porting.c to decide whether a decode error is an iOS-induced
// VideoToolbox session loss (background) rather than a real stream failure.
bool GetUpdateApplicationBackgroundState(bool update) {
    if (update) {
        bApplicationInBackground =
            (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground);
    }
    return bApplicationInBackground ? true : false;
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

            // Log at most once per kLayerFailLogIntervalSeconds, carrying the
            // number of occurrences suppressed since the last line so a
            // persistent failure is still obvious from its rate.
            CFAbsoluteTime nowFail = CFAbsoluteTimeGetCurrent();
            g_layerFailCountSinceLog++;
            if (nowFail - g_lastLayerFailLogTime >= kLayerFailLogIntervalSeconds) {
                if (g_layerFailCountSinceLog > 1) {
                    NSLog(@"⚠️ [Render] Display layer failed: %@ (x%d in the last %.0fs)",
                          error.localizedDescription, g_layerFailCountSinceLog,
                          kLayerFailLogIntervalSeconds);
                } else {
                    NSLog(@"⚠️ [Render] Display layer failed: %@",
                          error.localizedDescription);
                }
                g_lastLayerFailLogTime = nowFail;
                g_layerFailCountSinceLog = 0;
            }

            [displayLayer flush];

            // The queue was just emptied, so any stall in progress is over.
            // Clearing this matters because g_stallStartTime is process-global
            // and survives both this failure and a later reconnect: left set, a
            // stale start time would make the next full-queue frame look like a
            // multi-second stall and trigger an immediate spurious reset.
            g_consecutiveDropCount = 0;
            g_stallStartTime = 0;
            g_episodeStartTime = 0;
            g_episodeDropCount = 0;
            g_episodeResetCount = 0;

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
        //
        // Tier 1 (the common case): just drop this frame. A scene change fills
        // the queue for a few frames; skipping them lets it drain with no
        // visible interruption.
        //
        // Tier 2 (rare): if the queue has stayed full continuously for
        // kStallBeforeRecoverySeconds, decoding really is stuck and only an
        // encoder restart will recover it.
        if (!displayLayer.isReadyForMoreMediaData) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

            g_consecutiveDropCount++;
            g_totalDropCount++;

            // Mark the start of this stall. Cleared as soon as a frame is
            // accepted, so the duration below always measures one uninterrupted
            // stall rather than an accumulation of unrelated bursts.
            if (g_stallStartTime == 0) {
                g_stallStartTime = now;
            }
            // An episode spans the whole black period including any resets, so
            // it starts with the first stall and is only cleared on recovery.
            if (g_episodeStartTime == 0) {
                g_episodeStartTime = now;
                g_episodeDropCount = 0;
                g_episodeResetCount = 0;
            }
            g_episodeDropCount++;
            CFAbsoluteTime stalledFor = now - g_stallStartTime;

            // Tier 1 diagnostics. Throttled to every 10th consecutive drop:
            // this runs on the decode thread at frame rate, so an unthrottled
            // NSLog here would both flood the log and cost real time in the
            // frame path. The first drop is always logged so the start of an
            // episode is visible.
            if (g_consecutiveDropCount == 1 || g_consecutiveDropCount % 10 == 0) {
                NSLog(@"⚠️ [StallRecovery] Tier1 drop: consecutive=%d episode=%d "
                      @"total=%d stalled=%.2fs (threshold %.1fs)",
                      g_consecutiveDropCount, g_episodeDropCount, g_totalDropCount,
                      stalledFor, kStallBeforeRecoverySeconds);
            }

            // Only a sustained stall justifies restarting the encoder.
            if (stalledFor >= kStallBeforeRecoverySeconds &&
                now - g_lastRecoveryTime > kRecoveryCooldownSeconds) {
                // Ask the limiter up-front whether this reset can actually go
                // through, so a refusal is visible instead of silent. This only
                // reads the limiter state; ScrcpyTryResetVideo() below still
                // makes the real decision.
                const char *blockReason = "ready";
                NSTimeInterval blockedFor = ScrcpyResetVideoBlockedFor(&blockReason);

                g_episodeResetCount++;
                NSLog(@"🔄 [StallRecovery] Tier2 escalate: stalled=%.2fs "
                      @"episode=%.2fs drops=%d resets=%d -> flush + reset",
                      stalledFor, now - g_episodeStartTime, g_episodeDropCount,
                      g_episodeResetCount);

                // If the limiter will refuse this reset, say so and say for how
                // long: that wait is exactly how much longer the picture stays
                // black, which is the number to compare against the reported
                // "~5 seconds".
                if (blockedFor > 0) {
                    NSLog(@"⏳ [StallRecovery] Reset blocked by %s, ~%.1fs to wait "
                          @"— picture stays black until then",
                          blockReason, blockedFor);
                }

                [displayLayer flush];
                ScrcpyTryResetVideo();
                g_lastRecoveryTime = now;
                g_consecutiveDropCount = 0;
                // Restart the stall clock so the next escalation is judged from
                // this recovery, not from the original stall — otherwise every
                // later frame would still read as "stalled >= threshold" and
                // fire a reset on each cooldown expiry.
                g_stallStartTime = now;
            }
            return;  // Skip this frame
        }

        // The queue accepted a frame: this stall (if any) is over.
        if (g_episodeStartTime != 0) {
            NSLog(@"✅ [StallRecovery] recovered after %.2fs "
                  @"(dropped %d frames, %d reset(s))",
                  CFAbsoluteTimeGetCurrent() - g_episodeStartTime,
                  g_episodeDropCount, g_episodeResetCount);
            g_episodeStartTime = 0;
            g_episodeDropCount = 0;
            g_episodeResetCount = 0;
        }
        g_consecutiveDropCount = 0;
        g_stallStartTime = 0;

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
