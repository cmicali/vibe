//
//  VibePerfLevels.mm
//  VibePerf
//
//  The equalizer's analyzer, the render's meter stage (1.10 on; before 1.14 a
//  consume also summarized).
//

#import "VibePerf.h"

#if __has_include("AudioLevelAnalyzer.h")
extern "C" {
#import "AudioLevelAnalyzer.h"
}

static void VibePerfRegisterLevels(void) {
    // The render's meter stage on a 48 kHz output, in 512-frame IO cycles,
    // with a summary per cycle as the publisher's drain takes them.
    VibePerfAdd("levels", "render", "audio s", VibePerfPCMPrepare(@"flac-24-96", 48000), []() {
        VibePerfPCM *pcm = VibePerfDecoded(@"flac-24-96");
        VibeAudioLevelAnalyzer *analyzer = VibeAudioLevelAnalyzerCreate(48000, (VibeAudioLevelNormalizationMode)0);
        float levels[kLevelBandCount];
        for (NSUInteger at = 0; at + 512 <= pcm->frames; at += 512) {
            float *channels[2] = {pcm->left.data() + at, pcm->right.data() + at};
#if VIBE_PERF_LEVELS_SUMMARIZE
            VibeAudioLevelAnalyzerConsume(analyzer, channels, 2, 512);
            VibeAudioLevelAnalyzerSummarize(analyzer, levels);
#else
            VibeAudioLevelAnalyzerConsume(analyzer, channels, 2, 512, levels);
#endif
        }
        VibeAudioLevelAnalyzerDestroy(analyzer);
    });
}

VIBE_PERF_REGISTER(VibePerfRegisterLevels)
#endif
