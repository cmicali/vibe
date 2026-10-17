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

#if !VIBE_BENCH_COMPONENTS_VIBE_RESAMPLER
#define VibeResampler VibeConverter
#define VibeResamplerCreate VibeConverterCreate
#define VibeResamplerFill VibeConverterFill
#define VibeResamplerDispose VibeConverterDispose
#endif

struct VibeBenchComponentsResamplerSource {
    const float *left;
    const float *right;
    NSUInteger frames;
    NSUInteger cursor;
    uint32_t channels;
};

static uint32_t VibeBenchComponentsResamplerInput(void *userData, uint32_t maxFrames, const float **channels) {
    VibeBenchComponentsResamplerSource *source = (VibeBenchComponentsResamplerSource *)userData;
    if (source->cursor >= source->frames) {
        return 0;
    }
    uint32_t frames = (uint32_t)MIN((NSUInteger)maxFrames, source->frames - source->cursor);
    channels[0] = source->left + source->cursor;
    if (source->channels > 1) channels[1] = source->right + source->cursor;
    source->cursor += frames;
    return frames;
}

static void VibeBenchComponentsRegisterResample(void) {
    // From the rates the corpus plays to the 48 kHz built-in output, the way
    // the bus's decoder fills: 4096 output frames a turn, over 30 s of noise.
    for (double rate : {22050.0, 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0}) {
        for (double outputRate : {48000.0, 44100.0, 96000.0}) {
            if (outputRate != 48000 && rate != 48000) continue;
            for (uint32_t channels : {1u, 2u}) {
                if (channels == 1 && rate != 22050 && rate != 48000) continue;
                auto noise = std::make_shared<std::vector<float>>();
                const double seconds = 30;
                std::string name = std::to_string((int)rate) + (outputRate == 48000 ? "" : "-to-" + std::to_string((int)outputRate)) +
                                   (channels == 1 ? "-mono" : "");
                VibeBenchComponentsAdd("resample", name, "audio s", [noise, rate, seconds]() -> double {
                    noise->resize((size_t)(rate * seconds) * 2);
                    VibeBenchComponentsNoise(noise->data(), noise->size(), 22222);
                    return seconds;
                }, [noise, rate, outputRate, channels]() {
                    size_t frames = noise->size() / 2;
                    VibeResampler *resampler = VibeResamplerCreate(rate, outputRate, channels);
                    VibeBenchComponentsRequire(resampler != nullptr, "resampler creation failed");
                    VibeBenchComponentsResamplerSource source = {noise->data(), noise->data() + frames, frames, 0, channels};
                    std::vector<float> outLeft(4096), outRight(4096);
                    float *out[2] = {outLeft.data(), outRight.data()};
                    uint64_t produced = 0;
                    uint32_t count;
                    while ((count = VibeResamplerFill(resampler, VibeBenchComponentsResamplerInput, &source, 4096, out))) produced += count;
                    VibeBenchComponentsRequire(source.cursor == frames && produced > 0, "resampler did not consume its input");
                    VibeResamplerDispose(resampler);
                });
            }
        }
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterResample)
#endif
