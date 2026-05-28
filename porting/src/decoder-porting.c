//
//  decoder-porting.c
//  scrcpy-module
//
//  Created by Ethan on 2022/6/8.
//

#define avcodec_send_packet(...)        avcodec_send_packet_hijack(__VA_ARGS__)
#define avcodec_receive_frame(...)        avcodec_receive_frame_hijack(__VA_ARGS__)

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

int avcodec_send_packet_hijack(AVCodecContext *avctx, const AVPacket *avpkt) {
    int ret = avcodec_send_packet(avctx, avpkt);
    if (ret < 0) {
        char errbuf[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(ret, errbuf, sizeof(errbuf));
        fprintf(stderr, "[ERROR] avcodec_send_packet error: %s\n", errbuf);
		ScrcpyTryResetVideo();
    }
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
        fprintf(stderr, "[decoder-porting] receive_frame error ret=%d bg=%d\n",
                ret, (int)inBg);
        if (inBg) {
            fprintf(stderr, "[decoder-porting] suppressing VT error → EAGAIN\n");
            return AVERROR(EAGAIN);
        }
    }
    return ret;
}
