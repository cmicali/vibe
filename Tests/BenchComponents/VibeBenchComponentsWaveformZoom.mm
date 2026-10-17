//
//  VibeBenchComponentsWaveformZoom.mm
//  VibeBenchComponents
//
//  The iOS scrubber's waveform work, offscreen: a 3x picture 180 pt tall,
//  drawn as a window of a track far wider than the screen, as it scrolls and
//  as a pinch zooms. Apart from the resize benchmarks, so a version without
//  render windows drops only these. With VIBE_BENCH_COMPONENTS_UI_DUMP set,
//  each prepare writes the picture it last drew.
//

#import "VibeBenchComponents.h"

#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER

#import <QuartzCore/QuartzCore.h>
#import "DetailedWaveformRenderer.h"
#import "OversamplingDetailedWaveformRenderer.h"
#import "ThreeBandWaveformRenderer.h"

#include <cmath>
#include <memory>
#include <vector>

static const CGFloat kZoomHeight = 180;
static const CGFloat kZoomScreen = 390;

// About 24 s of noise under a kick every half second, built as a decode builds
// it, with every block of its frames held in the detail.
static std::shared_ptr<AudioWaveform> VibeBenchComponentsZoomWaveform(bool bands) {
    const int64_t blockFrames = wavecore::Detail::kBlockFrames;
    const int64_t frames = (int64_t)wavecore::Detail::kMaxBlocks * blockFrames;
    std::vector<float> samples((size_t)frames);
    VibeBenchComponentsNoise(samples.data(), samples.size(), 31);
    for (int64_t i = 0; i < frames; i++) {
        double beat = std::fmod((double)i / 22050.0, 1.0);
        samples[(size_t)i] *= (float)(0.15 + 0.7 * std::exp(-beat * 12));
    }
    auto builder = VibeBenchComponentsMixBuilder(bands, frames, 44100);
    VibeBenchComponentsAppendMix(*builder, samples.data(), samples.size());
    std::shared_ptr<AudioWaveform> waveform(builder->finish(true));
    for (int64_t block = 0; block * blockFrames < frames; block++) {
        auto begin = samples.begin() + (ptrdiff_t)(block * blockFrames);
        waveform->detail().insertBlock(block, std::vector<float>(begin, begin + blockFrames));
    }
    return waveform;
}

struct VibeBenchComponentsZoomState {
    CALayer *host;
    WaveformRenderer *renderer;
    std::shared_ptr<AudioWaveform> waveform;
};

// The scrubber's host: geometryFlipped at 3x, as wide as the zoomed track.
static void VibeBenchComponentsZoomSetUp(VibeBenchComponentsZoomState *state, Class style, bool bands,
                                         CGFloat virtualWidth) {
    state->waveform = VibeBenchComponentsZoomWaveform(bands);
    state->host = [CALayer layer];
    state->host.geometryFlipped = YES;
    state->host.contentsScale = 3;
    state->host.bounds = CGRectMake(0, 0, virtualWidth, kZoomHeight);
    state->renderer = [[style alloc] initWithLayer:state->host bounds:state->host.bounds isDark:YES];
    state->renderer.normalizesLevels = YES;
}

// One redraw of the window around content x, half a screen of margin either
// side unless pinching.
static void VibeBenchComponentsZoomDraw(VibeBenchComponentsZoomState *state, CGFloat x, BOOL margin) {
    CGRect bounds = state->host.bounds;
    CGFloat half = kZoomScreen / 2 + (margin ? kZoomScreen / 2 : 0);
    state->renderer.renderRect = CGRectIntersection(CGRectMake(x - half, 0, 2 * half, kZoomHeight), bounds);
    [state->renderer updateWaveform:bounds progress:0.4 waveform:state->waveform.get()];
}

// Thirty scroll frames a screen apart, each drawing a fresh window.
static void VibeBenchComponentsZoomScroll(VibeBenchComponentsZoomState *state) {
    for (int i = 0; i < 30; i++) {
        VibeBenchComponentsZoomDraw(state, kZoomScreen * (1.5 + i), YES);
    }
    [CATransaction flush];
}

// Thirty pinch frames from the resting zoom to 20 times it, about the
// playhead at 40%, each drawing the screen alone.
static void VibeBenchComponentsZoomPinch(VibeBenchComponentsZoomState *state) {
    for (int i = 0; i < 30; i++) {
        CGFloat width = 812 * std::pow(20.0, i / 29.0);
        state->host.bounds = CGRectMake(0, 0, width, kZoomHeight);
        VibeBenchComponentsZoomDraw(state, 0.4 * width, NO);
    }
    [CATransaction flush];
}

static void VibeBenchComponentsRegisterZoom(void) {
    struct Case {
        const char *name;
        Class style;
        bool bands;
        CGFloat width;
        NSString *picture;
        void (*body)(VibeBenchComponentsZoomState *);
    };
    // 24 s across 6,000 pt reads the bins; across 65,536 pt, 16 frames a
    // point, Detailed reads the frames themselves.
    const Case cases[] = {
        {"detailed-scroll", DetailedWaveformRenderer.class, false, 6000, @"_barMask", VibeBenchComponentsZoomScroll},
        {"detailed-deep-scroll", DetailedWaveformRenderer.class, false, 65536, @"_barMask",
         VibeBenchComponentsZoomScroll},
        {"detailed-pinch", DetailedWaveformRenderer.class, false, 812, @"_barMask", VibeBenchComponentsZoomPinch},
        {"oversampling-x4-pinch", x4OversamplingDetailedWaveformRenderer.class, false, 812, @"_barMask",
         VibeBenchComponentsZoomPinch},
        {"three-band-scroll", ThreeBandWaveformRenderer.class, true, 6000, @"_picture",
         VibeBenchComponentsZoomScroll},
    };
    for (const Case &c : cases) {
        auto state = std::make_shared<VibeBenchComponentsZoomState>();
        Case item = c;
        VibeBenchComponentsAdd("ui-waveform-zoom", item.name, "frame", [state, item]() -> double {
            VibeBenchComponentsZoomSetUp(state.get(), item.style, item.bands, item.width);
            item.body(state.get());
            [state->renderer settleMorphImmediately];
            // The picture last drawn, from the renderer's one picture layer.
            VibeBenchComponentsUIDump([NSString stringWithFormat:@"ui-waveform-zoom-%s.raw", item.name],
                                      VibeBenchComponentsUIContents([state->renderer valueForKey:item.picture]));
            return 30;
        }, [state, item]() {
            item.body(state.get());
        });
    }
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterZoom)

#endif
