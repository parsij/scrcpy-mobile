//
//  texture-porting.c
//  scrcpy-module
//
//  In v4.0, the YUV-upload path moved from display.c to texture.c. We
//  hijack SDL_UpdateYUVTexture so the hardware-decoded path can skip the
//  CPU-side upload to an SDL texture (the frame is being rendered through
//  AVSampleBufferDisplayLayer in the iOS app layer).
//
//  Created by Ethan in 2026 for the v4.0 upgrade.
//  Replaces the old porting/src/display-porting.c.
//

#include <SDL3/SDL.h>

int ScrcpyEnableHardwareDecoding(void);

static bool SDL_UpdateYUVTexture_hijack(SDL_Texture *texture,
                                        const SDL_Rect *rect,
                                        const Uint8 *Yplane, int Ypitch,
                                        const Uint8 *Uplane, int Upitch,
                                        const Uint8 *Vplane, int Vpitch);

#define SDL_UpdateYUVTexture(...) SDL_UpdateYUVTexture_hijack(__VA_ARGS__)

#include "texture.c"

#undef SDL_UpdateYUVTexture

static bool
SDL_UpdateYUVTexture_hijack(SDL_Texture *texture,
                            const SDL_Rect *rect,
                            const Uint8 *Yplane, int Ypitch,
                            const Uint8 *Uplane, int Upitch,
                            const Uint8 *Vplane, int Vpitch)
{
    if (ScrcpyEnableHardwareDecoding() >= 1) {
        // For hardware decoding with layer render, we skip the SDL upload.
        return true;
    }
    return SDL_UpdateYUVTexture(texture, rect, Yplane, Ypitch,
                                Uplane, Upitch, Vplane, Vpitch);
}
