//
//  main-porting.c
//  scrcpy-mobile
//
//  Created by Ethan on 2022/6/2.
//

#include <stdbool.h>

// Lifecycle guard for the process-wide main-thread mutex owned by events.c.
//
// On iOS scrcpy_main() is re-entered once per connection in the same process
// (-[ScrcpyADBClient startScrcpy:]), so the file-static `sc_mutex mutex` in
// events.c outlives a single run. Two defects follow from that, and they are
// the events.c analogue of the sc_server teardown fixed in 15ce734:
//
//  1. Double-destroy. sc_mutex_destroy() calls SDL_DestroyMutex() without
//     resetting mutex->mutex, and sc_main_thread_init() is not reached on
//     every path through main() (an early `goto end` from argument parsing,
//     --help/--version, or a net_init() failure skips it while the previous
//     run's handle is still stored). A later sc_main_thread_destroy() then
//     hands an already-freed SDL_Mutex to SDL_DestroyMutex(), which traps
//     with EXC_BREAKPOINT — the reported events.c:36 -> thread.c:82 crash.
//
//  2. Unpaired destroy. main() jumps to `net_cleanup:` when sc_main_thread_init()
//     fails, so a failed init is never followed by a destroy; but the reverse
//     (destroy without a live init, on a re-entry that bailed out early) is
//     exactly the crash above.
//
// Fix, entirely in the porting layer (no changes to scrcpy/ or SDL): track
// whether the mutex is currently live, make destroy a no-op unless a matching
// init succeeded, and make init idempotent so a leaked mutex from an aborted
// run is torn down rather than overwritten.
//
// scrcpy_main() runs on the main thread and each run is strictly sequential,
// so a single non-atomic guard is sufficient.
static bool g_main_thread_initialized = false;

#define main(...)      scrcpy_main(__VA_ARGS__)
#define sc_main_thread_init(...)    sc_main_thread_init_hijack(__VA_ARGS__)
#define sc_main_thread_destroy(...) sc_main_thread_destroy_hijack(__VA_ARGS__)

#include "main.c"

#undef main
#undef sc_main_thread_init
#undef sc_main_thread_destroy

// The real events.c symbols (the macros above only rewrite the call sites
// inside main.c, so these still resolve to the upstream implementations).
bool
sc_main_thread_init(void);
void
sc_main_thread_destroy(void);

// Handle sc_main_thread_init to keep the guard in sync and to avoid leaking a
// mutex if a previous run somehow left one live (init without a paired
// destroy). events.c resets `stopped` on every init, so re-initialising is
// safe as long as the old handle is released first.
bool
sc_main_thread_init_hijack(void) {
    if (g_main_thread_initialized) {
        // A previous run left the mutex live: release it before creating a new
        // one so the handle is not overwritten and leaked.
        sc_main_thread_destroy();
        g_main_thread_initialized = false;
    }

    bool ok = sc_main_thread_init();
    if (ok) {
        g_main_thread_initialized = true;
    }
    return ok;
}

// Handle sc_main_thread_destroy to make it idempotent: destroy only a mutex
// that a matching init actually created. Without this, a re-entry that never
// reached sc_main_thread_init() still runs the destroy on the stale handle
// left by the previous connection.
void
sc_main_thread_destroy_hijack(void) {
    if (!g_main_thread_initialized) {
        return; // never initialised, or already torn down — nothing to destroy
    }

    sc_main_thread_destroy();
    g_main_thread_initialized = false;
}
