//
//  input_manager-porting.c
//  scrcpy-module
//
//  iOS / SDL3 fixup: SDL3's iOS backend reports pressureForTouch: ==
//  touch.force, which is always 0.0 on devices without 3D / Force
//  Touch hardware. Every FINGER_DOWN / MOTION then reaches scrcpy with
//  pressure = 0.0, and Android's MotionEvent.obtain(...,pressure=0,...)
//  is interpreted by some apps as a hover / non-contact, so quick taps
//  register as long-presses. SDL2's iOS backend used to fall back to
//  1.0 for the same input, which is why the regression only appeared
//  after the SDL2 -> SDL3 upgrade.
//
//  Implementation: install an SDL_EventFilter that rewrites
//  event.tfinger.pressure on FINGER_DOWN / MOTION before any scrcpy
//  code consumes the event. SDL_EVENT_FINGER_UP keeps its upstream
//  pressure (0.0).
//
//  Why not the usual `#define foo foo_orig` + `#include "input_manager.c"`
//  hijack on sc_input_manager_process_touch? Because that function is
//  static and is only called from another static (the dispatcher) in
//  the same TU — the rename catches both the definition AND the call
//  site, so an external wrapper of the original name is never reached.
//  Patching the SDL_Event at the source bypasses that entirely.
//

#include <SDL3/SDL.h>
#include <stdio.h>

// Wrap upstream sc_input_manager_init so we can install our event
// watcher at a known-safe time (post SDL_Init).
#define sc_input_manager_init sc_input_manager_init_orig

#include "input_manager.c"

#undef sc_input_manager_init

static bool SDLCALL sc_finger_pressure_watch(void *userdata, SDL_Event *event) {
    (void)userdata;

    // Promote SDL3's FINGER_CANCELED to FINGER_UP. scrcpy's
    // input_manager dispatcher (input_manager.c:1189-1192) only handles
    // DOWN / UP / MOTION explicitly; CANCELED falls through silently,
    // which leaves the server-side virtual finger in the DOWN state
    // forever. iOS triggers CANCELED whenever a system gesture
    // (Slide Over edge, control center, incoming alert, multi-finger
    // recognizer conflict) steals the touch from us, so this happens
    // surprisingly often during regular taps.
    if (event->type == SDL_EVENT_FINGER_CANCELED) {
        event->type = SDL_EVENT_FINGER_UP;
        event->tfinger.type = SDL_EVENT_FINGER_UP;
        event->tfinger.pressure = 0.0f;
        return true;
    }

    if (event->type == SDL_EVENT_FINGER_DOWN ||
        event->type == SDL_EVENT_FINGER_MOTION) {
        if (event->tfinger.pressure <= 0.0f) {
            event->tfinger.pressure = 1.0f;
        }
    }
    return true;
}

static bool g_finger_watch_installed = false;

void
sc_input_manager_init(struct sc_input_manager *im,
                      const struct sc_input_manager_params *params) {
    sc_input_manager_init_orig(im, params);

    // First call installs the watcher. SDL3 hooks are FIFO so this
    // runs before any downstream consumer (input_manager dispatcher,
    // mouse_sdk's process_touch, etc.) sees the event.
    if (!g_finger_watch_installed) {
        g_finger_watch_installed = true;
        SDL_AddEventWatch(sc_finger_pressure_watch, NULL);
        printf("🖐️ finger-pressure SDL_EventWatch installed\n");
        fflush(stdout);
    }
}
