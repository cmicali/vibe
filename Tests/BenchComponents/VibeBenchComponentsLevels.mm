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
    // The render's meter stage on a 48 kHz output, in 512-frame IO cycles,
    // with a summary per cycle as the publisher's drain takes them.
    VibeBenchComponentsAdd("levels", "render", "audio s", VibeBenchComponentsPCMPrepare(@"flac-24-96", 48000), []() {
        VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(@"flac-24-96");
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(48000, (VibeAudioLevelNormalizationMode)0);
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

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterLevels)
#endif
