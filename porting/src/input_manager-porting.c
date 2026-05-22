//
//  input_manager-porting.c
//  scrcpy-module
//
//  iOS-specific shim around scrcpy's upstream input_manager.c.
//
//  Problem: on a real touch screen (iPad/iPhone) SDL3 emits FINGER_DOWN +
//  many FINGER_MOTION + FINGER_UP between fingers touching and leaving
//  the screen. scrcpy enqueues each one as an INJECT_TOUCH_EVENT
//  control message; the server then injects them serially with the
//  current SystemClock.uptimeMillis() as event time, so the DOWN -> UP
//  wall-clock gap on the device grows with the number of MOTION
//  events. Once that gap exceeds Android's long-press timeout (default
//  500ms) the OS reports a long-press instead of a tap, which is what
//  users see on v4 + SDL3 (upstream desktop client sends only DOWN/UP
//  for mouse, so it is unaffected).
//
//  Fix: throttle FINGER_MOTION events to ~60 Hz per finger. DOWN and UP
//  always pass through unchanged.
//
//  Created 2026 for the v4.0 upgrade.
//

#include <SDL3/SDL.h>

#define sc_input_manager_process_touch(...) sc_input_manager_process_touch_orig(__VA_ARGS__)

#include "input_manager.c"

#undef sc_input_manager_process_touch

// Per-finger last-forwarded MOTION timestamp (ms). 256 slots is well
// above the ~10 simultaneous fingers iOS ever delivers; SDL_FingerID
// values are tiny on iOS.
#define SCRCPY_TOUCH_SLOTS 256
#define SCRCPY_TOUCH_MOTION_MIN_MS 16

static Uint64 g_last_motion_ms[SCRCPY_TOUCH_SLOTS];

static void
sc_input_manager_process_touch(struct sc_input_manager *im,
                               const SDL_TouchFingerEvent *event) {
    if (event->type == SDL_EVENT_FINGER_MOTION) {
        size_t slot = (size_t)((uintptr_t)event->fingerID) % SCRCPY_TOUCH_SLOTS;
        Uint64 now_ms = SDL_GetTicks();
        Uint64 last = g_last_motion_ms[slot];
        if (last != 0 && now_ms - last < SCRCPY_TOUCH_MOTION_MIN_MS) {
            // Drop this MOTION; the next one or the eventual UP will
            // carry the latest finger position to the device.
            return;
        }
        g_last_motion_ms[slot] = now_ms;
    } else if (event->type == SDL_EVENT_FINGER_DOWN
            || event->type == SDL_EVENT_FINGER_UP) {
        size_t slot = (size_t)((uintptr_t)event->fingerID) % SCRCPY_TOUCH_SLOTS;
        // Reset the throttle window on transitions so the first MOTION
        // after a fresh DOWN is forwarded immediately.
        g_last_motion_ms[slot] = 0;
    }

    sc_input_manager_process_touch_orig(im, event);
}
