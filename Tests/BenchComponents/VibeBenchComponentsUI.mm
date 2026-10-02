//
//  VibeBenchComponentsUI.mm
//  VibeBenchComponents
//
//  The UI layer offscreen: the playlist's cells, the Now Playing placeholder,
//  the formatters and display names the ticks read, and the waveform
//  renderers' layer work. With VIBE_BENCH_COMPONENTS_UI_DUMP set to a directory, each
//  prepare also writes what its subject draws there, so two builds' pictures
//  can be compared byte for byte.
//

#import "VibeBenchComponents.h"

#import <AppKit/AppKit.h>

#import "AppSettings+Mac.h"
#import "AppTheme.h"
#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "CloudTransferRegistry.h"
#import "DetailedAudioWaveformRenderer.h"
#import "Formatters.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PlaylistTextCell.h"
#import "SonicCirrusWaveformRenderer.h"
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
#import "ThreeBandWaveformRenderer.h"
#endif
#import "WaveformMorphEngine.h"

#include <cmath>

@interface PlaylistController (VibeBenchComponentsUI) <CloudTransferRegistryObserver>
@end

// MARK: - Fixtures

static void VibeBenchComponentsUIDump(NSString *name, NSData *bytes) {
    const char *directory = getenv("VIBE_BENCH_COMPONENTS_UI_DUMP");
    if (!directory || !bytes) {
        return;
    }
    NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:name];
    [bytes writeToFile:path atomically:YES];
}

static NSData *VibeBenchComponentsUIPixels(NSView *view) {
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    return [NSData dataWithBytes:rep.bitmapData length:(NSUInteger)(rep.bytesPerRow * rep.pixelsHigh)];
}

static void VibeBenchComponentsUIEnsureApplication(void) {
    [NSApplication sharedApplication];
}

// Untagged rows, as a folder of unnamed rips lists, plus scripts that fall
// back to other fonts.
static NSArray<NSString *> *VibeBenchComponentsUITitles(void) {
    return @[@"01 Opening_Theme", @"Björk - Jóga", @"坂本龍一 - Merry Christmas Mr. Lawrence",
             @"🎵 Song with an emoji 🎶", @"فيروز - نسم علينا الهوى", @"Ελληνικά τραγούδια",
             @"A very long title that will certainly be truncated by the column at its usual width",
             @"", @"ÅÄÖ ÇÑ ÿ ğ", @"한국어 노래 제목"];
}

static AudioTrack *VibeBenchComponentsUITaggedTrack(NSString *name) {
    NSString *path = VibeBenchComponentsFile(name);
    if (!path) {
        return nil;
    }
    AudioTrack *track = [AudioTrack withURL:[NSURL fileURLWithPath:path]];
    NSData *art = nil;
    [track installMetadataIfUnresolved:[AudioTrackMetadata metadataWithURL:track.url displayArtData:&art]];
    return track;
}

static NSTextField *VibeBenchComponentsUICellField(NSRect frame) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    PlaylistTextCell *cell = [[PlaylistTextCell alloc] initTextCell:@""];
    field.cell = cell;
    field.editable = NO;
    field.selectable = NO;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    return field;
}

// MARK: - Benchmarks: the playlist's cells

struct VibeBenchComponentsUICells {
    NSTextField *title;
    std::vector<NSAttributedString *> strings;
};

struct VibeBenchComponentsUITable {
    NSWindow *window;
    NSScrollView *scroll;
    PlaylistController *controller;
};

static void VibeBenchComponentsRegisterPlaylist(void) {
    // A title cell drawn, as a row is on every scroll, configure and redraw:
    // each of the titles and a tagged title + artist, twenty times.
    auto cells = std::make_shared<VibeBenchComponentsUICells>();
    VibeBenchComponentsAdd("ui-cell", "title-draw", "draw", [cells]() -> double {
        VibeBenchComponentsUIEnsureApplication();
        cells->title = VibeBenchComponentsUICellField(NSMakeRect(0, 0, 420, 28));
        cells->strings.clear();
        for (NSString *title in VibeBenchComponentsUITitles()) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/%@.mp3", title]];
            cells->strings.push_back([PlaylistTableView titleCellStringForTrack:[AudioTrack withURL:url]]);
        }
        AudioTrack *tagged = VibeBenchComponentsUITaggedTrack(@"mp3-320");
        if (tagged) {
            cells->strings.push_back([PlaylistTableView titleCellStringForTrack:tagged]);
        }
        for (NSUInteger n : {1u, 9u, 42u, 999u, 12345u}) {
            cells->strings.push_back([PlaylistTableView numberCellString:n]);
        }
        cells->strings.push_back([PlaylistTableView durationCellString:@"3:07"]);
        cells->strings.push_back([PlaylistTableView durationCellString:@"1:02:03"]);
        // Each string at each of the three row field sizes, as drawn.
        NSMutableData *pixels = [NSMutableData data];
        for (NSRect frame : {NSMakeRect(0, 0, 420, 28), NSMakeRect(0, 0, 24, 28), NSMakeRect(0, 0, 42, 28)}) {
            NSTextField *field = VibeBenchComponentsUICellField(frame);
            for (NSAttributedString *string : cells->strings) {
                field.attributedStringValue = string;
                [pixels appendData:VibeBenchComponentsUIPixels(field)];
            }
        }
        VibeBenchComponentsUIDump(@"ui-cell-title-draw.raw", pixels);
        return (double)cells->strings.size() * 20;
    }, [cells]() {
        NSTextField *field = cells->title;
        NSBitmapImageRep *rep = [field bitmapImageRepForCachingDisplayInRect:field.bounds];
        for (int i = 0; i < 20; i++) {
            for (NSAttributedString *string : cells->strings) {
                field.attributedStringValue = string;
                [field cacheDisplayInRect:field.bounds toBitmapImageRep:rep];
            }
        }
    });

    // A cloud transfer's progress reaching the gutter: every visible number
    // cell reconfigured in place and the window redisplayed, ten times.
    auto table = std::make_shared<VibeBenchComponentsUITable>();
    VibeBenchComponentsAdd("ui-table", "registry-change", "change", [table]() -> double {
        VibeBenchComponentsUIEnsureApplication();
        table->window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 900)
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        table->window.releasedWhenClosed = NO;
        table->scroll = [PlaylistTableView scrollViewWithFrame:table->window.contentView.bounds];
        [table->window.contentView addSubview:table->scroll];
        table->controller = [[PlaylistController alloc] initWithAudioPlayer:(AudioPlayer *_Nonnull)nil];
        table->controller.tableView = (PlaylistTableView *)table->scroll.documentView;
        NSMutableArray<AudioTrack *> *tracks = [NSMutableArray array];
        for (NSUInteger i = 0; i < 400; i++) {
            NSString *path = [NSString stringWithFormat:@"/tmp/vibe-perf-ui/Track %03lu.mp3", (unsigned long)i];
            [tracks addObject:[AudioTrack withURL:[NSURL fileURLWithPath:path]]];
        }
        [table->controller loadTracks:tracks selectingIndex:3];
        [table->window layoutIfNeeded];
        [table->window displayIfNeeded];
        [CATransaction flush];
        VibeBenchComponentsUIDump(@"ui-table-registry-change.raw", VibeBenchComponentsUIPixels(table->window.contentView));
        return 10;
    }, [table]() {
        for (int i = 0; i < 10; i++) {
            [table->controller cloudTransferRegistryDidChange:CloudTransferRegistry.sharedRegistry];
            [table->window displayIfNeeded];
            [CATransaction flush];
        }
    });
}

// MARK: - Benchmarks: what the UI tick reads

static void VibeBenchComponentsRegisterTick(void) {
    // updateNowPlaying's placeholder, asked on every tick: a thousand asks.
    VibeBenchComponentsAdd("ui-tick", "nowplaying-placeholder", "ask", []() -> double {
        AppTheme *theme = AppSettings.sharedInstance.currentTheme;
        NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        NSAppearance *light = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        NSImage *d = [theme defaultArtworkImageForAppearance:dark];
        NSImage *l = [theme defaultArtworkImageForAppearance:light];
        VibeBenchComponentsUIDump(@"ui-tick-nowplaying-placeholder.txt",
                       [[NSString stringWithFormat:@"%@ %@ %@", NSStringFromSize(d.size), NSStringFromSize(l.size),
                                                   d == l ? @"same" : @"two"] dataUsingEncoding:NSUTF8StringEncoding]);
        return 1000;
    }, []() {
        AppTheme *theme = AppSettings.sharedInstance.currentTheme;
        NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        for (int i = 0; i < 1000; i++) {
            (void)[theme defaultArtworkImageForAppearance:dark];
        }
    });

    // The codec line's two numbers, as fileInfoLine asks them in turn: a
    // thousand lines.
    VibeBenchComponentsAdd("ui-format", "file-info-numbers", "line", []() -> double {
        Formatters *formatters = Formatters.sharedInstance;
        NSMutableString *out = [NSMutableString string];
        for (double value : {0.0, 1.0, 44.1, 48.0, 320.0, 95.5, 1234.5678, -2.25, (double)NAN}) {
            for (NSInteger digits : {0, 1, 2, 3}) {
                [out appendFormat:@"%@\n", [formatters decimalString:value fractionDigits:digits]];
            }
            [out appendFormat:@"%@ %@\n", [formatters sampleRateString:value * 1000], [formatters bpmString:value]];
        }
        VibeBenchComponentsUIDump(@"ui-format-file-info-numbers.txt", [out dataUsingEncoding:NSUTF8StringEncoding]);
        return 1000;
    }, []() {
        Formatters *formatters = Formatters.sharedInstance;
        for (int i = 0; i < 1000; i++) {
            (void)[formatters decimalString:320 fractionDigits:0];
            (void)[formatters sampleRateString:44100];
        }
    });

    // The display names every tick and row configure read: 200 untagged and
    // one tagged row, ten times each.
    auto rows = std::make_shared<std::vector<AudioTrack *>>();
    VibeBenchComponentsAdd("ui-track", "display-names", "row", [rows]() -> double {
        rows->clear();
        NSMutableString *out = [NSMutableString string];
        for (NSUInteger i = 0; i < 200; i++) {
            NSString *title = VibeBenchComponentsUITitles()[i % VibeBenchComponentsUITitles().count];
            NSString *path = [NSString stringWithFormat:@"/tmp/vibe_perf/%@_%lu.flac", title, (unsigned long)i];
            rows->push_back([AudioTrack withURL:[NSURL fileURLWithPath:path]]);
        }
        AudioTrack *tagged = VibeBenchComponentsUITaggedTrack(@"flac-16-44");
        if (tagged) {
            rows->push_back(tagged);
        }
        for (AudioTrack *track : *rows) {
            [out appendFormat:@"%@|%@|%@\n", track.displayTitle, track.displayArtist ?: @"(nil)", track.singleLineTitle];
        }
        VibeBenchComponentsUIDump(@"ui-track-display-names.txt", [out dataUsingEncoding:NSUTF8StringEncoding]);
        return (double)rows->size() * 10;
    }, [rows]() {
        for (int i = 0; i < 10; i++) {
            for (AudioTrack *track : *rows) {
                (void)track.displayTitle;
                (void)track.displayArtist;
            }
        }
    });
}

// MARK: - Benchmarks: the waveform renderers

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

struct VibeBenchComponentsUIRenderer {
    CALayer *parent;
    AudioWaveformRenderer *renderer;
    WaveformMorphEngine *morph;
    std::shared_ptr<AudioWaveform> waveform;
};

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
        cirrus->parent = [CALayer layer];
        cirrus->parent.contentsScale = 2;
        CGRect bounds = CGRectMake(0, 0, 4096, 60);
        cirrus->parent.bounds = bounds;
        cirrus->waveform = VibeBenchComponentsUIWaveform(7);
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
        detailed->parent = [CALayer layer];
        detailed->parent.contentsScale = 2;
        CGRect bounds = CGRectMake(0, 0, 800, 60);
        detailed->parent.bounds = bounds;
        detailed->waveform = VibeBenchComponentsUIWaveform(11);
        detailed->renderer = [[DetailedAudioWaveformRenderer alloc] initWithLayer:detailed->parent bounds:bounds
                                                                           isDark:YES wiggle:NO centered:NO];
        detailed->renderer.normalizesLevels = YES;
        [detailed->renderer updateWaveform:bounds progress:0 waveform:detailed->waveform.get()];
        [detailed->renderer settleMorphImmediately];
        NSMutableData *envelopes = [NSMutableData data];
        DetailedAudioWaveformRenderer *renderer = (DetailedAudioWaveformRenderer *)detailed->renderer;
        for (CGFloat width : {300.0, 801.0, 1600.0, 3000.0, 801.0}) {
            detailed->parent.bounds = CGRectMake(0, 0, width, 60);
            [renderer updateWaveform:detailed->parent.bounds progress:0.4 waveform:detailed->waveform.get()];
            [envelopes appendData:[renderer envelopeSamplesForWaveform:detailed->waveform.get()]];
            [renderer settleMorphImmediately];
        }
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

#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS
    // 3-Band through the same live resize as Detailed's: seven painter's
    // layers under the sides' mask, a bar a point.
    auto threeBand = std::make_shared<VibeBenchComponentsUIRenderer>();
    VibeBenchComponentsAdd("ui-waveform", "three-band-resize", "frame", [threeBand]() -> double {
        threeBand->parent = [CALayer layer];
        threeBand->parent.contentsScale = 2;
        CGRect bounds = CGRectMake(0, 0, 800, 60);
        threeBand->parent.bounds = bounds;
        threeBand->waveform = VibeBenchComponentsUIWaveform(13);
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

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterPlaylist)
VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterTick)
VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterRenderers)
