//
//  decoder-porting.c
//  scrcpy-module
//
//  Created by Ethan on 2022/6/8.
//

#define avcodec_send_packet(...)        avcodec_send_packet_hijack(__VA_ARGS__)
#define avcodec_receive_frame(...)        avcodec_receive_frame_hijack(__VA_ARGS__)

#include <time.h>

#include "decoder.c"

#undef avcodec_receive_frame
#undef avcodec_send_packet

int ScrcpyEnableHardwareDecoding(void);
void ScrcpyTryResetVideo(void);
bool GetUpdateApplicationBackgroundState(bool update);
int avcodec_send_packet(AVCodecContext *avctx, const AVPacket *avpkt);
int avcodec_receive_frame(AVCodecContext *avctx, AVFrame *frame);
AVFrame * ScrcpyHandleFrame(AVFrame *pending_frame);

// Static buffer for converted YUV planes
static Uint8 *converted_Y_buffer = NULL;
static Uint8 *converted_U_buffer = NULL;
static Uint8 *converted_V_buffer = NULL;
static int buffer_width = 0;
static int buffer_height = 0;

// Function to convert YUV 420v format from frame->data[3] to separate Y, U, V planes
static bool convert_yuv420v_from_frame_data3(const Uint8 *frame_data3, int width, int height,
                                            const Uint8 **Y_plane, int *Y_pitch,
                                            const Uint8 **U_plane, int *U_pitch,
                                            const Uint8 **V_plane, int *V_pitch) {
    if (!frame_data3) return false;

    // Reallocate buffers if size changed
    if (width != buffer_width || height != buffer_height) {
        if (converted_Y_buffer) { free(converted_Y_buffer); converted_Y_buffer = NULL; }
        if (converted_U_buffer) { free(converted_U_buffer); converted_U_buffer = NULL; }
        if (converted_V_buffer) { free(converted_V_buffer); converted_V_buffer = NULL; }

        int y_size = width * height;
        int uv_size = (width / 2) * (height / 2);

        converted_Y_buffer = (Uint8*)malloc(y_size);
        converted_U_buffer = (Uint8*)malloc(uv_size);
        converted_V_buffer = (Uint8*)malloc(uv_size);

        if (!converted_Y_buffer || !converted_U_buffer || !converted_V_buffer) {
            if (converted_Y_buffer) { free(converted_Y_buffer); converted_Y_buffer = NULL; }
            if (converted_U_buffer) { free(converted_U_buffer); converted_U_buffer = NULL; }
            if (converted_V_buffer) { free(converted_V_buffer); converted_V_buffer = NULL; }
            return false;
        }

        buffer_width = width;
        buffer_height = height;
    }

    // YUV420 format layout in frame->data[3]:
    // Y plane: width * height bytes
    // U plane: (width/2) * (height/2) bytes
    // V plane: (width/2) * (height/2) bytes
    int y_size = width * height;
    int uv_size = (width / 2) * (height / 2);

    // Copy planes from 420v format data
    memcpy(converted_Y_buffer, frame_data3, y_size);
    memcpy(converted_U_buffer, frame_data3 + y_size, uv_size);
    memcpy(converted_V_buffer, frame_data3 + y_size + uv_size, uv_size);

    // Set output parameters
    *Y_plane = converted_Y_buffer;
    *U_plane = converted_U_buffer;
    *V_plane = converted_V_buffer;
    *Y_pitch = width;
    *U_pitch = width / 2;
    *V_pitch = width / 2;

    return true;
}

// Throttle for the decode-error logs below.
//
// AppLogManager redirects the process's stderr into a file on disk when logging
// is enabled, so an unthrottled fprintf here writes a line per packet for as
// long as the error persists. Both hijacks deliberately keep the stream alive
// across a failure (see the comments on each), which means a persistent error
// is logged forever rather than ending the session — a user reported a single
// log file at 76 GB.
//
// Log at most one line per interval per call site, and report how many
// occurrences were suppressed so the rate is still visible.
#define SC_DECODE_LOG_INTERVAL_SEC 5.0

static bool sc_should_log_decode_error(double *last_log_time, int *suppressed) {
    // Monotonic elapsed seconds. clock() would measure CPU time, not wall time,
    // which on a mostly-blocked decode thread runs far slower than real time and
    // would stretch the interval unpredictably. CLOCK_MONOTONIC is unaffected by
    // both CPU usage and the user changing the date.
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = (double) ts.tv_sec + (double) ts.tv_nsec / 1e9;
    (*suppressed)++;
    if (now - *last_log_time < SC_DECODE_LOG_INTERVAL_SEC) {
        return false;
    }
    *last_log_time = now;
    return true;
}

int avcodec_send_packet_hijack(AVCodecContext *avctx, const AVPacket *avpkt) {
    int ret = avcodec_send_packet(avctx, avpkt);
    if (ret < 0) {
        static double last_log_time = 0;
        static int suppressed = 0;
        if (sc_should_log_decode_error(&last_log_time, &suppressed)) {
            char errbuf[AV_ERROR_MAX_STRING_SIZE];
            av_strerror(ret, errbuf, sizeof(errbuf));
            fprintf(stderr, "[ERROR] avcodec_send_packet error: %s (x%d in the last %.0fs)\n",
                    errbuf, suppressed, SC_DECODE_LOG_INTERVAL_SEC);
            suppressed = 0;
        }
		ScrcpyTryResetVideo();
    }
    // Deliberately report success to the caller even on failure.
    //
    // Upstream sc_decoder_push() returns false when send_packet fails, which
    // breaks the demuxer's read loop and ends the whole session
    // (on_ended -> disconnect). On iOS a decode error is usually transient —
    // VideoToolbox dropping its session across a background transition, or a
    // corrupt packet after a network hiccup — and dropping the connection for
    // one bad packet is far worse than skipping it. Swallowing the error keeps
    // the stream alive and lets ScrcpyTryResetVideo() above ask the server for
    // a fresh keyframe. This is the hijack's original purpose (4ca3338); the
    // same reasoning is documented on avcodec_receive_frame_hijack below.
    return ret < 0 ? 0 : ret;
}

int avcodec_receive_frame_hijack(AVCodecContext *avctx, AVFrame *frame) {
    int ret = avcodec_receive_frame(avctx, frame);
    if (ret == 0 && ScrcpyEnableHardwareDecoding() > 0) {
		ScrcpyHandleFrame(frame);
        return 0;
    }
    // When the app is in background, iOS invalidates the VideoToolbox hardware
    // decoder session (kVTInvalidSessionErr -12903). The next
    // avcodec_receive_frame then fails with AVERROR_EXTERNAL (-542398533).
    // Propagating that error makes scrcpy v4's sc_decoder_push() return false,
    // the demuxer breaks out of its loop ("end of frames") and the whole
    // connection drops. EAGAIN / EOF are legitimate "no frame yet" signals and
    // must pass through untouched.
    //
    // Swallow only genuine errors, and only while backgrounded: return EAGAIN
    // so the caller simply retries on the next packet. Video resumes on
    // foreground via ScrcpyTryResetVideo().
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
        bool inBg = GetUpdateApplicationBackgroundState(false);

        // Same throttling rationale as send_packet above: while backgrounded
        // this branch is hit for every packet and returns EAGAIN, so the error
        // persists by design and an unthrottled log would write a line per
        // packet for the whole time the app is in the background.
        static double last_log_time = 0;
        static int suppressed = 0;
        if (sc_should_log_decode_error(&last_log_time, &suppressed)) {
            fprintf(stderr,
                    "[decoder-porting] receive_frame error ret=%d bg=%d%s (x%d in the last %.0fs)\n",
                    ret, (int)inBg, inBg ? " -> suppressing to EAGAIN" : "",
                    suppressed, SC_DECODE_LOG_INTERVAL_SEC);
            suppressed = 0;
        }

        if (inBg) {
            return AVERROR(EAGAIN);
        }
    }
    return ret;
}
