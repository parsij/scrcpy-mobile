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
#define sc_server_start(...)    sc_server_start_hijack(__VA_ARGS__)
#define sc_server_join(...)     sc_server_join_hijack(__VA_ARGS__)
#define sc_server_destroy(...)  sc_server_destroy_hijack(__VA_ARGS__)
//#define sc_delay_buffer_init(...)     sc_delay_buffer_init_hijack(__VA_ARGS__)
#define SDL_Init(f)     SDL_Init_hijack(f)

#include "scrcpy.c"

#undef sc_server_init
#undef sc_server_start
#undef sc_server_join
#undef sc_server_destroy
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
// Lifecycle guard for the single sc_server owned by scrcpy()'s static
// `struct scrcpy`. On iOS scrcpy() is re-entered once per connection in the
// same process, so we cannot rely on fresh zero-initialised state and must
// track by hand whether the server thread was started and whether the struct
// has already been torn down.
//
// scrcpy() runs on the main thread (ScrcpyADBClient startScrcpy:), and each
// run is strictly sequential, so a single non-atomic guard is sufficient.
static struct sc_server *g_server_ptr = NULL;
static bool g_server_started = false;   // sc_server_start() succeeded, thread live
static bool g_server_joined = false;    // server thread has been joined
static bool g_server_destroyed = false; // primitives have been torn down

bool
sc_server_init_hijack(struct sc_server *server, const struct sc_server_params *params,
              const struct sc_server_callbacks *cbs, void *cbs_userdata) {
    static const struct sc_server_callbacks cbs_fixed = {
        .on_connection_failed = sc_server_on_connection_failed_hijack,
        .on_connected = sc_server_on_connected_hijack,
        .on_disconnected = sc_server_on_disconnected_hijack,
    };

    // scrcpy() keeps `struct scrcpy` in a static, and on iOS scrcpy() is run
    // once per connection inside the same process (instead of once per
    // process). The owned pointers below therefore still hold the values left
    // by the previous run. sc_server_init() only clears them after
    // sc_adb_init() succeeds, so a failure there would leave them dangling for
    // sc_server_destroy() to free a second time. Clear them up-front so the
    // struct always starts from a known state.
    server->serial = NULL;
    server->device_socket_name = NULL;
    server->video_socket = SC_SOCKET_NONE;
    server->audio_socket = SC_SOCKET_NONE;
    server->control_socket = SC_SOCKET_NONE;

    bool ok = sc_server_init(server, params, &cbs_fixed, cbs_userdata);
    if (ok) {
        // A fresh, fully initialised server: reset the lifecycle guard so the
        // primitives created inside sc_server_init() (mutex/cond/intr) are
        // considered live again for this run.
        g_server_ptr = server;
        g_server_started = false;
        g_server_joined = false;
        g_server_destroyed = false;
    }
    return ok;
}

// Handle sc_server_start to record that the server thread is live, so the
// join/destroy hijacks know a thread exists that must be joined.
bool
sc_server_start(struct sc_server *server);
bool
sc_server_start_hijack(struct sc_server *server) {
    bool ok = sc_server_start(server);
    if (ok && server == g_server_ptr) {
        g_server_started = true;
        g_server_joined = false;
    }
    return ok;
}

// Handle sc_server_join to make joining idempotent. scrcpy() joins the thread
// at `end:` (when server_started), and sc_server_destroy_hijack() also needs to
// join to close the destroy-before-join race. sc_thread_join()/SDL_WaitThread()
// must run exactly once per thread, so funnel both callers through this guard.
void
sc_server_join(struct sc_server *server);
void
sc_server_join_hijack(struct sc_server *server) {
    if (server == g_server_ptr) {
        if (!g_server_started || g_server_joined) {
            return; // never started, or already joined — nothing to do
        }
        sc_server_join(server);
        g_server_joined = true;
        return;
    }
    sc_server_join(server);
}

// Handle sc_server_destroy to make the whole teardown race-free and idempotent.
//
// Two defects converge here on iOS, where scrcpy() reuses a static
// `struct scrcpy` across connections:
//
//  1. Double-free / double-destroy. scrcpy() calls sc_server_destroy()
//     unconditionally at `end:`, and the upstream destructor frees serial /
//     device_socket_name and destroys mutex/cond/intr without resetting any of
//     them. A second teardown on the reused struct then double-frees the heap
//     pointers and calls SDL_DestroyMutex()/SDL_DestroyCondition() on already
//     freed handles (SIGTRAP inside SDL_DestroyMutex).
//
//  2. Use-after-free race. The sc_server_join() right before the destroy is
//     guarded by `server_started`, but the destroy itself is not. If the run
//     took an early `goto end` after the server thread was started, the main
//     thread can reach sc_intr_destroy() -> sc_mutex_destroy() while
//     run_server() is still using intr->mutex. Low-memory conditions widen this
//     window (slower thread teardown), which is why it reproduces under memory
//     pressure.
//
// Fix: join the server thread first if it was started and not yet joined, then
// free the owned pointers and NULL them, run the upstream destructor exactly
// once, and poison the SDL primitive handles so any repeat teardown is a no-op.
void
sc_server_destroy(struct sc_server *server);
void
sc_server_destroy_hijack(struct sc_server *server) {
    bool tracked = (server == g_server_ptr);

    // If we already tore this server down (reused static, second destroy),
    // there is nothing left to release. Just clear the owned pointers defensively.
    if (tracked && g_server_destroyed) {
        server->serial = NULL;
        server->device_socket_name = NULL;
        return;
    }

    // Ensure run_server() has fully exited before we destroy the mutex/cond/intr
    // it may still be using. scrcpy() only joins when `server_started`, but the
    // destroy runs unconditionally; join here to close that race. The join
    // hijack is idempotent, so this is a no-op if scrcpy() already joined and
    // never touches a thread that was never started.
    if (tracked) {
        sc_server_join_hijack(server);
    }

    free(server->serial);
    server->serial = NULL;

    free(server->device_socket_name);
    server->device_socket_name = NULL;

    sc_server_destroy(server);

    if (tracked) {
        // Poison the SDL handles so a subsequent teardown of the reused static
        // struct cannot double-destroy them. SDL_DestroyMutex(NULL) /
        // SDL_DestroyCondition(NULL) are documented no-ops.
        server->mutex.mutex = NULL;
        server->cond_stopped.cond = NULL;
        server->intr.mutex.mutex = NULL;
        g_server_destroyed = true;
        g_server_started = false;
    }
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