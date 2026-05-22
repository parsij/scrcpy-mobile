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
#define SDL_DestroyWindow(w)           SDL_DestroyWindow_hijack(w)

#include "screen.c"

#undef sc_screen_init
#undef sc_screen_handle_event
#undef SDL_DestroyWindow

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
    bool ret = sc_screen_init_orig(screen, params);

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
