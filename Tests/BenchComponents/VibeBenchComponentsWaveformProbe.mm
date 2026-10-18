//
//  VibeBenchComponentsWaveformProbe.mm
//  VibeBenchComponents
//
//  --waveform: one real file decoded by the production loader and drawn by
//  the production renderer, laid out as the iOS scrubber lays it out, plus
//  what the picture is drawn from. The vibe-waveform skill drives it, at any
//  ref perf.py can build. Measures nothing.
//

#import "VibeBenchComponents.h"

#if VIBE_BENCH_COMPONENTS_WAVEFORM_RASTER && VIBE_BENCH_COMPONENTS_WAVEFORM_SPECTRUM && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "AppSettings.h"
#import "AudioWaveform.h"
#import "AudioWaveformLoader.h"
#import "ThreeBandWaveformRenderer.h"
#import "WaveformRendererRegistry.h"
#import "WaveformZoomMath.h"

namespace {

struct ProbeOptions {
    NSString *style = @"spectrum";
    double at = 30;
    double span = 0;
    double fraction = 0;
    CGFloat width = 402;
    CGFloat height = 180;
    CGFloat scale = 3;
    BOOL precise = NO;
    BOOL light = NO;
    NSString *palette = SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB;
    NSString *out = nil;
    BOOL sections = NO;
    double levelsStep = 0;
    NSString *deliveries = nil;
    double every = 10;
};

}  // namespace

static void VibeWaveformProbeUsage(void) {
    fprintf(stderr,
            "usage: VibeBenchComponents --waveform <file> [options]\n"
            "  --style ID        a registry identifier (default spectrum)\n"
            "  --at S            the time under the playhead, in seconds (default 30)\n"
            "  --span S          seconds across the width (default: the style's deepest zoom)\n"
            "  --fraction F      or the share of the track across it, the scrubber's visibleFraction (0.48 at rest)\n"
            "  --width PT --height PT --scale N   the view (default 402, 180, 3: an iPhone 17 Pro's card)\n"
            "  --precise         Spectrum's Precise coloring (default By section)\n"
            "  --palette ID      Spectrum's palette: rgb, blue, green (default rgb)\n"
            "  --light           the light appearance\n"
            "  --out PNG         write the picture\n"
            "  --sections        print Spectrum's sections over the whole track\n"
            "  --levels STEP     print the mix and band levels every STEP seconds across the view\n"
            "  --deliveries DIR  replay the decode's progressive deliveries, one every --every seconds of audio\n"
            "                    (default 10), each drawn settled as DIR/NNN.png, the complete one last\n");
}

// The decode's progressive deliveries, replayed: the file through the
// player's reader and the summary builder as the loader drives them, a
// snapshot every `every` seconds of audio. The loader's own come every 0.1 s
// of wall time, which a fast Mac finishes before the first.
static NSArray<CodableAudioWaveform *> *VibeWaveformProbeReplay(NSString *path, BOOL bands, double every) {
    VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:path interleaved:YES];
    AVAudioFormat *format = reader.processingFormat;
    double rate = format.sampleRate;
    NSUInteger channels = format.channelCount;
    auto builder = VibeBenchComponentsMixBuilder(bands, reader.length, rate);
    AVAudioFrameCount block = 4096;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:block];
    std::vector<float> scratch(block);
    NSMutableArray<CodableAudioWaveform *> *snapshots = [NSMutableArray array];
    int64_t read = 0, next = (int64_t)(every * rate);
    BOOL more = YES;
    while (more) {
        more = [reader read:buffer];
        NSUInteger frames = buffer.frameLength;
        if (frames > 0) {
            VibeBenchComponentsAppendMix(*builder,
                    AudioWaveformMonoMix(buffer.floatChannelData[0], scratch.data(), frames, channels), frames);
            read += (int64_t)frames;
        }
        if (more && read >= next) {
            [snapshots addObject:[[CodableAudioWaveform alloc] initWithWaveform:builder->snapshot()]];
            next += (int64_t)(every * rate);
        }
    }
    return snapshots;
}

// The style's renderer on a host of its own, as the scrubber makes it.
static WaveformRenderer *VibeWaveformProbeRenderer(const ProbeOptions &o, NSString *style, CALayer *host) {
    host.anchorPoint = CGPointZero;
    host.contentsScale = o.scale;
    host.bounds = CGRectMake(0, 0, o.width, o.height);
    WaveformRenderer *renderer = [WaveformRendererRegistry rendererForResolvedIdentifier:style layer:host
                                                                                 bounds:host.bounds isDark:!o.light];
    renderer.normalizesLevels = YES;
    return renderer;
}

// The view's visible fraction, clamped as the scrubber clamps it.
static double VibeWaveformProbeFraction(const ProbeOptions &o, WaveformRenderer *renderer, AudioWaveform *waveform) {
    double total = (double)waveform->totalFrames();
    double minimum = VibeWaveformMinimumVisibleFraction(o.width, total, [renderer minimumFramesPerPointForWaveform:waveform]);
    double requested = o.fraction > 0 ? o.fraction : o.span > 0 ? o.span * waveform->sampleRate() / total : minimum;
    return VibeWaveformClampVisibleFraction(requested, minimum);
}

static WaveformTheme *VibeWaveformProbeTheme(const ProbeOptions &o, NSString *style) {
    WaveformTheme *theme = [WaveformTheme monochromeThemeIsDark:!o.light];
    theme.spectrumColors = [WaveformTheme spectrumColorsForIdentifier:o.palette isDark:!o.light customBands:@[]];
    theme.spectrumColorsBySection = !o.precise;
    if ([WaveformRendererRegistry drawsPlayheadLineForIdentifier:style chosen:nil]) {
        theme.playheadColor = [(o.light ? NSColor.blackColor : NSColor.whiteColor) colorWithAlphaComponent:0.68];
    }
    return theme;
}

// Draws the window the scrubber shows with the playhead at its center, and
// answers the picture. Deep zoom's blocks are read from the file once, as the
// scrubber's delegate reads them, and the window drawn again.
static CGImageRef VibeWaveformProbeNewImage(const ProbeOptions &o, NSString *style, double fraction, NSString *path,
                                            CodableAudioWaveform *codable, AudioWaveformLoader *loader) {
    AudioWaveform *waveform = codable.waveform;
    CALayer *host = [CALayer layer];
    WaveformRenderer *renderer = VibeWaveformProbeRenderer(o, style, host);
    if (!renderer) {
        return NULL;
    }
    WaveformTheme *theme = VibeWaveformProbeTheme(o, style);
    renderer.theme = theme;
    [renderer updateColors:!o.light];
    CGFloat virtualWidth = o.width / fraction;
    CGRect virtualBounds = CGRectMake(0, 0, virtualWidth, o.height);
    host.bounds = virtualBounds;
    double at = o.at * waveform->sampleRate() / (double)waveform->totalFrames();
    CGFloat left = at * virtualWidth - o.width / 2;
    CGRect window = CGRectIntersection(CGRectMake(left, 0, o.width, o.height), virtualBounds);
    CGFloat progress = theme.playheadColor ? 1 : clampRange(at, 0.0, 1.0);
    renderer.samplingWidth = o.width / kVibeWaveformDefaultZoomFraction;
    renderer.renderRect = CGRectIsNull(window) ? CGRectZero : window;
    [renderer updateWaveform:virtualBounds progress:progress waveform:waveform];
    std::vector<int64_t> lacked = waveform->detail().takeLackedBlocks();
    if (!lacked.empty() && loader) {
        NSMutableIndexSet *blocks = [NSMutableIndexSet indexSet];
        for (int64_t block : lacked) {
            [blocks addIndex:(NSUInteger)block];
        }
        if ([loader loadDetailBlocks:blocks ofFile:path intoWaveform:codable]) {
            [renderer updateWaveform:virtualBounds progress:progress waveform:waveform];
        }
    }
    [renderer settleMorphImmediately];
    [CATransaction flush];

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)llround(o.width * o.scale), (size_t)llround(o.height * o.scale), 8, 0,
                                                 space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(context, o.scale, o.scale);
    CGFloat ground = o.light ? 0.92 : 0.24;
    CGContextSetRGBFillColor(context, ground, ground, ground, 1);
    CGContextFillRect(context, CGRectMake(0, 0, o.width, o.height));
    CGContextTranslateCTM(context, -left, 0);
    [host renderInContext:context];
    CGContextTranslateCTM(context, left, 0);
    if (theme.playheadColor) {
        CGContextSetFillColorWithColor(context, theme.playheadColor.CGColor);
        // The scrubber's line, 8 pt past the band at each end.
        CGRect band = CGRectIntersection(CGRectInset([renderer seekHitBandForBounds:host.bounds], 0, -8),
                                         CGRectMake(0, 0, o.width, o.height));
        CGContextFillRect(context, VibePlayheadLineRect(o.width / 2, band, o.width, o.scale));
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

static BOOL VibeWaveformProbeWrite(CGImageRef image, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

static void VibeWaveformProbePrintSections(AudioWaveform *waveform) {
    double rate = waveform->sampleRate();
    printf("sections (start s, low mid high share of the mix):\n");
#if VIBE_BENCH_COMPONENTS_SPECTRUM_SECTIONS
    for (const VibeSpectrumSection &section : VibeSpectrumSections(waveform)) {
        float mix[3];
        VibeSpectrumMix(section.meanSquares, kVibeWaveformBandShares, mix);
        printf("  %9.3f  %.2f %.2f %.2f\n", section.start / rate, mix[0], mix[1], mix[2]);
    }
#else
    printf("  this ref has no VibeSpectrumSections\n");
#endif
}

static void VibeWaveformProbePrintLevels(const ProbeOptions &o, AudioWaveform *waveform, double fraction) {
    double rate = waveform->sampleRate();
    double seconds = fraction * (double)waveform->totalFrames() / rate;
    double step = o.levelsStep * rate;
    printf("levels (s: mix lo hi loudest | low mid high loudest), every %.3f s:\n", o.levelsStep);
    for (double t = o.at - seconds / 2; t < o.at + seconds / 2; t += o.levelsStep) {
        if (t < 0) {
            continue;
        }
        wavecore::Column column = waveform->column(t * rate, t * rate + step);
        printf("  %9.3f  %6.3f %6.3f %6.3f | %6.3f %6.3f %6.3f\n", t, column.lo, column.hi, column.loudest,
               column.bandLoudest[0], column.bandLoudest[1], column.bandLoudest[2]);
    }
}

static int VibeWaveformProbe(NSString *path, int argc, const char *argv[]) {
    if ([path isEqualToString:@"--help"]) {
        VibeWaveformProbeUsage();
        return 0;
    }
    ProbeOptions o;
    for (int i = 0; i < argc; i++) {
        std::string arg = argv[i];
        BOOL hasValue = i + 1 < argc;
        if (arg == "--style" && hasValue) o.style = @(argv[++i]);
        else if (arg == "--at" && hasValue) o.at = atof(argv[++i]);
        else if (arg == "--span" && hasValue) o.span = atof(argv[++i]);
        else if (arg == "--fraction" && hasValue) o.fraction = atof(argv[++i]);
        else if (arg == "--width" && hasValue) o.width = atof(argv[++i]);
        else if (arg == "--height" && hasValue) o.height = atof(argv[++i]);
        else if (arg == "--scale" && hasValue) o.scale = atof(argv[++i]);
        else if (arg == "--palette" && hasValue) o.palette = @(argv[++i]);
        else if (arg == "--out" && hasValue) o.out = @(argv[++i]);
        else if (arg == "--levels" && hasValue) o.levelsStep = atof(argv[++i]);
        else if (arg == "--deliveries" && hasValue) o.deliveries = @(argv[++i]);
        else if (arg == "--every" && hasValue) o.every = atof(argv[++i]);
        else if (arg == "--precise") o.precise = YES;
        else if (arg == "--light") o.light = YES;
        else if (arg == "--sections") o.sections = YES;
        else {
            VibeWaveformProbeUsage();
            return 64;
        }
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        fprintf(stderr, "no file at %s\n", path.UTF8String);
        return 66;
    }
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:o.style];
    AudioWaveformLoader *loader = [[AudioWaveformLoader alloc] init];
    loader.analysis = (VibeWaveformAnalysis){.bands = [WaveformRendererRegistry readsBandsForIdentifier:style]};
    // The loader posts its progress to main, so it decodes off main.
    __block CodableAudioWaveform *result = nil;
    __block BOOL done = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CodableAudioWaveform *loaded = [loader load:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            result = loaded;
            done = YES;
        });
    });
    VibeBenchComponentsSpinMainUntil(^BOOL {
        return done;
    });
    if (!result) {
        fprintf(stderr, "the loader could not decode %s\n", path.UTF8String);
        return 65;
    }
    AudioWaveform *waveform = result.waveform;
    double rate = waveform->sampleRate();
    printf("%s: %.3f s at %.0f Hz, %u-frame bins%s\n", path.lastPathComponent.UTF8String,
           (double)waveform->totalFrames() / rate, rate, waveform->binFrames(), waveform->hasBands() ? ", bands" : "");
    // One zoom for every picture, the complete waveform's.
    double fraction = VibeWaveformProbeFraction(o, VibeWaveformProbeRenderer(o, style, [CALayer layer]), waveform);
    if (o.out) {
        CGImageRef image = VibeWaveformProbeNewImage(o, style, fraction, path, result, loader);
        if (!image || !VibeWaveformProbeWrite(image, o.out)) {
            fprintf(stderr, "could not draw %s with %s\n", o.out.UTF8String, style.UTF8String);
            CGImageRelease(image);
            return 70;
        }
        CGImageRelease(image);
        printf("%s: %s, %.3f s across %.0f pt, %.0f frames a point\n", o.out.UTF8String, style.UTF8String,
               fraction * (double)waveform->totalFrames() / rate, o.width,
               fraction * (double)waveform->totalFrames() / o.width);
    }
    if (o.deliveries) {
        [NSFileManager.defaultManager createDirectoryAtPath:o.deliveries withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableArray<CodableAudioWaveform *> *all =
                [VibeWaveformProbeReplay(path, waveform->hasBands(), o.every) mutableCopy];
        [all addObject:result];
        for (NSUInteger i = 0; i < all.count; i++) {
            @autoreleasepool {
                CGImageRef image = VibeWaveformProbeNewImage(o, style, fraction, path, all[i], nil);
                NSString *file = [o.deliveries stringByAppendingPathComponent:[NSString stringWithFormat:@"%03lu.png", (unsigned long)i]];
                if (image) {
                    VibeWaveformProbeWrite(image, file);
                }
                CGImageRelease(image);
            }
        }
        printf("%s: %lu deliveries, the last complete\n", o.deliveries.UTF8String, (unsigned long)all.count);
    }
    if (o.sections) {
        VibeWaveformProbePrintSections(waveform);
    }
    if (o.levelsStep > 0) {
        VibeWaveformProbePrintLevels(o, waveform, fraction);
    }
    return 0;
}

static void VibeBenchComponentsRegisterWaveformProbe(void) {
    VibeBenchComponentsSetWaveformProbe(VibeWaveformProbe);
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterWaveformProbe)

#endif
