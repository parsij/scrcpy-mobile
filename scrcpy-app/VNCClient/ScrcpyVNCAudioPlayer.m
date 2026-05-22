//
//  ScrcpyVNCAudioPlayer.m
//  VNCClient
//
//  VNC Audio Streaming Player
//  Receives MP3 audio stream over TCP and decodes/plays via SDL
//

#import "ScrcpyVNCAudioPlayer.h"
#import <SDL3/SDL.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswresample/swresample.h>
#import <libavutil/opt.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>

// Audio configuration
#define AUDIO_RECV_BUFFER_SIZE 8192
#define AUDIO_SAMPLE_RATE 44100
#define AUDIO_CHANNELS 2

@interface ScrcpyVNCAudioPlayer ()

// Connection state
@property (nonatomic, readwrite) BOOL isPlaying;
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, readwrite, nullable) NSString *host;
@property (nonatomic, readwrite) int port;

// Socket
@property (nonatomic, assign) int socketFd;

// FFmpeg decoder
@property (nonatomic, assign) AVCodecContext *codecContext;
@property (nonatomic, assign) AVCodecParserContext *parserContext;
@property (nonatomic, assign) SwrContext *swrContext;
@property (nonatomic, assign) AVPacket *packet;
@property (nonatomic, assign) AVFrame *frame;

// SDL Audio
// SDL3: audio is driven through an SDL_AudioStream rather than a device id.
@property (nonatomic, assign) SDL_AudioStream *audioStream;
@property (nonatomic, assign) SDL_AudioSpec audioSpec;

// Threading
@property (nonatomic, assign) BOOL shouldStop;
@property (nonatomic, strong) NSThread *receiveThread;

// Ring buffer for decoded PCM audio
@property (nonatomic, assign) uint8_t *ringBuffer;
@property (nonatomic, assign) int ringBufferSize;
@property (nonatomic, assign) int ringBufferReadPos;
@property (nonatomic, assign) int ringBufferWritePos;
@property (nonatomic, assign) int ringBufferAvailable;
@property (nonatomic, assign) SDL_Mutex *ringBufferMutex;

// Volume
@property (nonatomic, assign) float volume;

// Buffer configuration
@property (nonatomic, assign) int bufferMs;

@end

@implementation ScrcpyVNCAudioPlayer

- (instancetype)init {
    self = [super init];
    if (self) {
        _isPlaying = NO;
        _isConnected = NO;
        _socketFd = -1;
        _codecContext = NULL;
        _parserContext = NULL;
        _swrContext = NULL;
        _packet = NULL;
        _frame = NULL;
        _audioStream = NULL;
        _shouldStop = NO;
        _volume = 1.0f;
        _ringBuffer = NULL;
        _ringBufferSize = 0;
        _ringBufferReadPos = 0;
        _ringBufferWritePos = 0;
        _ringBufferAvailable = 0;
        _ringBufferMutex = NULL;
        _bufferMs = 100;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Public Methods

- (void)startWithHost:(NSString *)host
                 port:(int)port
             bufferMs:(int)bufferMs
           completion:(void (^)(BOOL success, NSString * _Nullable error))completion {

    if (self.isPlaying) {
        NSLog(@"🔊 [VNCAudioPlayer] Already playing, stopping first");
        [self stop];
    }

    self.host = host;
    self.port = port;
    self.shouldStop = NO;

    // Configure buffer time (clamp to valid range)
    self.bufferMs = (bufferMs < 50) ? 50 : ((bufferMs > 500) ? 500 : bufferMs);

    // Calculate ring buffer size: 1 second of audio data
    self.ringBufferSize = AUDIO_SAMPLE_RATE * AUDIO_CHANNELS * 2 * 2;  // 2 seconds, 16-bit stereo
    // Round up to power of 2
    int powerOf2 = 1;
    while (powerOf2 < self.ringBufferSize) powerOf2 <<= 1;
    self.ringBufferSize = powerOf2;

    NSLog(@"🔊 [VNCAudioPlayer] Starting MP3 audio stream from %@:%d (buffer: %dms)",
          host, port, self.bufferMs);

    // Initialize FFmpeg decoder
    if (![self initFFmpegDecoder]) {
        if (completion) completion(NO, @"Failed to initialize MP3 decoder");
        return;
    }

    // Initialize ring buffer
    if (![self initRingBuffer]) {
        [self cleanupFFmpeg];
        if (completion) completion(NO, @"Failed to initialize audio buffer");
        return;
    }

    // Initialize SDL audio
    if (![self initSDLAudio]) {
        [self cleanupRingBuffer];
        [self cleanupFFmpeg];
        if (completion) completion(NO, @"Failed to initialize SDL audio");
        return;
    }

    // Connect to audio stream
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSError *connectError = nil;
        if (![strongSelf connectToHost:host port:port error:&connectError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf stop];
                if (completion) {
                    completion(NO, [NSString stringWithFormat:@"Failed to connect: %@", connectError.localizedDescription ?: @"Unknown error"]);
                }
            });
            return;
        }

        strongSelf.isConnected = YES;
        strongSelf.isPlaying = YES;

        // Start SDL audio playback
        if (strongSelf.audioStream) {
            SDL_ResumeAudioStreamDevice(strongSelf.audioStream);
        }

        // Start receive thread
        strongSelf.receiveThread = [[NSThread alloc] initWithTarget:strongSelf
                                                            selector:@selector(receiveLoop)
                                                              object:nil];
        strongSelf.receiveThread.name = @"VNCAudioReceiveThread";
        [strongSelf.receiveThread start];

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"🔊 [VNCAudioPlayer] MP3 audio streaming started successfully");
            if (completion) completion(YES, nil);
        });
    });
}

- (void)stop {
    NSLog(@"🔊 [VNCAudioPlayer] Stopping audio stream");

    self.shouldStop = YES;
    self.isPlaying = NO;
    self.isConnected = NO;

    // Wait for receive thread to finish
    if (self.receiveThread && [self.receiveThread isExecuting]) {
        [self.receiveThread cancel];
        [NSThread sleepForTimeInterval:0.2];
    }
    self.receiveThread = nil;

    // Close socket
    if (self.socketFd >= 0) {
        shutdown(self.socketFd, SHUT_RDWR);
        close(self.socketFd);
        self.socketFd = -1;
    }

    // Stop SDL audio (SDL3 owns the device behind the stream;
    // destroying the stream closes the underlying device).
    if (self.audioStream) {
        SDL_PauseAudioStreamDevice(self.audioStream);
        SDL_DestroyAudioStream(self.audioStream);
        self.audioStream = NULL;
    }

    // Cleanup
    [self cleanupRingBuffer];
    [self cleanupFFmpeg];

    NSLog(@"🔊 [VNCAudioPlayer] Audio stream stopped");
}

- (void)setVolume:(float)volume {
    _volume = fminf(1.0f, fmaxf(0.0f, volume));
}

#pragma mark - FFmpeg Decoder

- (BOOL)initFFmpegDecoder {
    // Find MP3 decoder
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MP3);
    if (!codec) {
        NSLog(@"❌ [VNCAudioPlayer] MP3 codec not found");
        return NO;
    }

    // Create codec context
    self.codecContext = avcodec_alloc_context3(codec);
    if (!self.codecContext) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to allocate codec context");
        return NO;
    }

    // Open codec
    if (avcodec_open2(self.codecContext, codec, NULL) < 0) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to open codec");
        avcodec_free_context(&_codecContext);
        return NO;
    }

    // Create parser context for MP3
    self.parserContext = av_parser_init(AV_CODEC_ID_MP3);
    if (!self.parserContext) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to create parser context");
        avcodec_free_context(&_codecContext);
        return NO;
    }

    // Allocate packet and frame
    self.packet = av_packet_alloc();
    self.frame = av_frame_alloc();

    if (!self.packet || !self.frame) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to allocate packet/frame");
        [self cleanupFFmpeg];
        return NO;
    }

    NSLog(@"🔊 [VNCAudioPlayer] FFmpeg MP3 decoder initialized");
    return YES;
}

- (void)cleanupFFmpeg {
    if (self.swrContext) {
        swr_free(&_swrContext);
    }
    if (self.packet) {
        av_packet_free(&_packet);
    }
    if (self.frame) {
        av_frame_free(&_frame);
    }
    if (self.parserContext) {
        av_parser_close(self.parserContext);
        self.parserContext = NULL;
    }
    if (self.codecContext) {
        avcodec_free_context(&_codecContext);
    }
}

- (BOOL)initResampler {
    if (self.swrContext) {
        swr_free(&_swrContext);
    }

    self.swrContext = swr_alloc();
    if (!self.swrContext) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to allocate resampler");
        return NO;
    }

    // Configure resampler: input from decoder, output to SDL format
    AVChannelLayout inLayout = self.codecContext->ch_layout;
    AVChannelLayout outLayout = AV_CHANNEL_LAYOUT_STEREO;

    av_opt_set_chlayout(self.swrContext, "in_chlayout", &inLayout, 0);
    av_opt_set_chlayout(self.swrContext, "out_chlayout", &outLayout, 0);
    av_opt_set_int(self.swrContext, "in_sample_rate", self.codecContext->sample_rate, 0);
    av_opt_set_int(self.swrContext, "out_sample_rate", AUDIO_SAMPLE_RATE, 0);
    av_opt_set_sample_fmt(self.swrContext, "in_sample_fmt", self.codecContext->sample_fmt, 0);
    av_opt_set_sample_fmt(self.swrContext, "out_sample_fmt", AV_SAMPLE_FMT_S16, 0);

    if (swr_init(self.swrContext) < 0) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to initialize resampler");
        swr_free(&_swrContext);
        return NO;
    }

    NSLog(@"🔊 [VNCAudioPlayer] Resampler initialized: %d Hz %s -> %d Hz S16 stereo",
          self.codecContext->sample_rate,
          av_get_sample_fmt_name(self.codecContext->sample_fmt),
          AUDIO_SAMPLE_RATE);

    return YES;
}

#pragma mark - Ring Buffer Management

- (BOOL)initRingBuffer {
    self.ringBuffer = (uint8_t *)calloc(self.ringBufferSize, 1);
    if (!self.ringBuffer) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to allocate ring buffer");
        return NO;
    }

    self.ringBufferMutex = SDL_CreateMutex();
    if (!self.ringBufferMutex) {
        free(self.ringBuffer);
        self.ringBuffer = NULL;
        return NO;
    }

    self.ringBufferReadPos = 0;
    self.ringBufferWritePos = 0;
    self.ringBufferAvailable = 0;

    return YES;
}

- (void)cleanupRingBuffer {
    if (self.ringBufferMutex) {
        SDL_DestroyMutex(self.ringBufferMutex);
        self.ringBufferMutex = NULL;
    }
    if (self.ringBuffer) {
        free(self.ringBuffer);
        self.ringBuffer = NULL;
    }
    self.ringBufferReadPos = 0;
    self.ringBufferWritePos = 0;
    self.ringBufferAvailable = 0;
}

- (void)writeToRingBuffer:(const uint8_t *)data length:(int)length {
    if (!self.ringBuffer || !self.ringBufferMutex || length <= 0) return;

    SDL_LockMutex(self.ringBufferMutex);

    int bufferMask = self.ringBufferSize - 1;

    for (int i = 0; i < length; i++) {
        if (self.ringBufferAvailable >= self.ringBufferSize) {
            // Buffer full, drop oldest
            self.ringBufferReadPos = (self.ringBufferReadPos + 1) & bufferMask;
            self.ringBufferAvailable--;
        }
        self.ringBuffer[self.ringBufferWritePos] = data[i];
        self.ringBufferWritePos = (self.ringBufferWritePos + 1) & bufferMask;
        self.ringBufferAvailable++;
    }

    SDL_UnlockMutex(self.ringBufferMutex);
}

- (int)readFromRingBuffer:(uint8_t *)data length:(int)length {
    if (!self.ringBuffer || !self.ringBufferMutex || length <= 0) return 0;

    SDL_LockMutex(self.ringBufferMutex);

    int bufferMask = self.ringBufferSize - 1;
    int toRead = (length < self.ringBufferAvailable) ? length : self.ringBufferAvailable;

    for (int i = 0; i < toRead; i++) {
        data[i] = self.ringBuffer[self.ringBufferReadPos];
        self.ringBufferReadPos = (self.ringBufferReadPos + 1) & bufferMask;
    }
    self.ringBufferAvailable -= toRead;

    SDL_UnlockMutex(self.ringBufferMutex);

    return toRead;
}

#pragma mark - SDL Audio (SDL3)

// SDL3 audio uses an SDL_AudioStream model. The audio thread calls the
// supplied callback when it needs more data, and the callback feeds the
// stream with SDL_PutAudioStreamData. There is no more per-device
// SDL_AudioDeviceID + sample-buffer-callback pair from SDL2.
static void sdlAudioCallback(void *userdata, SDL_AudioStream *stream,
                             int additional_amount, int total_amount) {
    (void)total_amount;
    ScrcpyVNCAudioPlayer *player = (__bridge ScrcpyVNCAudioPlayer *)userdata;
    [player feedAudioStream:stream length:additional_amount];
}

- (void)feedAudioStream:(SDL_AudioStream *)stream length:(int)len {
    if (len <= 0 || self.shouldStop) return;

    uint8_t *tempBuffer = (uint8_t *)malloc(len);
    if (!tempBuffer) return;

    int bytesRead = [self readFromRingBuffer:tempBuffer length:len];
    if (bytesRead <= 0) {
        // Push silence so the device keeps running.
        memset(tempBuffer, 0, len);
        SDL_PutAudioStreamData(stream, tempBuffer, len);
        free(tempBuffer);
        return;
    }

    if (self.volume < 1.0f && self.volume > 0.0f) {
        // SDL3: SDL_MixAudio mixes src into dst using a given format and
        // volume in [0.0, 1.0]. We mix from tempBuffer into a fresh
        // silent buffer to apply gain, then push that.
        uint8_t *out = (uint8_t *)calloc(1, bytesRead);
        if (out) {
            SDL_MixAudio(out, tempBuffer, SDL_AUDIO_S16, bytesRead, self.volume);
            SDL_PutAudioStreamData(stream, out, bytesRead);
            free(out);
        }
    } else if (self.volume <= 0.0f) {
        memset(tempBuffer, 0, bytesRead);
        SDL_PutAudioStreamData(stream, tempBuffer, bytesRead);
    } else {
        SDL_PutAudioStreamData(stream, tempBuffer, bytesRead);
    }

    free(tempBuffer);
}

- (BOOL)initSDLAudio {
    if (!SDL_WasInit(SDL_INIT_AUDIO)) {
        if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) {
            NSLog(@"❌ [VNCAudioPlayer] Failed to initialize SDL audio: %s", SDL_GetError());
            return NO;
        }
    }

    SDL_AudioSpec wanted;
    SDL_zero(wanted);
    wanted.freq = AUDIO_SAMPLE_RATE;
    wanted.format = SDL_AUDIO_S16;
    wanted.channels = AUDIO_CHANNELS;

    SDL_AudioStream *stream = SDL_OpenAudioDeviceStream(
        SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &wanted, sdlAudioCallback,
        (__bridge void *)self);
    if (!stream) {
        NSLog(@"❌ [VNCAudioPlayer] Failed to open audio device stream: %s", SDL_GetError());
        return NO;
    }

    self.audioStream = stream;
    self.audioSpec = wanted;

    NSLog(@"🔊 [VNCAudioPlayer] SDL3 audio stream open: %dHz, %d ch",
          self.audioSpec.freq, self.audioSpec.channels);

    return YES;
}

#pragma mark - Network

- (BOOL)connectToHost:(NSString *)host port:(int)port error:(NSError **)error {
    NSLog(@"🔊 [VNCAudioPlayer] Connecting to %@:%d", host, port);

    self.socketFd = socket(AF_INET, SOCK_STREAM, 0);
    if (self.socketFd < 0) {
        if (error) *error = [NSError errorWithDomain:@"VNCAudioPlayer" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to create socket"}];
        return NO;
    }

    int flag = 1;
    setsockopt(self.socketFd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));

    struct timeval timeout = {.tv_sec = 30, .tv_usec = 0};
    setsockopt(self.socketFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct hostent *he = gethostbyname([host UTF8String]);
    if (!he) {
        close(self.socketFd);
        self.socketFd = -1;
        if (error) *error = [NSError errorWithDomain:@"VNCAudioPlayer" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to resolve hostname"}];
        return NO;
    }

    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(port);
    memcpy(&serverAddr.sin_addr, he->h_addr, he->h_length);

    if (connect(self.socketFd, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        close(self.socketFd);
        self.socketFd = -1;
        if (error) *error = [NSError errorWithDomain:@"VNCAudioPlayer" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"Failed to connect"}];
        return NO;
    }

    NSLog(@"🔊 [VNCAudioPlayer] Connected to MP3 audio stream");
    return YES;
}

#pragma mark - Receive and Decode Loop

- (void)receiveLoop {
    @autoreleasepool {
        uint8_t recvBuffer[AUDIO_RECV_BUFFER_SIZE];
        uint8_t *parseBuffer = (uint8_t *)malloc(AUDIO_RECV_BUFFER_SIZE * 4);
        int parseBufferLen = 0;

        NSLog(@"🔊 [VNCAudioPlayer] MP3 receive loop started");

        while (!self.shouldStop && ![[NSThread currentThread] isCancelled]) {
            ssize_t bytesRead = recv(self.socketFd, recvBuffer, sizeof(recvBuffer), 0);

            if (bytesRead > 0) {
                // Append to parse buffer
                if (parseBufferLen + bytesRead > AUDIO_RECV_BUFFER_SIZE * 4) {
                    // Buffer overflow, reset
                    parseBufferLen = 0;
                }
                memcpy(parseBuffer + parseBufferLen, recvBuffer, bytesRead);
                parseBufferLen += bytesRead;

                // Parse and decode MP3 frames
                [self parseAndDecodeBuffer:parseBuffer length:&parseBufferLen];

            } else if (bytesRead == 0) {
                NSLog(@"🔊 [VNCAudioPlayer] Server closed connection");
                break;
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    continue;
                }
                NSLog(@"❌ [VNCAudioPlayer] Receive error: %s", strerror(errno));
                break;
            }
        }

        free(parseBuffer);
        NSLog(@"🔊 [VNCAudioPlayer] MP3 receive loop ended");
    }
}

- (void)parseAndDecodeBuffer:(uint8_t *)buffer length:(int *)length {
    uint8_t *data = buffer;
    int dataLen = *length;

    while (dataLen > 0 && !self.shouldStop) {
        int ret = av_parser_parse2(self.parserContext, self.codecContext,
                                   &self.packet->data, &self.packet->size,
                                   data, dataLen,
                                   AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
        if (ret < 0) {
            NSLog(@"❌ [VNCAudioPlayer] Parser error");
            break;
        }

        data += ret;
        dataLen -= ret;

        if (self.packet->size > 0) {
            [self decodePacket];
        }
    }

    // Move remaining data to start of buffer
    if (dataLen > 0 && data != buffer) {
        memmove(buffer, data, dataLen);
    }
    *length = dataLen;
}

- (void)decodePacket {
    int ret = avcodec_send_packet(self.codecContext, self.packet);
    if (ret < 0) {
        return;
    }

    while (ret >= 0 && !self.shouldStop) {
        ret = avcodec_receive_frame(self.codecContext, self.frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            break;
        }

        // Initialize resampler on first frame (now we know the format)
        if (!self.swrContext) {
            if (![self initResampler]) {
                break;
            }
        }

        // Resample and write to ring buffer
        [self resampleAndEnqueue];
    }
}

- (void)resampleAndEnqueue {
    // Calculate output samples
    int outSamples = (int)av_rescale_rnd(
        swr_get_delay(self.swrContext, self.codecContext->sample_rate) + self.frame->nb_samples,
        AUDIO_SAMPLE_RATE,
        self.codecContext->sample_rate,
        AV_ROUND_UP
    );

    // Allocate output buffer
    int outBufferSize = outSamples * AUDIO_CHANNELS * 2;  // 16-bit stereo
    uint8_t *outBuffer = (uint8_t *)malloc(outBufferSize);
    if (!outBuffer) return;

    // Resample
    int samplesOut = swr_convert(self.swrContext,
                                  &outBuffer, outSamples,
                                  (const uint8_t **)self.frame->data, self.frame->nb_samples);

    if (samplesOut > 0) {
        int bytesOut = samplesOut * AUDIO_CHANNELS * 2;
        [self writeToRingBuffer:outBuffer length:bytesOut];
    }

    free(outBuffer);
}

@end
