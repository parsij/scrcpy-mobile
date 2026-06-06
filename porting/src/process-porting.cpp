//
//  process-porting.cpp
//  scrcpy-mobile
//
//  Created by Ethan on 2022/3/19.
//

#include "process-porting.hpp"

#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <map>
#include <mutex>
#include <string>
#include <vector>
#include <thread>

extern "C" {
#include "adb_public.h"
int adb_commandline_porting_safe(char **output_buffer,
                                 size_t *output_buffer_size,
                                 int argc,
                                 const char **argv);
}

static inline int array_len(const char *arr[]) {
    int len = 0;
    while (arr[len] != NULL) { len++; }
    return len;
}

/**
 * map tp store retured result of pid
 */

static std::map<pid_t, std::string> sc_result_map;

/**
 * global variable to store last output
 */
static std::string sc_last_output;

void sc_store_result(pid_t pid, const char *result) {
    sc_result_map.emplace(pid, std::string(result));
}

const char *sc_retrieve_result(pid_t pid) {
    return sc_result_map[pid].c_str();
}

const char *sc_remove_result(int pid) {
    std::string result = sc_result_map[pid];
    sc_result_map.erase(pid);
    if (result.empty()) {
        return strdup(result.c_str());
    }
    return NULL;
}

/**
 * map to store return success of pid
 */
static std::map<pid_t, bool> sc_success_map;

void sc_store_success(pid_t pid, bool success) {
    sc_success_map.emplace(pid, success);
}

bool sc_retrieve_success(pid_t pid) {
    return sc_success_map[pid];
}

void sc_remove_success(pid_t pid) {
    sc_success_map.erase(pid);
}

/**
 * map to store thread of pid
 */
static std::map<pid_t, std::thread *> sc_thread_map;
static std::mutex sc_thread_map_mutex;

void sc_thread_clean() {
    std::lock_guard<std::mutex> lock(sc_thread_map_mutex);
    std::map<pid_t, std::thread *> pending_clean;
    
    // try to avoid crash when there is no thread stored
    if (sc_thread_map.size() == 0) return;
    
    // try catch
    try {
        for (auto &th : sc_thread_map) {
            auto t = th.second;
            printf("> check thread %p status %d\n", t, t != nullptr && t->joinable());
            if (t == nullptr) pending_clean[th.first] = th.second;
        }

        printf("> cleaning %zu/%zu threads\n", pending_clean.size(), sc_thread_map.size());
        for (auto &th : pending_clean) {
            sc_thread_map.erase(th.first);
        }
        printf("> thread count after clean: %zu\n", sc_thread_map.size());
    } catch (const std::exception &e) {
        printf("> thread clean error: %s\n", e.what());
    }
}

void sc_store_thread(pid_t pid, std::thread *thread) {
    // clean finished thread
    sc_thread_clean();

    // Store thread
    std::lock_guard<std::mutex> lock(sc_thread_map_mutex);
    sc_thread_map.emplace(pid, thread);
}

void sc_remove_thread(pid_t pid) {
    std::lock_guard<std::mutex> lock(sc_thread_map_mutex);
    // Plain erase: do not pre-insert pid -> nullptr first, the v3-era
    // sequence here was equivalent (and the spurious insert just made
    // the assert path easier to hit under contention).
    sc_thread_map.erase(pid);
}

std::thread *sc_retrieve_thread(pid_t pid) {
    std::lock_guard<std::mutex> lock(sc_thread_map_mutex);
    // Check pid in map first
    if (sc_thread_map.empty() || sc_thread_map.size() == 0 || sc_thread_map.find(pid) == sc_thread_map.end()) {
        return nullptr;
    }
    return sc_thread_map[pid];
}

void adb_process_thread_func(bool *thread_started, pid_t pid, const char *thread_name, const char *adb_args[]) {
    printf("> thread: pid=%d, name=%s started.\n", pid, thread_name);
    
    // Copy args to local variable
    int argc = array_len(adb_args);
    const char *argv[argc];
    std::string command = std::string("");
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup(adb_args[i]);
        char cmd[strlen(argv[i])+2];
        memset(cmd, 0, strlen(argv[i])+2);
        sprintf(cmd, " %s", argv[i]);
        command.append(cmd);
    }
    printf("> adb%s\n", command.c_str());
    
    // Mark thread_started after copied all arguments
    *thread_started = true;
    
    if (argc > 5 && strcmp(argv[4], "app_process") == 0) {
        printf("> scrcpy-server app_process started\n");
    }

    // Change thread name
#ifdef __APPLE__
    pthread_setname_np(thread_name);
#else
    pthread_setname_np(pthread_self(), thread_name);
#endif

    // Execute adb command
    bool success;
    char *result = strdup("");
    size_t output_size = 0;

    std::thread commandline_thread = std::thread([argc, &argv, &result, &output_size, &success]() {
        int ret_code = adb_commandline_porting_safe(&result, &output_size, argc, argv);
        success = ret_code == 0;
    });
    commandline_thread.join();

    // deal with commandline occur errors and thread exit
    if (!success) {
        printf("> commandline_thread failed with output:\n%s", result);
    }

    // Save success
    sc_store_success(pid, success);
    
    // Save result
    sc_store_result(pid, result);
    
    printf("> pid=%d, success=%s\n", pid, success?"true":"false");
    // Find end of valid characters to avoid printing invalid unicode
    size_t result_len = result ? strlen(result) : 0;
    size_t valid_len = 0;
    if (result && result_len > 0) {
        for (size_t i = 0; i < result_len; i++) {
            unsigned char c = (unsigned char)result[i];
            // Check for valid ASCII or start of valid UTF-8 sequence
            if (c < 0x80 || (c >= 0xC0 && c <= 0xFD)) {
                valid_len = i + 1;
            } else if (c >= 0x80 && c < 0xC0) {
                // Continue UTF-8 sequence, keep current valid_len
                continue;
            } else {
                // Invalid character, stop here
                break;
            }
        }
    }
    
    // Store valid output to global variable
    if (valid_len > 0 && result) {
        sc_last_output = std::string(result, valid_len);
        printf("> result:\n%.*s\n", (int)valid_len, result);
    } else {
        sc_last_output = "";
        printf("> result:\n(empty)\n");
    }

    // Remove from sc_thread_map.
    // Must be under the same mutex as every other read/write of the map,
    // otherwise the std::map red-black tree can be torn between this
    // thread's erase and a concurrent reader/writer, tripping libc++'s
    // __tree_invariant assert. Also, do NOT re-insert pid -> nullptr
    // after erasing it (the v3-era line below would otherwise leak a
    // stale nullptr entry that later cleanup paths would erase again).
    {
        std::lock_guard<std::mutex> lock(sc_thread_map_mutex);
        sc_thread_map.erase(pid);
    }
}

int
sc_process_execute_p(const char *const argv[], sc_pid *pid, unsigned flags,
                     int *pin, int *pout, int *perr) {
    // Fake pipe fd
    if (pout != nullptr) {
        int pipe_fd[2];
        pipe(pipe_fd);
        *pout = (sc_pipe)pipe_fd[1];
    }
    
    // Generate fake pid
    *pid = arc4random() % 10000;
    
    // adb arguments start from index 1
    int len = array_len((const char **)argv);
    const char *adb_args[len];
    for (int i = 1; i < len; i++) {
        adb_args[i-1] = strdup(argv[i]);
    }
    adb_args[len-1] = NULL;
    
    // Format thread name
    const char *fmt = "adb-command-%d";
    int th_len = std::snprintf(nullptr, 0, fmt, *pid);
    char th_name[th_len+1];
    std::snprintf(th_name, th_len+1, fmt, *pid);
    const char *thread_name = strdup(th_name);
    
    // Create thread
    const char **adb_args_ref = (const char **)adb_args;
    bool thread_started = false;
    std::thread adb_thread = std::thread([&thread_started, pid, thread_name, adb_args_ref]() {
        adb_process_thread_func(&thread_started, *pid, thread_name, adb_args_ref);
    });
    sc_store_thread(*pid, &adb_thread);
    
    // Start thread
    adb_thread.detach();
    
    // Wait thread start, avoid variable be released
    while (thread_started == false) {
        usleep(10000);
    }
    
    return 0;
}

ssize_t
sc_pipe_read_all_intr(struct sc_intr *intr, sc_pid pid, sc_pipe pipe,
                      char *data, size_t len) {
    // Wait thread exited to read result
    sc_process_wait(pid, false);
    const char *result = sc_retrieve_result(pid);
    result = result ? : "";
    strcpy(data, result);
    return strlen(result) > len ? len : strlen(result);
}

sc_exit_code
sc_process_wait(pid_t pid, bool close) {
    // Wait 100ms to check thread status, prevent thread not started
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    
    std::thread *adb_thread = sc_retrieve_thread(pid);
    if (adb_thread == nullptr) {
        return sc_retrieve_success(pid)?0:1;
    }
    
    while((adb_thread = sc_retrieve_thread(pid)) && adb_thread != nullptr) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    
    printf("> wait pid=%d, result=%s\n", pid, sc_retrieve_success(pid)?"true":"false");
    return sc_retrieve_success(pid)?0:1;
}

bool
sc_process_terminate(pid_t pid) {
    std::thread *adb_thread = sc_retrieve_thread(pid);
    if (adb_thread == nullptr) {
        return true;
    }
    
    printf("> sc_process_terminate, thread pid: %d\n", pid);
    sc_remove_thread(pid);
    
    return true;
}

const char *
scrcpy_process_get_last_output() {
    return sc_last_output.c_str();
}
