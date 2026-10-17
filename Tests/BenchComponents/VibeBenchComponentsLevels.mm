//
//  VibeBenchComponentsLevels.mm
//  VibeBenchComponents
//
//  The equalizer's analyzer, the render's meter stage (1.10 on; before 1.14 a
//  consume also summarized).
//

#import "VibeBenchComponents.h"

#if __has_include("AudioLevelAnalyzer.h")
extern "C" {
#import "AudioLevelAnalyzer.h"
}

static void VibeBenchComponentsRegisterLevels(void) {
    // Summarize every 512-frame block for a fixed workload across versions.
    // The production meter summarizes at its publication interval.
    for (double rate : {48000.0, 96000.0}) {
        for (NSUInteger mode = 0; mode < 3; mode++) {
            std::string name = rate == 48000 && mode == 0 ? "render" :
                    "render-" + std::to_string((int)rate) + "-mode" + std::to_string(mode);
            VibeBenchComponentsAdd("levels", name, "audio s", VibeBenchComponentsPCMPrepare(@"flac-24-96", rate), [rate, mode]() {
                VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(@"flac-24-96");
                VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(rate, (VibeAudioLevelNormalizationMode)mode);
                VibeBenchComponentsRequire(analyzer != nullptr, "level analyzer creation failed");
                float levels[kLevelBandCount];
                for (NSUInteger at = 0; at + 512 <= pcm->frames; at += 512) {
                    float *channels[2] = {pcm->left.data() + at, pcm->right.data() + at};
#if VIBE_BENCH_COMPONENTS_LEVELS_SUMMARIZE
                    VibeAudioLevelAnalyzerConsume(analyzer, channels, 2, 512);
                    VibeAudioLevelAnalyzerSummarize(analyzer, levels);
#else
                    VibeAudioLevelAnalyzerConsume(analyzer, channels, 2, 512, levels);
#endif
                }
                VibeAudioLevelAnalyzerDestroy(analyzer);
            });
        }
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterLevels)
#endif
