//
//  input_manager-porting.c
//  scrcpy-module
//
//  iOS / SDL3 fixup: normalise the per-finger pressure value before
//  the upstream input_manager forwards it to scrcpy-server.
//
//  SDL3's iOS backend implements pressureForTouch: as simply
//  `return (float)touch.force` (src/video/uikit/SDL_uikitview.m:329).
//  iPads / iPhones without Force Touch hardware always report
//  touch.force == 0.0, so every FINGER_DOWN / MOTION arrives at scrcpy
//  with pressure=0.0. The server then calls Android's
//  MotionEvent.obtain(..., pressure=0, ...); some Android versions /
//  ROMs treat a DOWN with pressure 0 as a hover / non-contact, which
//  combined with the burst of MOTION events makes a single tap
//  register as a long-press. SDL2's iOS backend used to fall back to
//  pressure = 1.0 for the same input, which is why this regression
//  only appeared after the SDL2 -> SDL3 upgrade.
//
//  Fix: synthesise pressure = 1.0 for DOWN / MOTION and 0.0 for UP
//  whenever the SDL3 backend gives us a zero (i.e. no real force
//  data). Real force values (e.g. on a future Force-Touch capable
//  device) are passed through untouched.
//

#include <SDL3/SDL.h>

#define sc_input_manager_process_touch(...) sc_input_manager_process_touch_orig(__VA_ARGS__)

#include "input_manager.c"

#undef sc_input_manager_process_touch

static void
sc_input_manager_process_touch(struct sc_input_manager *im,
                               const SDL_TouchFingerEvent *event) {
    // Patch pressure in-place via a local copy: the upstream callee
    // only reads event->pressure.
    SDL_TouchFingerEvent fixed = *event;
    if (fixed.pressure <= 0.0f) {
        fixed.pressure = (event->type == SDL_EVENT_FINGER_UP) ? 0.0f : 1.0f;
    }
    sc_input_manager_process_touch_orig(im, &fixed);
}
