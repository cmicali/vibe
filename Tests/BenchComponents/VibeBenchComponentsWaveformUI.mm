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

#if __has_include("DetailedWaveformRenderer.h")
#import "DetailedWaveformRenderer.h"
#import "OversamplingDetailedWaveformRenderer.h"
#else
#import "DetailedAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
// The drawing classes were AudioWaveform* before they took the Waveform* names.
#define WaveformRenderer AudioWaveformRenderer
#define DetailedWaveformRenderer DetailedAudioWaveformRenderer
#define x4OversamplingDetailedWaveformRenderer x4OversamplingDetailedAudioWaveformRenderer
#endif
#import "SonicCirrusWaveformRenderer.h"
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
#import "ThreeBandWaveformRenderer.h"
#endif
#import "WaveformMorphEngine.h"
#if VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
#import "WaveformRendererRegistry.h"
#endif

#include <cmath>
#include <memory>
#include <vector>

// A complete waveform with a loud middle, so normalize has something to
// raise: the loader's 8,192 chunks, or a summary of 8,192 bins of 512 frames.
static std::shared_ptr<AudioWaveform> VibeBenchComponentsUIWaveform(uint32_t seed) {
    const NSUInteger chunks = 8192;
#if VIBE_BENCH_COMPONENTS_WAVEFORM_MIX_ONLY
    auto waveform = std::make_shared<AudioWaveform>(512, true, 44100);
#elif VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
    auto waveform = std::make_shared<AudioWaveform>(512, 1, true, 44100);
#elif VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
    auto waveform = std::make_shared<AudioWaveform>(true);
#else
    auto waveform = std::make_shared<AudioWaveform>();
#endif
    uint32_t state = seed;
    for (NSUInteger i = 0; i < chunks; i++) {
        state = state * 1664525u + 1013904223u;
        float envelope = 0.15f + 0.35f * (float)std::sin(M_PI * (double)i / (double)chunks);
        float jitter = (float)(state >> 8) / 16777216.0f;
        float peak = envelope * (0.5f + 0.5f * jitter);
        float sumSquares = peak * peak * 0.3f * 512;
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
        // A mix's balance, the lead drifting between the bands.
        float lo = -peak * 0.9f;
        double bands[wavecore::kBandCount] = {sumSquares * (0.3f + 0.7f * jitter), sumSquares * 0.06f,
                                              sumSquares * 0.02f * (1.5f - jitter)};
#if VIBE_BENCH_COMPONENTS_WAVEFORM_MIX_ONLY
        waveform->appendBin(lo, peak, sumSquares, bands, 512);
#else
        waveform->appendBin(&lo, &peak, sumSquares, bands, 512);
#endif
#else
        AudioWaveformCacheChunk chunk;
        chunk.set(-peak * 0.9f, peak, sumSquares, 512);
        waveform->setChunkAtIndex(chunk, i);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
        float bands[kAudioWaveformBandCount] = {sumSquares * (0.3f + 0.7f * jitter), sumSquares * 0.06f,
                                                sumSquares * 0.02f * (1.5f - jitter)};
        waveform->setBandSumSquaresAtIndex(bands, i);
#endif
#endif
    }
#if VIBE_BENCH_COMPONENTS_WAVEFORM_COMPLETE
    waveform->markComplete();
#endif
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

#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
// The Detailed family's mask, its coverage drawn into its contents.
static NSData *VibeBenchComponentsUIMaskCoverage(WaveformRenderer *renderer) {
    return VibeBenchComponentsUIContents([renderer valueForKey:@"_barMask"]);
}

// What a band style paints, before the sides' mask.
static NSData *VibeBenchComponentsUIBandPicture(WaveformRenderer *renderer) {
    return VibeBenchComponentsUIContents([renderer valueForKey:@"_picture"]);
}
#else
// The Detailed family's bar mask as Core Graphics fills it at 2x, a coverage
// byte a pixel: two builds' masks compared by what they cover.
static NSData *VibeBenchComponentsUIMaskCoverage(WaveformRenderer *renderer) {
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
#endif

#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
// Typed as Detailed, which declared the bake before the base class did.
static NSData *VibeBenchComponentsUIBakePixels(DetailedWaveformRenderer *renderer, AudioWaveform *waveform) {
    CGImageRef image = [renderer newEnvelopeImageForSize:renderer.parentLayer.bounds.size scale:2
                                                 samples:[renderer envelopeSamplesForWaveform:waveform]];
    NSData *pixels = image ? CFBridgingRelease(CGDataProviderCopyData(CGImageGetDataProvider(image))) : nil;
    CGImageRelease(image);
    return pixels;
}
#endif

// What a renderer draws, settled: its picture. A version from before
// pictures answers its envelope's samples.
static NSData *VibeBenchComponentsUISamples(WaveformRenderer *renderer, AudioWaveform *waveform) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
    [renderer settleMorphImmediately];
    return [renderer.class readsBands] ? VibeBenchComponentsUIBandPicture(renderer)
                                       : VibeBenchComponentsUIMaskCoverage(renderer);
#else
    // Detailed declared the envelope before the base class did (1.15).
    return [(DetailedWaveformRenderer *)renderer envelopeSamplesForWaveform:waveform];
#endif
}

static CGContextRef VibeBenchComponentsUIBitmap(CGSize size) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)llround(size.width * 2),
            (size_t)llround(size.height * 2), 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    VibeBenchComponentsRequire(context != NULL, "waveform bitmap allocation failed");
    CGContextScaleCTM(context, 2, 2);
    return context;
}

struct VibeBenchComponentsUIRenderer {
    CALayer *parent;
    WaveformRenderer *renderer;
    WaveformMorphEngine *morph;
    std::shared_ptr<AudioWaveform> waveform;
    std::shared_ptr<AudioWaveform> nextWaveform;
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

// The render server's share of a frame: every shape layer's path scan
// converted at 2x. A version that draws its waveform as paths hands this
// work out of process, where a benchmark would not see it. One that draws
// pictures does it in process and has no paths left here, so the two
// compare.
static void VibeBenchComponentsUIFillShapes(CALayer *layer, CGContextRef ctx) {
    if ([layer isKindOfClass:CAShapeLayer.class] && ((CAShapeLayer *)layer).path) {
        CGContextAddPath(ctx, ((CAShapeLayer *)layer).path);
        CGContextFillPath(ctx);
    }
    if (layer.mask) {
        VibeBenchComponentsUIFillShapes(layer.mask, ctx);
    }
    for (CALayer *sublayer in layer.sublayers) {
        VibeBenchComponentsUIFillShapes(sublayer, ctx);
    }
}

static CGContextRef VibeBenchComponentsUIShapeContext(void) {
    CGContextRef ctx = CGBitmapContextCreate(NULL, 2 * 1000, 120, 8, 0, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextScaleCTM(ctx, 2, 2);
    return ctx;
}

// Sixty frames of a live resize, 700 to 936pt, each with the render server's
// share.
static void VibeBenchComponentsUILiveResize(VibeBenchComponentsUIRenderer *state) {
    CGContextRef ctx = VibeBenchComponentsUIShapeContext();
    for (int i = 0; i < 60; i++) {
        CGRect bounds = CGRectMake(0, 0, 700 + 4 * i, 60);
        state->parent.bounds = bounds;
        [state->renderer updateWaveform:bounds progress:0.4 waveform:state->waveform.get()];
        CGContextClearRect(ctx, CGRectMake(0, 0, 1000, 60));
        VibeBenchComponentsUIFillShapes(state->parent, ctx);
    }
    CGContextRelease(ctx);
    [state->renderer settleMorphImmediately];
    [CATransaction flush];
}

#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
// A streaming load's deliveries: thirty snapshots of a three-minute decode, a
// kick every half second over a slow swell. Each lands settled, and each
// differs from the one before only where the decode has reached since.
struct VibeBenchComponentsUILoad {
    VibeBenchComponentsUIRenderer view;
    std::vector<std::shared_ptr<AudioWaveform>> snapshots;
};

static void VibeBenchComponentsUILoadSnapshots(VibeBenchComponentsUILoad *load, bool bands) {
    const int64_t frames = 180 * 44100;
    std::vector<float> samples((size_t)frames);
    VibeBenchComponentsNoise(samples.data(), samples.size(), 37);
    for (int64_t i = 0; i < frames; i++) {
        double beat = std::fmod((double)i / 22050.0, 1.0);
        double swell = 0.4 + 0.6 * std::sin(M_PI * (double)i / (double)frames);
        samples[(size_t)i] *= (float)(swell * (0.15 + 0.7 * std::exp(-beat * 12)));
    }
    auto builder = VibeBenchComponentsMixBuilder(bands, frames, 44100);
    for (int64_t s = 0; s < 30; s++) {
        int64_t from = frames * s / 30, to = frames * (s + 1) / 30;
        VibeBenchComponentsAppendMix(*builder, samples.data() + from, (size_t)(to - from));
        load->snapshots.emplace_back(builder->snapshot());
    }
}

static void VibeBenchComponentsUIDeliver(VibeBenchComponentsUILoad *load) {
    CGRect bounds = load->view.parent.bounds;
    for (const auto &snapshot : load->snapshots) {
        [load->view.renderer updateWaveform:bounds progress:0.4 waveform:snapshot.get()];
        [load->view.renderer settleMorphImmediately];
    }
    [CATransaction flush];
}
#endif

static void VibeBenchComponentsRegisterRenderers(void) {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
    // Keep coverage in step with the production registry, including style variants.
    for (NSString *identifier in [[WaveformRendererRegistry availableIdentifiers] sortedArrayUsingSelector:@selector(compare:)]) {
        for (const char *operation : {"progress", "draw", "resize-draw", "scroll-draw", "pinch-draw", "load-draw", "detail-draw", "bake"}) {
            std::string op = operation;
            if (op == "detail-draw" && !VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER) continue;
#if !VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
            if (op == "bake") continue;
#endif
            auto state = std::make_shared<VibeBenchComponentsUIRenderer>();
            VibeBenchComponentsAdd("ui-waveform-" + op, identifier.UTF8String, "frame", [state, identifier, op]() -> double {
                CGRect bounds = VibeBenchComponentsUIHost(state.get(), op == "bake" ? 3200 :
                        op == "detail-draw" ? 65536 : op == "scroll-draw" ? 8000 : 800, 31);
                if (op == "load-draw") state->nextWaveform = VibeBenchComponentsUIWaveform(43);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
                if (op == "detail-draw") {
                    VibeBenchComponentsPCM *pcm = VibeBenchComponentsDecoded(@"flac-16-44");
                    if (!pcm) return -1;
                    size_t blockFrames = wavecore::Detail::kBlockFrames;
                    size_t frames = blockFrames * wavecore::Detail::kMaxBlocks;
                    VibeBenchComponentsRequire(pcm->frames >= frames, "deep zoom fixture too short");
                    auto builder = VibeBenchComponentsMixBuilder(true, (int64_t)frames, pcm->rate);
                    VibeBenchComponentsAppendMix(*builder, pcm->mono.data(), frames);
                    state->waveform = builder->finish(true);
                    for (size_t at = 0; at < frames; at += blockFrames) {
                        state->waveform->detail().insertBlock(at / blockFrames,
                                std::vector<float>(pcm->mono.begin() + at, pcm->mono.begin() + at + blockFrames));
                    }
                }
#endif
                state->renderer = [WaveformRendererRegistry rendererForResolvedIdentifier:identifier layer:state->parent
                                                                                  bounds:bounds isDark:YES];
                VibeBenchComponentsRequire(state->renderer != nil, "waveform renderer missing");
#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
                if (op == "scroll-draw" || op == "pinch-draw" || op == "detail-draw") {
                    state->renderer.renderRect = CGRectMake(0, 0, 800, 60);
                }
#endif
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
                if (op == "bake" && (!state->renderer.supportsEnvelopeBake ||
                                     ![state->renderer respondsToSelector:@selector(envelopeSamplesForWaveform:)])) return -1;
#endif
                [state->renderer updateWaveform:bounds progress:0 waveform:state->waveform.get()];
                [state->renderer settleMorphImmediately];
                if (getenv("VIBE_BENCH_COMPONENTS_UI_DUMP") && op != "progress") {
                    [state->renderer updateProgress:0.4 waveform:state->waveform.get()];
                    [state->renderer setHoverHighlightX:bounds.size.width * 0.6];
                    CGSize canvas = bounds.size;
                    if (op == "scroll-draw" || op == "detail-draw") canvas.width = 800;
                    CGContextRef context = VibeBenchComponentsUIBitmap(canvas);
                    [state->parent renderInContext:context];
                    CGImageRef image;
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
                    if (op == "bake") image = [(DetailedWaveformRenderer *)state->renderer newEnvelopeImageForSize:bounds.size scale:2
                                                      samples:[(DetailedWaveformRenderer *)state->renderer envelopeSamplesForWaveform:state->waveform.get()]];
                    else
#endif
                        image = CGBitmapContextCreateImage(context);
                    VibeBenchComponentsRequire(image != NULL, "waveform preview failed");
                    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
                    VibeBenchComponentsUIDump([NSString stringWithFormat:@"ui-waveform-%s-%@.png", op.c_str(), identifier],
                                             [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]);
                    CGImageRelease(image);
                    CGContextRelease(context);
                }
                [CATransaction flush];
                return 60;
            }, [state, op, identifier]() {
                CGRect canvas = CGRectMake(0, 0, op == "resize-draw" ? 1000 : 800, 60);
                CGContextRef context = op == "draw" || op.find("-draw") != std::string::npos ? VibeBenchComponentsUIBitmap(canvas.size) : NULL;
                for (int i = 0; i < 60; i++) {
                    @autoreleasepool {
                        CGFloat offset = 0;
                        if (op == "bake") {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
                            DetailedWaveformRenderer *baker = (DetailedWaveformRenderer *)state->renderer;
                            NSData *samples = [baker envelopeSamplesForWaveform:state->waveform.get()];
                            CGImageRef image = [baker newEnvelopeImageForSize:state->parent.bounds.size
                                                                               scale:2 samples:samples];
                            VibeBenchComponentsRequire(image != NULL, "waveform envelope bake failed");
                            CGImageRelease(image);
#endif
                        } else {
                            if (op == "scroll-draw" || op == "pinch-draw" || op == "detail-draw") {
                                CGFloat width = op == "detail-draw" ? 65536 :
                                                op == "scroll-draw" ? 8000 : 800 * std::pow(20.0, i / 59.0);
                                offset = op == "pinch-draw" ? (width - 800) * 0.4 : (width - 800) * i / 59.0;
                                state->parent.bounds = CGRectMake(0, 0, width, 60);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
                                state->renderer.renderRect = CGRectMake(offset, 0, 800, 60);
#endif
                                [state->renderer updateWaveform:state->parent.bounds progress:0.4 waveform:state->waveform.get()];
                                [state->renderer settleMorphImmediately];
                            } else if (op == "load-draw") {
                                [state->renderer updateWaveform:state->parent.bounds progress:0.4
                                                     waveform:(i % 2 ? state->waveform : state->nextWaveform).get()];
                                [state->renderer settleMorphImmediately];
                            } else if (op == "resize-draw") {
                                state->parent.bounds = CGRectMake(0, 0, 700 + 4 * i, 60);
                                [state->renderer updateWaveform:state->parent.bounds progress:0.4 waveform:state->waveform.get()];
                            } else {
                                [state->renderer updateProgress:(i + 1) / 60.0 waveform:state->waveform.get()];
                                [state->renderer setHoverHighlightX:i * state->parent.bounds.size.width / 60.0];
                            }
                            if (context) {
                                CGContextClearRect(context, canvas);
                                CGContextSaveGState(context);
                                CGContextTranslateCTM(context, -offset, 0);
                                [state->parent renderInContext:context];
                                CGContextRestoreGState(context);
                                if (getenv("VIBE_BENCH_COMPONENTS_UI_DUMP")) {
                                    VibeBenchComponentsUIDump([NSString stringWithFormat:@"ui-waveform-%s-%@-%02d.raw",
                                            op.c_str(), identifier, i], [NSData dataWithBytes:CGBitmapContextGetData(context)
                                            length:CGBitmapContextGetBytesPerRow(context) * CGBitmapContextGetHeight(context)]);
                                }
                            }
                        }
                    }
                }
                CGContextRelease(context);
                [state->renderer settleMorphImmediately];
                [CATransaction flush];
            });
        }
    }
#endif

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

    // Detailed under Normalize through a live resize: every frame redraws the
    // mask, and a version that reads its levels per bar refills them too.
    // Sixty frames.
    auto detailed = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "detailed-resize", "frame", [detailed]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(detailed.get(), 800, 11);
        detailed->renderer = [[DetailedWaveformRenderer alloc] initWithLayer:detailed->parent bounds:bounds
                                                                      isDark:YES];
        detailed->renderer.normalizesLevels = YES;
        [detailed->renderer updateWaveform:bounds progress:0 waveform:detailed->waveform.get()];
        [detailed->renderer settleMorphImmediately];
        NSMutableData *envelopes = [NSMutableData data], *masks = [NSMutableData data];
        DetailedWaveformRenderer *renderer = (DetailedWaveformRenderer *)detailed->renderer;
        for (CGFloat width : {300.0, 801.0, 1600.0, 3000.0, 801.0}) {
            detailed->parent.bounds = CGRectMake(0, 0, width, 60);
            [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
            [envelopes appendData:VibeBenchComponentsUISamples(renderer, detailed->waveform.get())];
            [renderer settleMorphImmediately];
            [masks appendData:VibeBenchComponentsUIMaskCoverage(renderer)];
        }
        VibeBenchComponentsUIDump(@"ui-waveform-detailed-masks.raw", masks);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
        VibeBenchComponentsUIDump(@"ui-waveform-detailed-bake.raw",
                                  VibeBenchComponentsUIBakePixels(renderer, detailed->waveform.get()));
#endif
        renderer.normalizesLevels = NO;
        [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
        [envelopes appendData:VibeBenchComponentsUISamples(renderer, detailed->waveform.get())];
        renderer.normalizesLevels = YES;
        [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
        [envelopes appendData:VibeBenchComponentsUISamples(renderer, detailed->waveform.get())];
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
        plain->renderer = [[DetailedWaveformRenderer alloc] initWithLayer:plain->parent bounds:bounds
                                                                   isDark:YES];
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

    // Oversampled 4x through the same resize, which redraws the mask.
    auto x4 = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "oversampling-x4-resize", "frame", [x4]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(x4.get(), 800, 19);
        x4->renderer = [[x4OversamplingDetailedWaveformRenderer alloc] initWithLayer:x4->parent bounds:bounds
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
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BAKE
        VibeBenchComponentsUIDump(@"ui-waveform-oversampling-x4-bake.raw",
                                  VibeBenchComponentsUIBakePixels((DetailedWaveformRenderer *)x4->renderer,
                                                                  x4->waveform.get()));
#endif
        return 60;
    }, [x4]() {
        VibeBenchComponentsUILiveResize(x4.get());
    });

    auto loads = std::make_shared<VibeBenchComponentsUIRenderer>();
    auto next = std::make_shared<std::shared_ptr<AudioWaveform>>();
    VibeBenchComponentsAdd("ui-waveform", "oversampling-x4-load", "load", [loads, next]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(loads.get(), 800, 23);
        *next = VibeBenchComponentsUIWaveform(29);
        loads->renderer = [[x4OversamplingDetailedWaveformRenderer alloc] initWithLayer:loads->parent
                                                                                  bounds:bounds isDark:YES];
        [loads->renderer updateWaveform:bounds progress:0 waveform:loads->waveform.get()];
        [loads->renderer settleMorphImmediately];
        return 30;
    }, [loads, next]() {
        CGRect bounds = loads->parent.bounds;
        CGContextRef ctx = VibeBenchComponentsUIShapeContext();
        for (int i = 0; i < 30; i++) {
            AudioWaveform *waveform = (i % 2 ? loads->waveform : *next).get();
            [loads->renderer updateWaveform:bounds progress:0.4 waveform:waveform];
            [loads->renderer settleMorphImmediately];
            CGContextClearRect(ctx, CGRectMake(0, 0, 1000, 60));
            VibeBenchComponentsUIFillShapes(loads->parent, ctx);
        }
        CGContextRelease(ctx);
        [CATransaction flush];
    });

#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
    // A streaming load as it lands: Detailed, then 3-Band, at a wide window's
    // width.
    for (int band = 0; band <= VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS; band++) {
        auto load = std::make_shared<VibeBenchComponentsUILoad>();
        VibeBenchComponentsAdd("ui-waveform", band ? "three-band-load-frames" : "detailed-load-frames", "frame",
                               [load, band]() -> double {
            if (load->snapshots.empty()) {
                VibeBenchComponentsUILoadSnapshots(load.get(), band);
            }
            load->view.parent = [CALayer layer];
            load->view.parent.contentsScale = 2;
            load->view.parent.bounds = CGRectMake(0, 0, 1200, 60);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
            Class style = band ? ThreeBandWaveformRenderer.class : DetailedWaveformRenderer.class;
#else
            Class style = DetailedWaveformRenderer.class;
#endif
            load->view.renderer = [[style alloc] initWithLayer:load->view.parent bounds:load->view.parent.bounds
                                                        isDark:YES];
            load->view.renderer.normalizesLevels = YES;
            VibeBenchComponentsUIDeliver(load.get());
            VibeBenchComponentsUIDump(band ? @"ui-waveform-three-band-load.raw" : @"ui-waveform-detailed-load.raw",
                                      band ? VibeBenchComponentsUIBandPicture(load->view.renderer)
                                           : VibeBenchComponentsUIMaskCoverage(load->view.renderer));
            return (double)load->snapshots.size();
        }, [load]() {
            VibeBenchComponentsUIDeliver(load.get());
        });
    }
#endif

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
            [envelopes appendData:VibeBenchComponentsUISamples(threeBand->renderer, threeBand->waveform.get())];
            [threeBand->renderer settleMorphImmediately];
        }
        VibeBenchComponentsUIDump(@"ui-waveform-three-band-resize.raw", envelopes);
        return 60;
    }, [threeBand]() {
        VibeBenchComponentsUILiveResize(threeBand.get());
    });
#endif

#if VIBE_BENCH_COMPONENTS_WAVEFORM_SPECTRUM
    for (float gain : {-6.0f, 6.0f}) {
        auto gained = std::make_shared<VibeBenchComponentsUIRenderer>();
        VibeBenchComponentsAdd("ui-waveform", gain < 0 ? "spectrum-gain-down-resize" : "spectrum-gain-up-resize",
                              "frame", [gained, gain]() -> double {
            CGRect bounds = VibeBenchComponentsUIHost(gained.get(), 800, 13);
            gained->renderer = [[SpectrumWaveformRenderer alloc] initWithLayer:gained->parent bounds:bounds isDark:YES];
            gained->renderer.gainDB = gain;
            [gained->renderer updateWaveform:bounds progress:0.4 waveform:gained->waveform.get()];
            [gained->renderer settleMorphImmediately];
            return 60;
        }, [gained]() {
            VibeBenchComponentsUILiveResize(gained.get());
        });
    }

    // Through KVC, so a version without the coloring skips it.
    auto sections = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "spectrum-sections-resize", "frame", [sections]() -> double {
        WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:YES];
        if (![theme respondsToSelector:NSSelectorFromString(@"setSpectrumColorsBySection:")]) {
            return -1;
        }
        [theme setValue:@YES forKey:@"spectrumColorsBySection"];
        CGRect bounds = VibeBenchComponentsUIHost(sections.get(), 800, 13);
        sections->renderer = [[SpectrumWaveformRenderer alloc] initWithLayer:sections->parent bounds:bounds
                                                                      isDark:YES];
        sections->renderer.theme = theme;
        [sections->renderer updateColors:YES];
        sections->renderer.normalizesLevels = YES;
        [sections->renderer updateWaveform:bounds progress:0.4 waveform:sections->waveform.get()];
        [sections->renderer settleMorphImmediately];
        return 60;
    }, [sections]() {
        VibeBenchComponentsUILiveResize(sections.get());
    });

    auto spectrum = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "spectrum-resize", "frame", [spectrum]() -> double {
        CGRect bounds = VibeBenchComponentsUIHost(spectrum.get(), 800, 13);
        spectrum->renderer = [[SpectrumWaveformRenderer alloc] initWithLayer:spectrum->parent bounds:bounds
                                                                      isDark:YES];
        spectrum->renderer.normalizesLevels = YES;
        NSMutableData *envelopes = [NSMutableData data], *pixels = [NSMutableData data];
        for (CGFloat width : {300.0, 801.0, 3000.0, 5000.0}) {
            spectrum->parent.bounds = CGRectMake(0, 0, width, 60);
            [spectrum->renderer updateWaveform:spectrum->parent.bounds progress:0.4 waveform:spectrum->waveform.get()];
            [spectrum->renderer settleMorphImmediately];
#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER
            [pixels appendData:VibeBenchComponentsUIBandPicture(spectrum->renderer)];
#else
            [envelopes appendData:[spectrum->renderer envelopeSamplesForWaveform:spectrum->waveform.get()]];
            [pixels appendData:VibeBenchComponentsUIContents([spectrum->renderer valueForKey:@"_spectrumFill"])];
#endif
        }
        VibeBenchComponentsUIDump(@"ui-waveform-spectrum-envelopes.raw", envelopes);
        VibeBenchComponentsUIDump(@"ui-waveform-spectrum-strip.raw", pixels);
        spectrum->parent.bounds = bounds;
        [spectrum->renderer updateWaveform:bounds progress:0.4 waveform:spectrum->waveform.get()];
        [spectrum->renderer settleMorphImmediately];
        return 60;
    }, [spectrum]() {
        VibeBenchComponentsUILiveResize(spectrum.get());
    });
#endif
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterRenderers)
