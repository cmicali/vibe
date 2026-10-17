#import "VibeBenchComponents.h"
extern "C" {
#if __has_include("AudioFX+Pipeline.h")
#import "AudioFX+Pipeline.h"
#else
#import "AudioFX.h"
#endif
}

#include <memory>

// These cases measure settled effects. Finish control ramps before rendering.
static AudioFX *VibeBenchComponentsFX(dispatch_queue_t queue) {
    return [[AudioFX alloc] initWithQueue:queue scheduler:^(NSTimeInterval seconds, dispatch_block_t block) {
        block();
    } afterRenderLeaves:^(dispatch_block_t work) {
        work();
    }];
}

static void VibeBenchComponentsRegisterFX(void) {
    for (double rate : {48000.0, 96000.0}) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
        dispatch_queue_t queue = dispatch_queue_create("com.vibe.perf.fx", DISPATCH_QUEUE_SERIAL);
        VibeBenchComponentsAdd("fx-host", std::to_string((int)rate), "host", []() -> double { return 1; },
                              [format, queue]() {
            AudioFX *fx = VibeBenchComponentsFX(queue);
            dispatch_sync(queue, ^{
                [fx setConnected:YES format:format maximumFrameCount:512];
                VibeBenchComponentsRequire(fx.connected && fx.chain != NULL, "FX hosting failed");
                [fx setConnected:NO format:nil maximumFrameCount:512];
            });
        });

        auto noise = std::make_shared<std::vector<float>>();
        for (const char *effect : {"idle", "low-kill", "reverb", "delay", "short-delay", "all"}) {
            std::string name = effect;
            auto owner = std::make_shared<AudioFX *>();
            VibeBenchComponentsAdd("fx-render", name + "-" + std::to_string((int)rate), "audio s",
                                  [owner, noise, name, format, queue, rate]() -> double {
                noise->resize((size_t)rate * 30 * 2);
                VibeBenchComponentsNoise(noise->data(), noise->size(), 419);
                AudioFX *fx = VibeBenchComponentsFX(queue);
                fx.lowKillEnabled = name == "low-kill" || name == "all";
                fx.reverbSendLevel = name == "reverb" || name == "all" ? 0.5f : 0;
                fx.delaySendLevel = name == "delay" || name == "all" ? 0.5f : 0;
                fx.shortDelaySendEnabled = name == "short-delay" || name == "all";
                fx.delayTapBPM = 120;
                dispatch_sync(queue, ^{
                    [fx setConnected:YES format:format maximumFrameCount:512];
                    VibeBenchComponentsRequire(fx.connected && fx.chain != NULL, "FX hosting failed");
                });
                *owner = fx;
                return 30;
            }, [owner, noise, name, format, queue, rate]() {
                AudioFX *fx = *owner;
                dispatch_sync(queue, ^{
                    // Reset tails and filters for every repetition, including warm-up.
                    [fx setConnected:NO format:nil maximumFrameCount:512];
                    [fx setConnected:YES format:format maximumFrameCount:512];
                    uint64_t before = fx.unitRenders;
                    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:512];
                    NSUInteger frames = (NSUInteger)rate * 30;
                    for (NSUInteger at = 0; at < frames; at += 512) {
                        buffer.frameLength = (AVAudioFrameCount)MIN((NSUInteger)512, frames - at);
                        for (NSUInteger channel = 0; channel < 2; channel++) {
                            memcpy(buffer.floatChannelData[channel], noise->data() + channel * frames + at,
                                   buffer.frameLength * sizeof(float));
                        }
                        AudioTimeStamp stamp = {};
                        stamp.mFlags = kAudioTimeStampSampleTimeValid;
                        stamp.mSampleTime = at;
                        VibeBenchComponentsRequire(VibeFXChainRender(fx.chain, &stamp, buffer.frameLength,
                                                                     buffer.mutableAudioBufferList) == noErr,
                                                   "FX render failed");
                    }
                    VibeBenchComponentsRequire(name == "idle" ? fx.unitRenders == before : fx.unitRenders > before,
                                               "FX activity did not match the benchmark");
                });
            });
        }
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterFX)
