//
//  util-sdl-porting.c
//  scrcpy-module
//
//  v4.0 wraps SDL_CreateWindow and SDL_RenderPresent inside util/sdl.c
//  as sc_sdl_create_window() and sc_sdl_render_present(). We rename those
//  inside the included translation unit (sdl.c) to _orig and re-export
//  thin wrappers from this file:
//    - sc_sdl_create_window: emit ScrcpyStatusSDLWindowCreated to iOS app
//      after the SDL window is up.
//    - sc_sdl_render_present: skip the SDL present in the hardware-decoded
//      path (frames are composited via AVSampleBufferDisplayLayer at the
//      iOS app layer), but still flush the renderer command queue so
//      SDL_DestroyTexture can free pending commands.
//
//  Created by Ethan in 2026 for the v4.0 upgrade.
//

#include <SDL3/SDL.h>

#include "scrcpy-porting.h"

int ScrcpyEnableHardwareDecoding(void);

#define sc_sdl_create_window(...)  sc_sdl_create_window_orig(__VA_ARGS__)
#define sc_sdl_render_present(...) sc_sdl_render_present_orig(__VA_ARGS__)

#include "util/sdl.c"

#undef sc_sdl_create_window
#undef sc_sdl_render_present

SDL_Window *
sc_sdl_create_window(const char *title, int64_t x, int64_t y,
                     int64_t width, int64_t height, int64_t flags)
{
    SDL_Window *window =
        sc_sdl_create_window_orig(title, x, y, width, height, flags);
    if (window) {
        ScrcpyUpdateStatus(ScrcpyStatusSDLWindowCreated, "SDL Window Created");
    }
    return window;
}

void
sc_sdl_render_present(SDL_Renderer *renderer)
{
    if (ScrcpyEnableHardwareDecoding() >= 1) {
        // Hardware-decoded frames composited at the iOS app layer.
        // Flush the SDL3 renderer command queue so its internal
        // render_command_generation advances; otherwise SDL_DestroyTexture
        // later accumulates pending commands and leaks memory. Replaces
        // the SDL2-era SDL_UpdateCommandGeneration patch.
        SDL_FlushRenderer(renderer);
        return;
    }
    sc_sdl_render_present_orig(renderer);
}
