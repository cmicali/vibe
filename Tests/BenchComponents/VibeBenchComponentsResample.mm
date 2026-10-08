//
//  VibeBenchComponentsResample.mm
//  VibeBenchComponents
//
//  The voice bus's resampler, r8brain, from 1.14 on; earlier versions
//  converted inside AVAudioEngine, which has no equivalent to measure alone.
//

#import "VibeBenchComponents.h"

#if __has_include("AudioResampler.h")
#import "AudioResampler.h"

struct VibeBenchComponentsConverterSource {
    const float *left;
    const float *right;
    NSUInteger frames;
    NSUInteger cursor;
};

static uint32_t VibeBenchComponentsConverterInput(void *userData, uint32_t maxFrames, const float **channels) {
    VibeBenchComponentsConverterSource *source = (VibeBenchComponentsConverterSource *)userData;
    if (source->cursor >= source->frames) {
        return 0;
    }
    uint32_t frames = (uint32_t)MIN((NSUInteger)maxFrames, source->frames - source->cursor);
    channels[0] = source->left + source->cursor;
    channels[1] = source->right + source->cursor;
    source->cursor += frames;
    return frames;
}

static void VibeBenchComponentsRegisterResample(void) {
    // From the rates the corpus plays to the 48 kHz built-in output, the way
    // the bus's decoder fills: 4096 output frames a turn, over 30 s of noise.
    for (double rate : {44100.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
        auto noise = std::make_shared<std::vector<float>>();
        const double seconds = 30;
        VibeBenchComponentsAdd("resample", std::to_string((int)rate), "audio s", [noise, rate, seconds]() -> double {
            noise->resize((size_t)(rate * seconds) * 2);
            VibeBenchComponentsNoise(noise->data(), noise->size(), 22222);
            return seconds;
        }, [noise, rate]() {
            size_t frames = noise->size() / 2;
            VibeConverter *converter = VibeConverterCreate(rate, 48000, 2);
            VibeBenchComponentsConverterSource source = {noise->data(), noise->data() + frames, frames, 0};
            std::vector<float> outLeft(4096), outRight(4096);
            float *out[2] = {outLeft.data(), outRight.data()};
            while (VibeConverterFill(converter, VibeBenchComponentsConverterInput, &source, 4096, out) > 0) {
            }
            VibeConverterDispose(converter);
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterResample)
#endif
