//
//  AudioLevelTap.m
//  Vibe
//

#import "AudioLevelTap.h"

#import <Accelerate/Accelerate.h>
#import <stdatomic.h>

// 1024 samples at 48 kHz is ~47 published updates a second — comfortably finer
// than a 60 Hz display can show, and a real FFT of that size costs single-digit
// microseconds. Non-overlapping: an overlap would only buy time resolution the
// bars cannot draw.
enum { kFrameSize = 1024, kLog2FrameSize = 10 };

// A hint only. The delivered frameLength varies, which is the whole reason for
// the accumulator below.
enum { kTapBufferFrames = 1024 };

// The downmix scratch. A delivered buffer larger than this is consumed in
// several passes rather than growing the allocation on the audio thread.
enum { kMonoChunkFrames = 4096 };

// Everything the tap block touches, in one heap block of plain C. The block
// captures this pointer and nothing else, so it creates no objects and sends no
// messages beyond reading the delivered buffer's channel pointers.
typedef struct VibeLevelTapState {
    FFTSetup        fftSetup;
    float          *window;         // kFrameSize
    float          *accum;          // kFrameSize
    float          *windowed;       // kFrameSize
    float          *splitReal;      // kFrameSize / 2
    float          *splitImag;      // kFrameSize / 2
    float          *magnitudes;     // kFrameSize / 2
    float          *mono;           // kMonoChunkFrames
    size_t          fill;
    float           hopSeconds;
    NSUInteger      bandLow[kLevelBandCount];
    NSUInteger      bandHigh[kLevelBandCount];
    float           reference[kLevelBandCount];
    // Published to the main thread. Relaxed: each bar is independent and a
    // torn read across bars is invisible at 60 Hz, so ordering buys nothing
    // and a fence on the audio thread is not free.
    _Atomic float   level[kLevelBandCount];
} VibeLevelTapState;

#pragma mark - Frame processing (audio thread, no allocation, no locks)

static void VibeLevelTapProcessFrame(VibeLevelTapState *s) {
    vDSP_vmul(s->accum, 1, s->window, 1, s->windowed, 1, kFrameSize);

    DSPSplitComplex split = { s->splitReal, s->splitImag };
    vDSP_ctoz((const DSPComplex *)s->windowed, 2, &split, 1, kFrameSize / 2);
    vDSP_fft_zrip(s->fftSetup, &split, 1, kLog2FrameSize, kFFTDirection_Forward);

    // Bin 0 packs DC and Nyquist together, and neither belongs to a band.
    // vDSP_fft_zrip's output carries a factor of two the reference normalizes
    // away, so it is deliberately not scaled here.
    split.realp[0] = 0;
    split.imagp[0] = 0;
    vDSP_zvmags(&split, 1, s->magnitudes, 1, kFrameSize / 2);

    for (NSUInteger b = 0; b < kLevelBandCount; b++) {
        NSUInteger lo = s->bandLow[b];
        NSUInteger hi = s->bandHigh[b];
        float mean = 0;
        vDSP_meanv(s->magnitudes + lo, 1, &mean, hi - lo);
        // TRAP: a corrupt decode yields NaN or Inf samples, which vDSP
        // propagates. A NaN level makes the bar's CATransform3D NaN and the bar
        // disappears permanently, with no way back short of a relayout — the
        // same trap AudioWaveform.h sanitizes for the renderers.
        if (!isfinite(mean) || mean < 0) {
            mean = 0;
        }
        s->reference[b] = VibeLevelUpdateReference(s->reference[b], mean, s->hopSeconds);
        float level = VibeLevelNormalize(mean, s->reference[b]);
        atomic_store_explicit(&s->level[b], level, memory_order_relaxed);
    }
}

static void VibeLevelTapAccumulate(VibeLevelTapState *s, const float *mono, size_t frames) {
    size_t consumed = 0;
    while (consumed < frames) {
        size_t take = kFrameSize - s->fill;
        if (take > frames - consumed) {
            take = frames - consumed;
        }
        memcpy(s->accum + s->fill, mono + consumed, take * sizeof(float));
        s->fill += take;
        consumed += take;
        if (s->fill == kFrameSize) {
            VibeLevelTapProcessFrame(s);
            s->fill = 0;
        }
    }
}

// TRAP: a tap buffer is NON-interleaved — one pointer per channel — so
// AudioWaveformMonoMix, which looks like exactly the downmix wanted here, is
// the wrong tool and would silently read garbage: it expects interleaved
// float32. A stride-1 add per channel is the whole of the difference.
static void VibeLevelTapConsume(VibeLevelTapState *s, float * const *channels,
                                size_t channelCount, size_t frames) {
    if (channelCount == 0) {
        return;
    }
    size_t offset = 0;
    while (offset < frames) {
        size_t chunk = frames - offset;
        if (chunk > kMonoChunkFrames) {
            chunk = kMonoChunkFrames;
        }
        memcpy(s->mono, channels[0] + offset, chunk * sizeof(float));
        for (size_t c = 1; c < channelCount; c++) {
            vDSP_vadd(s->mono, 1, channels[c] + offset, 1, s->mono, 1, chunk);
        }
        if (channelCount > 1) {
            float scale = 1.0f / (float)channelCount;
            vDSP_vsmul(s->mono, 1, &scale, s->mono, 1, chunk);
        }
        VibeLevelTapAccumulate(s, s->mono, chunk);
        offset += chunk;
    }
}

#pragma mark -

@implementation AudioLevelTap {
    VibeLevelTapState *_state;
    AVAudioNode       *_node;
    BOOL               _installed;
}

- (instancetype)initWithNode:(AVAudioNode *)node {
    self = [super init];
    if (self) {
        // nil rather than an inert object, so the owner simply has no tap and
        // the next enable retries — a stopped engine's mixer can report no
        // usable format, and that is temporary.
        AVAudioFormat *format = [node outputFormatForBus:0];
        if (format.sampleRate <= 0 || format.channelCount == 0) {
            LogWarn(@"AudioLevelTap: bus 0 has no usable format, no levels");
            return nil;
        }

        _state = calloc(1, sizeof(VibeLevelTapState));
        _state->fftSetup = vDSP_create_fftsetup(kLog2FrameSize, kFFTRadix2);
        if (!_state->fftSetup) {
            LogError(@"AudioLevelTap: vDSP_create_fftsetup failed, no levels");
            free(_state);
            _state = NULL;
            return nil;
        }
        _state->window = malloc(sizeof(float) * kFrameSize);
        _state->accum = malloc(sizeof(float) * kFrameSize);
        _state->windowed = malloc(sizeof(float) * kFrameSize);
        _state->splitReal = malloc(sizeof(float) * kFrameSize / 2);
        _state->splitImag = malloc(sizeof(float) * kFrameSize / 2);
        _state->magnitudes = malloc(sizeof(float) * kFrameSize / 2);
        _state->mono = malloc(sizeof(float) * kMonoChunkFrames);
        vDSP_hann_window(_state->window, kFrameSize, vDSP_HANN_NORM);

        _state->hopSeconds = (float)((double)kFrameSize / format.sampleRate);
        for (NSUInteger b = 0; b < kLevelBandCount; b++) {
            VibeLevelBandBinRange(b, kFrameSize, format.sampleRate,
                                  &_state->bandLow[b], &_state->bandHigh[b]);
            _state->reference[b] = kLevelReferenceFloor;
            atomic_store_explicit(&_state->level[b], 0.0f, memory_order_relaxed);
        }

        VibeLevelTapState *state = _state;
        [node installTapOnBus:0 bufferSize:kTapBufferFrames format:format
                        block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            float * const *channels = buffer.floatChannelData;
            if (channels) {
                VibeLevelTapConsume(state, channels, buffer.format.channelCount,
                                    buffer.frameLength);
            }
        }];
        _node = node;
        _installed = YES;
        LogDebug(@"AudioLevelTap: installed at %.0f Hz", format.sampleRate);
    }
    return self;
}

- (void)remove {
    if (_installed) {
        [_node removeTapOnBus:0];
        _installed = NO;
    }
    _node = nil;
}

- (void)abandon {
    _installed = NO;
    _node = nil;
}

- (BOOL)copyLevels:(float *)out count:(NSUInteger)count {
    if (!_state || !out || count == 0 || count > kLevelBandCount) {
        return NO;
    }
    for (NSUInteger i = 0; i < count; i++) {
        out[i] = atomic_load_explicit(&_state->level[i], memory_order_relaxed);
    }
    return YES;
}

// The scratch is freed HERE and not in remove, because copyLevels: runs on the
// main thread against a tap the player queue may be tearing down at that
// moment. Reading the owner's atomic property retains this object for the call,
// so ordinary ARC lifetime is what keeps the buffers alive under the reader —
// where freeing them in remove would need a lock on the display-rate path to
// achieve the same thing. By the time dealloc runs, removeTapOnBus: has
// already returned and the block can no longer be invoked.
- (void)dealloc {
    [self remove];
    if (_state) {
        vDSP_destroy_fftsetup(_state->fftSetup);
        free(_state->window);
        free(_state->accum);
        free(_state->windowed);
        free(_state->splitReal);
        free(_state->splitImag);
        free(_state->magnitudes);
        free(_state->mono);
        free(_state);
        _state = NULL;
    }
}

@end
