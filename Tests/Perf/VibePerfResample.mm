//
//  VibePerfResample.mm
//  VibePerf
//
//  The voice bus's resampler, r8brain, from 1.14 on; earlier versions
//  converted inside AVAudioEngine, which has no equivalent to measure alone.
//

#import "VibePerf.h"

#if __has_include("AudioResampler.h")
#import "AudioResampler.h"

struct VibePerfConverterSource {
    const float *left;
    const float *right;
    NSUInteger frames;
    NSUInteger cursor;
};

static uint32_t VibePerfConverterInput(void *userData, uint32_t maxFrames, const float **channels) {
    VibePerfConverterSource *source = (VibePerfConverterSource *)userData;
    if (source->cursor >= source->frames) {
        return 0;
    }
    uint32_t frames = (uint32_t)MIN((NSUInteger)maxFrames, source->frames - source->cursor);
    channels[0] = source->left + source->cursor;
    channels[1] = source->right + source->cursor;
    source->cursor += frames;
    return frames;
}

static void VibePerfRegisterResample(void) {
    // From the rates the corpus plays to the 48 kHz built-in output, the way
    // the bus's decoder fills: 4096 output frames a turn, over 30 s of noise.
    for (double rate : {44100.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
        auto noise = std::make_shared<std::vector<float>>();
        const double seconds = 30;
        VibePerfAdd("resample", std::to_string((int)rate), "audio s", [noise, rate, seconds]() -> double {
            noise->resize((size_t)(rate * seconds) * 2);
            uint32_t state = 22222;
            for (float &sample : *noise) {
                state = state * 1664525u + 1013904223u;
                sample = (float)(int32_t)state / 2147483648.0f * 0.5f;
            }
            return seconds;
        }, [noise, rate]() {
            size_t frames = noise->size() / 2;
            VibeConverter *converter = VibeConverterCreate(rate, 48000, 2);
            VibePerfConverterSource source = {noise->data(), noise->data() + frames, frames, 0};
            std::vector<float> outLeft(4096), outRight(4096);
            float *out[2] = {outLeft.data(), outRight.data()};
            while (VibeConverterFill(converter, VibePerfConverterInput, &source, 4096, out) > 0) {
            }
            VibeConverterDispose(converter);
        });
    }
}

VIBE_PERF_REGISTER(VibePerfRegisterResample)
#endif
