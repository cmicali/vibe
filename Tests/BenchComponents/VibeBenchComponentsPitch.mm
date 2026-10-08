//
//  VibeBenchComponentsPitch.mm
//  VibeBenchComponents
//
//  The pitch fader's converter, AudioVarispeed. Earlier versions hosted
//  Apple's Varispeed unit inside the render, which has no equivalent to
//  measure alone.
//

#import "VibeBenchComponents.h"

#if __has_include("AudioVarispeed.h")
#import "AudioVarispeed.h"
#include <memory>

static void VibeBenchComponentsRegisterPitch(void) {
    // 30 s of stereo noise out at 48 kHz, in the 512-frame slices of a
    // typical output cycle, at the fader's −8%, +4% and +16%. The ring holds
    // the whole input, so this measures the conversion and no copying.
    const double seconds = 30, rate = 48000;
    const uint32_t ringFrames = 1u << 21, slice = 512;
    auto ring = std::make_shared<std::vector<float>>();
    for (int percent : {-8, 4, 16}) {
        double ratio = 1 + percent / 100.0;
        auto table = std::make_shared<VibeVarispeedTable *>(nullptr);
        VibeBenchComponentsAdd("pitch", (percent > 0 ? "+" : "") + std::to_string(percent), "audio s",
                               [ring, table, ratio, seconds, ringFrames]() -> double {
            if (ring->empty()) {
                ring->resize((size_t)ringFrames * 2);
                uint32_t state = 33333;
                for (float &sample : *ring) {
                    state = state * 1664525u + 1013904223u;
                    sample = (float)(int32_t)state / 2147483648.0f * 0.5f;
                }
            }
            if (!*table) {
                *table = VibeVarispeedTableCreate(ratio);
            }
            return *table ? seconds : -1;
        }, [ring, table, ratio, seconds, rate, ringFrames, slice]() {
            std::vector<float> left(slice), right(slice);
            uint64_t index = kVibeVarispeedMaxHalfWidth;
            double fraction = 0;
            for (uint32_t done = 0; done < (uint32_t)(seconds * rate); done += slice) {
                VibeVarispeedConvert(*table, ring->data(), ring->data() + ringFrames, ringFrames - 1, &index, &fraction,
                                     ratio, ratio, slice, left.data(), right.data());
            }
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterPitch)
#endif
