//
//  adb-safe-porting.cpp
//  scrcpy-module
//
//  Catches C++ exceptions thrown from inside the in-tree ADB code so they
//  do not propagate up into Objective-C frames and SIGABRT the process.
//
//  Field crash motivating this wrapper:
//      Thread 0:
//        std::__1::thread::join()                          (thread.cpp:49)
//        (anonymous namespace)::ReconnectHandler::Stop()   (transport.cpp:174)
//        kick_all_transports()                             (transport.cpp:800)
//        adb_server_cleanup()                              (main.cpp:67)
//        launch_server()                                   (main.cpp:279)
//        adb_commandline()                                 (commandline.cpp)
//        adb_commandline_porting()
//        -[ADBClient executeADBCommandUnderlying:returnCode:]
//
//  std::thread::join() throws std::system_error if the thread handle is in a
//  bad state (e.g. the ReconnectHandler worker has already exited / been
//  detached by another shutdown path). adb-mobile is `external/` and not ours
//  to patch — so we wrap the boundary instead and surface the failure as a
//  non-zero return code, matching how every adb shell error already flows.
//

#include <cstring>
#include <exception>

extern "C" {
#include "adb_public.h"

int adb_commandline_porting_safe(char **output_buffer,
                                 size_t *output_buffer_size,
                                 int argc,
                                 const char **argv);
}

int adb_commandline_porting_safe(char **output_buffer,
                                 size_t *output_buffer_size,
                                 int argc,
                                 const char **argv) {
    try {
        return adb_commandline_porting(output_buffer, output_buffer_size, argc, argv);
    } catch (const std::exception &e) {
        const char *what = e.what() ? e.what() : "(unknown std::exception)";
        fprintf(stderr,
                "[adb-safe] adb_commandline_porting threw std::exception: %s\n",
                what);
        if (output_buffer && !*output_buffer) {
            *output_buffer = strdup(what);
            if (output_buffer_size) {
                *output_buffer_size = strlen(what);
            }
        }
        return -1;
    } catch (...) {
        fprintf(stderr,
                "[adb-safe] adb_commandline_porting threw unknown C++ exception\n");
        return -1;
    }
}
