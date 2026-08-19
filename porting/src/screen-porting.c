//
//  screen-porting.c
//  scrcpy-module
//
//  Created by Ethan on 2022/6/3.
//  Updated 2026 for scrcpy v4.0 + SDL3:
//   - SDL_CreateWindow hijack moved out to util-sdl-porting.c (screen.c
//     no longer calls SDL_CreateWindow directly; it goes through
//     sc_sdl_create_window in util/sdl.c).
//   - SDL2 SDL_RenderSetScale renamed to SDL3 SDL_SetRenderScale.
//   - sc_screen->display.renderer flattened to sc_screen->renderer.
//   - SDL_CLIPBOARDUPDATE renamed to SDL_EVENT_CLIPBOARD_UPDATE.
//   - SDL_SetWindowFullscreen now takes a bool and returns bool.
//   - sc_screen_handle_event's second argument is `const SDL_Event *`.
//

#include "stdbool.h"
#include <string.h>

#include <SDL3/SDL.h>

#include "scrcpy-porting.h"

static void SDL_DestroyWindow_hijack(SDL_Window *window);

#define sc_screen_init(...)            sc_screen_init_orig(__VA_ARGS__)
#define sc_screen_handle_event(...)    sc_screen_handle_event_hijack(__VA_ARGS__)
#define sc_screen_destroy(...)         sc_screen_destroy_orig(__VA_ARGS__)
#define sc_fps_counter_destroy(...)    sc_fps_counter_destroy_hijack(__VA_ARGS__)
#define SDL_DestroyWindow(w)           SDL_DestroyWindow_hijack(w)

#include "screen.c"

#undef sc_screen_init
#undef sc_screen_handle_event
#undef sc_screen_destroy
#undef sc_fps_counter_destroy
#undef SDL_DestroyWindow

// Lifecycle guard state for the reused sc_screen / sc_fps_counter. Defined here
// because sc_screen_init() below is the first user; the rationale is documented
// at the destroy hijacks near the bottom of this file.
static struct sc_screen *g_screen_ptr = NULL;
static bool g_screen_destroyed = false;     // screen primitives torn down
static bool g_fps_counter_destroyed = false; // fps_counter primitives torn down

struct sc_screen *
sc_screen_current_screen(struct sc_screen *screen) {
    static struct sc_screen *current_screen;
    if (screen != NULL) {
        current_screen = screen;
    }
    return current_screen;
}

__attribute__((weak))
float ScrcpyRenderScreenScale(void) {
    return 2.f;
}

bool
sc_screen_init(struct sc_screen *screen,
               const struct sc_screen_params *params) {
    // Track this screen before initialising so that the fps_counter hijack can
    // recognise it on sc_screen_init_orig()'s own error paths (which call
    // sc_fps_counter_destroy() directly).
    g_screen_ptr = screen;
    g_screen_destroyed = false;
    g_fps_counter_destroyed = false;

    bool ret = sc_screen_init_orig(screen, params);
    if (!ret) {
        // Initialisation failed and already unwound whatever it had created.
        // Mark the primitives as gone so a later teardown does not destroy
        // handles this run never successfully built.
        g_screen_destroyed = true;
        g_fps_counter_destroyed = true;
        return ret;
    }

    // Apply device pixel scale to the SDL3 renderer.
    float scale = ScrcpyRenderScreenScale();
    SDL_SetRenderScale(screen->renderer, scale, scale);

    // Save current screen pointer
    sc_screen_current_screen(screen);

    return ret;
}

void
sc_screen_handle_event(struct sc_screen *screen, const SDL_Event *event) {
    // Handle Clipboard Event to Sync Clipboard to Remote
    if (event->type == SDL_EVENT_CLIPBOARD_UPDATE) {
        char *text = SDL_GetClipboardText();
        if (!text) {
            LOGW("Could not get clipboard text: %s", SDL_GetError());
            return;
        }

        char *text_dup = strdup(text);
        SDL_free(text);
        if (!text_dup) {
            LOGW("Could not strdup input text");
            return;
        }

        struct sc_control_msg msg;
        msg.type = SC_CONTROL_MSG_TYPE_SET_CLIPBOARD;
        msg.set_clipboard.sequence = SC_SEQUENCE_INVALID;
        msg.set_clipboard.text = text_dup;
        msg.set_clipboard.paste = false;

        if (!sc_controller_push_msg(screen->im.controller, &msg)) {
            free(text_dup);
            LOGW("Could not request 'set device clipboard'");
            return;
        }
        return;
    }

    sc_screen_handle_event_hijack(screen, event);
}

void SDL_DestroyWindow(SDL_Window *window);
void SDL_DestroyWindow_hijack(SDL_Window *window) {
    // Leaving fullscreen before destroying the window avoids a known
    // crash path on iOS.
    SDL_SetWindowFullscreen(window, false);
    SDL_DestroyWindow(window);
}

// Lifecycle guard for the sc_screen owned by scrcpy()'s static `struct scrcpy`.
//
// On iOS scrcpy() is re-entered once per connection in the same process, so the
// screen (and the sc_fps_counter embedded in it) is reused rather than freshly
// zero-initialised. This is the screen-side analogue of the sc_server teardown
// fixed in 15ce734, and it produces the reported
// sc_screen_destroy -> sc_fps_counter_destroy -> sc_mutex_destroy ->
// SDL_DestroyMutex EXC_BREAKPOINT.
//
// sc_mutex_destroy()/sc_cond_destroy() call SDL_DestroyMutex()/
// SDL_DestroyCondition() without resetting the handles, so any second teardown
// of the same struct passes freed handles back to SDL. scrcpy() guards the
// destroy with `screen_initialized`, but that flag is a fresh local on every
// run while the struct behind it is not: a run that fails after
// sc_screen_init() succeeded, and a subsequent run that tears down again, both
// reach the destructor with the same already-destroyed primitives.
//
// Fix, entirely in the porting layer (no changes to scrcpy/ or SDL): track
// which screen is live, run each destructor exactly once per initialisation,
// and NULL the SDL handles afterwards so a repeat teardown is a no-op.
//
// scrcpy() runs on the main thread and each run is strictly sequential, so a
// single non-atomic guard is sufficient.

// Handle sc_fps_counter_destroy to make it idempotent.
//
// Called both directly by sc_screen_destroy() (rewritten by the macro above to
// reach this hijack) and, on the error path, by sc_screen_init() itself. The
// counter's mutex/cond must be destroyed exactly once per successful init.
void
sc_fps_counter_destroy(struct sc_fps_counter *counter);
void
sc_fps_counter_destroy_hijack(struct sc_fps_counter *counter) {
    bool tracked = g_screen_ptr && counter == &g_screen_ptr->fps_counter;

    if (tracked && g_fps_counter_destroyed) {
        return; // already torn down for this initialisation
    }

    sc_fps_counter_destroy(counter);

    // Poison the handles so a teardown we do not track cannot double-destroy
    // them either. SDL_DestroyMutex(NULL) / SDL_DestroyCondition(NULL) are
    // documented no-ops.
    counter->mutex.mutex = NULL;
    counter->state_cond.cond = NULL;

    if (tracked) {
        g_fps_counter_destroyed = true;
    }
}

// Handle sc_screen_destroy to make the whole screen teardown idempotent.
//
// Runs the upstream destructor exactly once per initialisation, then NULLs the
// SDL handles it leaves dangling so a repeat teardown of the reused static
// struct cannot hand freed pointers to SDL.
void
sc_screen_destroy_orig(struct sc_screen *screen);
void
sc_screen_destroy(struct sc_screen *screen) {
    bool tracked = (screen == g_screen_ptr);

    if (tracked && g_screen_destroyed) {
        return; // reused static struct, second destroy — nothing left to release
    }

    sc_screen_destroy_orig(screen);

    // The upstream destructor destroys screen->mutex and the embedded
    // fps_counter without resetting them, and frees the SDL window/renderer.
    // Poison everything so a repeat teardown is inert.
    screen->mutex.mutex = NULL;
    screen->renderer = NULL;
    screen->window = NULL;

    if (tracked) {
        g_screen_destroyed = true;
        // The screen is gone; stop tracking its fps_counter.
        g_fps_counter_destroyed = true;
    }
}
