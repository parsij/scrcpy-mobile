//
//  scrcpy-porting.c
//  scrcpy-mobile
//
//  Created by Ethan on 2022/6/2.
//

#include <SDL3/SDL.h>

#include "scrcpy-porting.h"

static bool SDL_Init_hijack(SDL_InitFlags flags);

#define sc_server_init(...)     sc_server_init_hijack(__VA_ARGS__)
//#define sc_delay_buffer_init(...)     sc_delay_buffer_init_hijack(__VA_ARGS__)
#define SDL_Init(f)     SDL_Init_hijack(f)

#include "scrcpy.c"

#undef sc_server_init
//#undef sc_delay_buffer_init
#undef SDL_Init

__attribute__((weak))
void ScrcpyUpdateStatus(enum ScrcpyStatus status, const char *message) {
    printf("ScrcpyUpdateStatus: %d\n", status);
}

static void
sc_server_on_connection_failed_hijack(struct sc_server *server, void *userdata) {
    sc_server_on_connection_failed(server, userdata);

    // Notify update status
    ScrcpyUpdateStatus(ScrcpyStatusConnectingFailed, "Scrcpy connect failed");
}

static void
sc_server_on_disconnected_hijack(struct sc_server *server, void *userdata) {
    sc_server_on_disconnected(server, userdata);

    // Fixed here, send quit event
    SDL_Event event;
    event.type = SDL_EVENT_QUIT;
    SDL_PushEvent(&event);

    // Notify update status
    ScrcpyUpdateStatus(ScrcpyStatusDisconnected, "Scrcpy disconnected");
}

static void
sc_server_on_connected_hijack(struct sc_server *server, void *userdata) {
    sc_server_on_connected(server, userdata);

    // Notify update status
    ScrcpyUpdateStatus(ScrcpyStatusConnected, "Scrcpy connected");
}

// Handle sc_server_init to change cbs->on_disconnected callback
// in order to quit normally when occur some unexpect network close like in sleep mode
bool
sc_server_init(struct sc_server *server, const struct sc_server_params *params,
               const struct sc_server_callbacks *cbs, void *cbs_userdata);
bool
sc_server_init_hijack(struct sc_server *server, const struct sc_server_params *params,
              const struct sc_server_callbacks *cbs, void *cbs_userdata) {
    static const struct sc_server_callbacks cbs_fixed = {
        .on_connection_failed = sc_server_on_connection_failed_hijack,
        .on_connected = sc_server_on_connected_hijack,
        .on_disconnected = sc_server_on_disconnected_hijack,
    };
    return sc_server_init(server, params, &cbs_fixed, cbs_userdata);
}

// Handle sc_delay_buffer_init to reset deley_buffer stopped status
// this can fix the issue: cannot continue video and audio buffer after re-connect
// TODO: Temperary disable this fix, need to find a better way to fix this issue
//void
//sc_delay_buffer_init(struct sc_delay_buffer *db, sc_tick delay,
//                            bool first_frame_asap);
//void
//sc_delay_buffer_init_hijack(struct sc_delay_buffer *db, sc_tick delay,
//                     bool first_frame_asap) {
//    sc_delay_buffer_init(db, delay, first_frame_asap);
//    db->stopped = false;
//}

// Handle SDL_Init to post setup key window.
// SDL3 changed SDL_Init to return bool (true on success) and take SDL_InitFlags.
static bool SDL_Init_hijack(SDL_InitFlags flags) {
    bool ok = SDL_Init(flags);
    if (ok) {
        ScrcpyUpdateStatus(ScrcpyStatusSDLInited, "SDL Inited");
    }
    return ok;
}