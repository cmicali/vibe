//
//  VibeBenchComponentsWaveformUI.mm
//  VibeBenchComponents
//
//  The waveform renderers' layer work, offscreen. Apart from the rest of the
//  UI layer's benchmarks so that a version whose playlist differs still
//  builds these. With VIBE_BENCH_COMPONENTS_UI_DUMP set to a directory, each
//  prepare also writes what its subject draws there.
//

#import "VibeBenchComponents.h"

#import <QuartzCore/QuartzCore.h>

#import "DetailedAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
#import "ThreeBandWaveformRenderer.h"
#endif
#import "WaveformMorphEngine.h"

#include <cmath>
#include <memory>

// A complete waveform of the loader's 8,192 chunks with a loud middle, so
// normalize has something to raise.
static std::shared_ptr<AudioWaveform> VibeBenchComponentsUIWaveform(uint32_t seed) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
    auto waveform = std::make_shared<AudioWaveform>(true);
#else
    auto waveform = std::make_shared<AudioWaveform>();
#endif
    NSUInteger chunks = waveform->getNumChunks();
    uint32_t state = seed;
    for (NSUInteger i = 0; i < chunks; i++) {
        state = state * 1664525u + 1013904223u;
        float envelope = 0.15f + 0.35f * (float)std::sin(M_PI * (double)i / (double)chunks);
        float jitter = (float)(state >> 8) / 16777216.0f;
        float peak = envelope * (0.5f + 0.5f * jitter);
        float sumSquares = peak * peak * 0.3f * 512;
        AudioWaveformCacheChunk chunk;
        chunk.set(-peak * 0.9f, peak, sumSquares, 512);
        waveform->setChunkAtIndex(chunk, i);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
        // A mix's balance, the lead drifting between the bands.
        float bands[kAudioWaveformBandCount] = {sumSquares * (0.3f + 0.7f * jitter), sumSquares * 0.06f,
                                                sumSquares * 0.02f * (1.5f - jitter)};
        waveform->setBandSumSquaresAtIndex(bands, i);
#endif
    }
    waveform->markComplete();
    return waveform;
}

static NSData *VibeBenchComponentsUISublayerFrames(CALayer *parent) {
    NSMutableData *frames = [NSMutableData data];
    for (CALayer *layer in parent.sublayers) {
        CGRect frame = layer.frame;
        [frames appendBytes:&frame length:sizeof(frame)];
        CGColorRef color = layer.backgroundColor;
        const CGFloat *components = color ? CGColorGetComponents(color) : NULL;
        size_t count = color ? CGColorGetNumberOfComponents(color) : 0;
        for (size_t c = 0; c < count; c++) {
            [frames appendBytes:&components[c] length:sizeof(CGFloat)];
        }
    }
    return frames;
}

// The Detailed family's bar mask as Core Graphics fills it at 2x, a coverage
// byte a pixel: two builds' masks compared by what they cover.
static NSData *VibeBenchComponentsUIMaskCoverage(AudioWaveformRenderer *renderer) {
    CAShapeLayer *mask = [renderer valueForKey:@"_barMask"];
    size_t width = (size_t)(mask.bounds.size.width * 2), height = (size_t)(mask.bounds.size.height * 2);
    NSMutableData *coverage = [NSMutableData dataWithLength:width * height];
    CGContextRef ctx = CGBitmapContextCreate(coverage.mutableBytes, width, height, 8, width, NULL,
                                             (CGBitmapInfo)kCGImageAlphaOnly);
    if (!ctx || !mask.path) {
        CGContextRelease(ctx);
        return nil;
    }
    CGContextScaleCTM(ctx, 2, 2);
    CGContextAddPath(ctx, mask.path);
    CGContextFillPath(ctx);
    CGContextRelease(ctx);
    return coverage;
}

// Typed as Detailed, which declared the bake before the base class did.
static NSData *VibeBenchComponentsUIBakePixels(DetailedAudioWaveformRenderer *renderer, AudioWaveform *waveform) {
    CGImageRef image = [renderer newEnvelopeImageForSize:renderer.parentLayer.bounds.size scale:2
                                                 samples:[renderer envelopeSamplesForWaveform:waveform]];
    NSData *pixels = image ? CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image))) : nil;
    CGImageRelease(image);
    return pixels;
}

struct VibeBenchComponentsUIRenderer {
    CALayer *parent;
    AudioWaveformRenderer *renderer;
    WaveformMorphEngine *morph;
    std::shared_ptr<AudioWaveform> waveform;
};

// A 2x host layer of this width and the waveform a benchmark draws; answers
// the layer's bounds.
static CGRect VibeBenchComponentsUIHost(VibeBenchComponentsUIRenderer *state, CGFloat width, uint32_t seed) {
    state->parent = [CALayer layer];
    state->parent.contentsScale = 2;
    state->parent.bounds = CGRectMake(0, 0, width, 60);
    state->waveform = VibeBenchComponentsUIWaveform(seed);
    return state->parent.bounds;
}

// Sixty frames of a live resize, 700 to 936pt.
static void VibeBenchComponentsUILiveResize(VibeBenchComponentsUIRenderer *state) {
    for (int i = 0; i < 60; i++) {
        CGRect bounds = CGRectMake(0, 0, 700 + 4 * i, 60);
        state->parent.bounds = bounds;
        [state->renderer updateWaveform:bounds progress:0.4 waveform:state->waveform.get()];
    }
    [state->renderer settleMorphImmediately];
    [CATransaction flush];
}

static void VibeBenchComponentsRegisterRenderers(void) {
    // Sonic Cirrus at its 1,024-bar cap: a convert dip, its settle and a
    // same-geometry rebuild, ten times — thirty rebuilds over 2,048 layers.
    auto cirrus = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "sonic-cirrus-rebuild", "rebuild", [cirrus]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(cirrus.get(), 4096, 7);
        cirrus->renderer = [[SonicCirrusWaveformRenderer alloc] initWithLayer:cirrus->parent bounds:bounds isDark:YES];
        [cirrus->renderer updateWaveform:bounds progress:0 waveform:cirrus->waveform.get()];
        [cirrus->renderer settleMorphImmediately];
        [cirrus->renderer updateProgress:0.37 waveform:cirrus->waveform.get()];
        [cirrus->renderer setHoverHighlightX:1000];
        cirrus->morph = [cirrus->renderer valueForKey:@"_morph"];
        NSMutableData *frames = [NSMutableData dataWithData:VibeBenchComponentsUISublayerFrames(cirrus->parent)];
        [cirrus->morph dipDisplayedSamplesFromFraction:0.25 toFraction:0.5];
        [frames appendData:VibeBenchComponentsUISublayerFrames(cirrus->parent)];
        [cirrus->morph settleImmediately];
        [frames appendData:VibeBenchComponentsUISublayerFrames(cirrus->parent)];
        [cirrus->renderer updateWaveform:CGRectMake(0, 0, 2000, 60) progress:0.37 waveform:cirrus->waveform.get()];
        [cirrus->renderer updateProgress:0.5 waveform:cirrus->waveform.get()];
        [frames appendData:VibeBenchComponentsUISublayerFrames(cirrus->parent)];
        [cirrus->renderer updateWaveform:bounds progress:0.5 waveform:cirrus->waveform.get()];
        [frames appendData:VibeBenchComponentsUISublayerFrames(cirrus->parent)];
        VibeBenchComponentsUIDump(@"ui-waveform-sonic-cirrus-rebuild.raw", frames);
        return 30;
    }, [cirrus]() {
        for (int i = 0; i < 10; i++) {
            [cirrus->morph dipDisplayedSamplesFromFraction:0 toFraction:1];
            [cirrus->morph settleImmediately];
            [cirrus->morph rebuildNow];
        }
        [CATransaction flush];
    });

    // Detailed under Normalize through a live resize: every frame a new bar
    // count, so a refill and a rebuild. Sixty frames.
    auto detailed = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "detailed-resize", "frame", [detailed]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(detailed.get(), 800, 11);
        detailed->renderer = [[DetailedAudioWaveformRenderer alloc] initWithLayer:detailed->parent bounds:bounds
                                                                           isDark:YES wiggle:NO centered:NO];
        detailed->renderer.normalizesLevels = YES;
        [detailed->renderer updateWaveform:bounds progress:0 waveform:detailed->waveform.get()];
        [detailed->renderer settleMorphImmediately];
        NSMutableData *envelopes = [NSMutableData data], *masks = [NSMutableData data];
        DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)detailed->renderer;
        for (CGFloat width : {300.0, 801.0, 1600.0, 3000.0, 801.0}) {
            detailed->parent.bounds = CGRectMake(0, 0, width, 60);
            [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
            [envelopes appendData:[renderer envelopeSamplesForWaveform:detailed->waveform.get()]];
            [renderer settleMorphImmediately];
            [masks appendData:VibeBenchComponentsUIMaskCoverage(renderer)];
        }
        VibeBenchComponentsUIDump(@"ui-waveform-detailed-masks.raw", masks);
        VibeBenchComponentsUIDump(@"ui-waveform-detailed-bake.raw",
                                  VibeBenchComponentsUIBakePixels(renderer, detailed->waveform.get()));
        renderer.normalizesLevels = NO;
        [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
        [envelopes appendData:[renderer envelopeSamplesForWaveform:detailed->waveform.get()]];
        renderer.normalizesLevels = YES;
        [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
        [envelopes appendData:[renderer envelopeSamplesForWaveform:detailed->waveform.get()]];
        VibeBenchComponentsUIDump(@"ui-waveform-detailed-resize.raw", envelopes);
        return 60;
    }, [detailed]() {
        VibeBenchComponentsUILiveResize(detailed.get());
    });

    // The same resize with Normalize off, as the app ships: the refill
    // measures no reference, so the bars' level windows are all of it.
    auto plain = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "detailed-plain-resize", "frame", [plain]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(plain.get(), 800, 11);
        plain->renderer = [[DetailedAudioWaveformRenderer alloc] initWithLayer:plain->parent bounds:bounds
                                                                        isDark:YES wiggle:NO centered:NO];
        [plain->renderer updateWaveform:bounds progress:0 waveform:plain->waveform.get()];
        [plain->renderer settleMorphImmediately];
        return 60;
    }, [plain]() {
        VibeBenchComponentsUILiveResize(plain.get());
    });

    // Sonic Cirrus through it: a block style, a bar every four points, each
    // bar's level its own window's and its layers added as the width grows.
    auto blocks = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "sonic-cirrus-resize", "frame", [blocks]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(blocks.get(), 800, 17);
        blocks->renderer = [[SonicCirrusWaveformRenderer alloc] initWithLayer:blocks->parent bounds:bounds isDark:YES];
        blocks->renderer.normalizesLevels = YES;
        [blocks->renderer updateWaveform:bounds progress:0 waveform:blocks->waveform.get()];
        [blocks->renderer settleMorphImmediately];
        return 60;
    }, [blocks]() {
        VibeBenchComponentsUILiveResize(blocks.get());
    });

    // The style the app ships with: 4,096 bars at every width, so a resize
    // frame refills nothing and rebuilds the whole mask. Sixty frames.
    auto x4 = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "oversampling-x4-resize", "frame", [x4]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(x4.get(), 800, 19);
        x4->renderer = [[x4OversamplingDetailedAudioWaveformRenderer alloc] initWithLayer:x4->parent bounds:bounds
                                                                                    isDark:YES];
        [x4->renderer updateWaveform:bounds progress:0 waveform:x4->waveform.get()];
        [x4->renderer settleMorphImmediately];
        // The mask settled at four widths, then with a span dipped to the
        // midline.
        NSMutableData *masks = [NSMutableData data];
        for (CGFloat width : {300.0, 801.0, 1600.0, 3000.0}) {
            x4->parent.bounds = CGRectMake(0, 0, width, 60);
            [x4->renderer updateWaveform:x4->parent.bounds progress:0.4 waveform:x4->waveform.get()];
            [masks appendData:VibeBenchComponentsUIMaskCoverage(x4->renderer)];
        }
        [x4->renderer dipBarsFromFraction:0.2 toFraction:0.6];
        [masks appendData:VibeBenchComponentsUIMaskCoverage(x4->renderer)];
        [x4->renderer settleMorphImmediately];
        VibeBenchComponentsUIDump(@"ui-waveform-oversampling-x4-masks.raw", masks);
        VibeBenchComponentsUIDump(@"ui-waveform-oversampling-x4-bake.raw",
                                  VibeBenchComponentsUIBakePixels((DetailedAudioWaveformRenderer *)x4->renderer,
                                                                  x4->waveform.get()));
        return 60;
    }, [x4]() {
        VibeBenchComponentsUILiveResize(x4.get());
    });

    // It through track changes: each a new waveform's fill of the 4,096 bars
    // and the rebuild its settle draws. Thirty.
    auto loads = std::make_shared<VibeBenchComponentsUIRenderer>();
    auto next = std::make_shared<std::shared_ptr<AudioWaveform>>();
    VibeBenchComponentsAdd("ui-waveform", "oversampling-x4-load", "load", [loads, next]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(loads.get(), 800, 23);
        *next = VibeBenchComponentsUIWaveform(29);
        loads->renderer = [[x4OversamplingDetailedAudioWaveformRenderer alloc] initWithLayer:loads->parent
                                                                                       bounds:bounds isDark:YES];
        [loads->renderer updateWaveform:bounds progress:0 waveform:loads->waveform.get()];
        [loads->renderer settleMorphImmediately];
        return 30;
    }, [loads, next]() {
        CGRect bounds = loads->parent.bounds;
        for (int i = 0; i < 30; i++) {
            AudioWaveform *waveform = (i % 2 ? loads->waveform : *next).get();
            [loads->renderer updateWaveform:bounds progress:0.4 waveform:waveform];
            [loads->renderer settleMorphImmediately];
        }
        [CATransaction flush];
    });

#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
    // 3-Band through the same live resize as Detailed's: seven painter's
    // layers under the sides' mask, a bar a point.
    auto threeBand = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "three-band-resize", "frame", [threeBand]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(threeBand.get(), 800, 13);
        threeBand->renderer = [[ThreeBandWaveformRenderer alloc] initWithLayer:threeBand->parent bounds:bounds
                                                                        isDark:YES];
        threeBand->renderer.normalizesLevels = YES;
        NSMutableData *envelopes = [NSMutableData data];
        for (CGFloat width : {300.0, 801.0, 1600.0, 3000.0, 801.0}) {
            threeBand->parent.bounds = CGRectMake(0, 0, width, 60);
            [threeBand->renderer updateWaveform:threeBand->parent.bounds progress:0.4
                                       waveform:threeBand->waveform.get()];
            [envelopes appendData:[threeBand->renderer envelopeSamplesForWaveform:threeBand->waveform.get()]];
            [threeBand->renderer settleMorphImmediately];
        }
        VibeBenchComponentsUIDump(@"ui-waveform-three-band-resize.raw", envelopes);
        return 60;
    }, [threeBand]() {
        VibeBenchComponentsUILiveResize(threeBand.get());
    });
#endif
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterRenderers)
