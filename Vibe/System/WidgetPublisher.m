//
//  WidgetPublisher.m
//  Vibe
//
//  See WidgetPublisher.h.
//

#import "WidgetPublisher.h"

#import <notify.h>

#import "AppSettings.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "NSURL+Hash.h"
#import "NowPlayingRules.h"
#import "PlatformColor.h"           // VibeHexStringFromColor, the palette signature
#import "PlatformImage.h"
#if !TARGET_OS_OSX
#import "Vibe-Swift.h"              // VibeWidgetReloader; the mac loads it from a bundle
#endif
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#import "AppTheme.h"
#import "NSImage+Util.h"
#else
#import "PlayerDisplaySettings.h"
#endif

// How far the real playhead may drift from what the widget would extrapolate
// before the snapshot is republished. It is a seek detector: playing straight
// through never trips it, because the widget's own arithmetic is right. Looser
// than the lock screen's, because a widget entry is minutes of wall clock.
static const NSTimeInterval kWidgetPositionTolerance = 2.0;

// The published artwork's longest side, in pixels. The widget draws it at 67pt
// and again blurred as the background, so 256 is generous at 3x (2x on a Mac).
static const CGFloat kWidgetArtworkSide = 256;

// The strip the widget draws, in points; it stretches to whatever the widget
// gives it, so only the ASPECT and the bar count really matter here. Baked to
// the medium widget's shape, which is the taller of the two — the small
// family's thinner strip scales down cleanly, where the reverse would stretch
// the envelope's amplitude up. 3x because that is every current iPhone, and a
// Mac's 2x only scales it down.
static const CGSize  kWidgetWaveformSize  = (CGSize){320, 64};
static const CGFloat kWidgetWaveformScale = 3;

// The longest a track change holds its reload for the cover and the strip.
// TRAP: while the app is frontmost, WidgetKit defers a reload asked for while
// another is still rendering until 5 s after that one began — and a playing
// timeline takes ~1.5 s to render, while a track change is three writes: the
// plist at once, the cover when its decode lands, the strip when its bake
// does. Reloading per write showed the title at once and the cover and strip
// 6-7 s later. Held, the three are one reload, done in ~2 s.
static const NSTimeInterval kWidgetTrackChangeHold = 1.5;

// An image the widget draws, or its absence: a file left from an earlier write
// would be drawn in its place.
static void VibeWidgetWriteImage(CGImageRef image, NSURL *url) {
    NSData *data = VibeEncodedImageData(image);
    if (data) {
        [data writeToURL:url atomically:YES];
    }
    else if (url) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
}

// VibeWidgetReloader's two class methods, for a class the mac only has as a
// runtime lookup.
@protocol VibeWidgetReloading <NSObject>
+ (void)reload;
+ (void)queryPlaced:(void (^)(BOOL placed))completion;
@end

// The reloader, loaded on the mac the first time it is asked for — which is
// only ever once a widget may exist (VibeWidgetState.widgetMayBePlaced, the
// read signal) — so an app with none never loads WidgetKit. Only ever called
// on the publish queue, which reloads and queries, so the load never blocks
// main. Nil only if the bundle failed to load, and every caller treats that as
// "no WidgetKit to tell".
static Class<VibeWidgetReloading> _Nullable VibeWidgetReloaderClass(void) {
#if TARGET_OS_OSX
    static Class reloader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL
                URLByAppendingPathComponent:@"VibeWidgetCenter.bundle"];
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSError *error = nil;
        if ([bundle loadAndReturnError:&error]) {
            reloader = [bundle classNamed:@"VibeWidgetReloader"];
            LogInfo(@"Widget: loaded %@ on the %@ thread", url.lastPathComponent,
                    NSThread.isMainThread ? @"main" : @"publish");
        }
        else {
            LogError(@"Widget: could not load %@: %@", url.lastPathComponent, error);
        }
    });
    return reloader;
#else
    return (Class<VibeWidgetReloading>)VibeWidgetReloader.class;
#endif
}

@implementation WidgetPublisher {
    // What the widget was last told. nil until the first update while a
    // widget is placed, and again whenever republish forgets it.
    VibeWidgetState      *_published;
    // The track that snapshot describes, held only to compare identity on the
    // 3 Hz tick. A pointer compare, deliberately: AudioTrack.cacheKey stats the
    // file and hashes its path, and its failure path does not memoize — on a
    // dropped mount that would be a blocking syscall three times a second.
    // Strong, so closing a track is a change to nil, never nil meeting nil.
    AudioTrack           *_publishedTrack;
    // The image the artwork file holds, nil for none: compared by identity,
    // so a cover that appears, is replaced or goes away is written again.
    VibeImage            *_artworkOnDisk;
    // The track the plist on disk names, so the sweep after the next commit
    // can keep that track's images through one more publish.
    NSString             *_committedKey;

    // The last complete envelope offered, and the track it came from, so a
    // settings change can re-bake without the card being asked again.
    CodableAudioWaveform *_waveform;
    AudioTrack           *_waveformTrack;
    // Everything the bake reads. A settings change that does not move one of
    // these is not a re-bake — which is what makes this safe to hang off
    // every settings change, whose posters include a continuous slider and a
    // colour well.
    NSString             *_bakedSignature;
    // The bake not yet started, so the next request can cancel it. TRAP: the
    // gain slider posts a distinct value per half-dB of a drag, and each is a
    // new signature — without this a one-second drag queued dozens of bakes,
    // all but the last thrown away after they ran.
    dispatch_block_t      _pendingBake;
    // The cover's dominant colour and the image it came from (artworkColor).
    __weak VibeImage     *_artworkColorImage;
    VibeColor            *_artworkColor;
    // Queue-only: whether a reload is already enqueued behind the writes.
    BOOL                  _reloadQueued;
    // The track-change hold (kWidgetTrackChangeHold): whether one is open, the
    // generation that drops a deadline a newer hold replaced, and whether a
    // write made meanwhile owes the reload the hold's end sends.
    BOOL                  _holdingReload;
    NSUInteger            _reloadHoldGeneration;
    BOOL                  _reloadOwed;

    // The theme every snapshot carries (VibeWidgetState.theme), nil on iOS,
    // and the inputs of the placeholder images last written.
    NSDictionary         *_theme;
    NSString             *_placeholderSignature;

    // Whether at least one widget is placed, as last known. Two sources,
    // because each can only be right about one direction: WidgetKit's own
    // answer (queryPlacedOnlyIfMarked:) is authoritative but asked only at
    // launch and on foreground, so it is what turns this OFF; the extension's
    // read signal arrives the instant a widget renders, wherever the app is,
    // so it is what turns it ON. While NO, nothing is computed, captured or written: every
    // entry point returns at this flag, and updateWithTrack: only records its
    // inputs (below) for republish to replay.
    BOOL                  _widgetPlaced;
    int                   _readToken;

    // The last update while no widget was placed, as handed in — a quiet tick
    // with nobody looking is these stores and nothing else. _heldAt is 0 when
    // there is none.
    __weak AudioTrack    *_heldTrack;
    NSTimeInterval        _heldPosition;
    NSTimeInterval        _heldDuration;
    CFAbsoluteTime        _heldAt;
    BOOL                  _heldPlaying;
    BOOL                  _heldStartPending;

    dispatch_queue_t      _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Serial, and the only writer of the shared container: the widget
        // reads a plist that names files, so an image must never land after
        // the plist that describes it, and two bakes must never interleave
        // writing the same two PNGs.
        _queue = dispatch_queue_create("com.commonwealthrecordings.Vibe.widget-publish",
                                       DISPATCH_QUEUE_SERIAL);
#if !TARGET_OS_OSX
        // The mac shell calls settingsDidChange from its live-effect funnel
        // instead; its settings post no notification.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(settingsDidChange)
                                                   name:VibeDisplaySettingsDidChangeNotification
                                                 object:nil];
#endif
        // The extension's "a widget just read the snapshot", on main so it is
        // ordered with everything else that touches _published.
        __weak WidgetPublisher *weakSelf = self;
        _readToken = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kVibeWidgetReadNotification, &_readToken,
                                 dispatch_get_main_queue(), ^(int token) {
            [weakSelf setWidgetPlaced:YES];
        });
        // Asked only if a widget has rendered since WidgetKit last said none:
        // with none ever placed, launch loads nothing and asks nothing.
        [self queryPlacedOnlyIfMarked:YES];
    }
    return self;
}

- (void)dealloc {
    if (_readToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_readToken);
    }
}

#pragma mark - Whether anyone is looking

// Only while one is placed: nothing can turn the flag on but the read signal,
// so with none placed there is nothing to ask.
- (void)refreshPlaced {
    if (_widgetPlaced) {
        [self queryPlacedOnlyIfMarked:NO];
    }
}

// On the publish queue, never main: the mark check resolves the container,
// which asks the container manager over XPC, and the first query loads
// VibeWidgetCenter.bundle and with it WidgetKit and SwiftUI. Neither belongs
// on a launch's main thread, and the answer is only ever a flag.
- (void)queryPlacedOnlyIfMarked:(BOOL)onlyIfMarked {
    __weak WidgetPublisher *weakSelf = self;
    dispatch_async(_queue, ^{
        if (onlyIfMarked && !VibeWidgetState.widgetMayBePlaced) {
            return;
        }
        Class<VibeWidgetReloading> reloader = VibeWidgetReloaderClass();
        if (!reloader) {
            return;     // nothing could be told anyway; the flag stays off
        }
        [reloader queryPlaced:^(BOOL placed) {
            if (!placed) {
                // The next launch loads nothing until a widget renders again.
                [VibeWidgetState forgetWidget];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setWidgetPlaced:placed];
            });
        }];
    });
}

- (void)setWidgetPlaced:(BOOL)placed {
    if (_widgetPlaced == placed) {
        return;
    }
    _widgetPlaced = placed;
    LogInfo(@"Widget: %@", placed ? @"now publishing" : @"no widget placed; publishing stops");
    if (placed) {
        [self republish];
    }
}

// The gate has just opened. Nothing was worked out while it was shut, so the
// last input is replayed against a forgotten snapshot — a track change, which
// from the widget's side is exactly what happened, the playhead advanced by
// the time it waited. A widget added while a track plays in the background
// renders once from whatever was on disk, its read lands here, and the next
// render is current.
- (void)republish {
    [self captureTheme];
    _published      = nil;
    _publishedTrack = nil;
    _bakedSignature = nil;
    _artworkOnDisk  = nil;
    if (!_heldAt) {
        return;     // nothing handed over yet; the first update publishes
    }
    NSTimeInterval position = _heldPosition;
    if (_heldPlaying && !_heldStartPending) {
        position += CFAbsoluteTimeGetCurrent() - _heldAt;   // clamped on read
    }
    _heldAt = 0;
    [self updateWithTrack:_heldTrack position:position duration:_heldDuration
                  playing:_heldPlaying startPending:_heldStartPending];
}

#pragma mark - What is playing

- (void)updateWithTrack:(AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending {
    if (!_widgetPlaced) {
        _heldTrack        = track;
        _heldPosition     = position;
        _heldDuration     = duration;
        _heldPlaying      = playing;
        _heldStartPending = startPending;
        _heldAt           = CFAbsoluteTimeGetCurrent();
        return;
    }
    VibeImage *artwork = track.cachedArt;
    BOOL trackChanged = (track != _publishedTrack);
    // TRAP: cachedArt is nil until the artwork DECODES, so a track change
    // almost always arrives before there is any art — and writing nil deletes
    // the file. Keyed on the track alone, the cover was cleared and never
    // written back. _artworkOnDisk re-fires the write on the first tick that
    // sees decoded art, or different art. A nil is artlessness only once the
    // art has resolved — the window's own rule — since a folder cover evicted
    // from its cache reads nil too until it decodes again; folder art switched
    // off is the nil that must clear.
    BOOL writeArtwork = trackChanged || artwork != _artworkOnDisk;
    if (!artwork && writeArtwork && !trackChanged) {
        AudioTrackMetadata *metadata = track.metadata;
        writeArtwork = metadata && !metadata.artNeedsLoad && !metadata.isArtLoadPending;
    }

    if (!writeArtwork && ![self needsPublishForTrack:track playing:playing duration:duration
                                            position:position startPending:startPending]) {
        return;
    }

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    next.trackKey     = track.url.pathKey;
    next.playing      = playing;
    next.duration     = duration;
    next.position     = position;
    next.positionDate = [NSDate date];
    next.theme        = _theme;

    _published      = next;
    _publishedTrack = track;
    if (trackChanged) {
        // The envelope is kept only if it was offered FOR the track being
        // adopted. The card can offer before this call or after it — returning
        // to an already-played track offers first, because the coordinator has
        // the snapshot in hand and starts no load — so the pairing is checked
        // rather than the order assumed.
        if (_waveformTrack != track) {
            _waveform      = nil;
            _waveformTrack = nil;
        }
        // A bake still queued is the outgoing track's, and holds its envelope.
        if (_pendingBake) {
            dispatch_block_cancel(_pendingBake);
            _pendingBake = nil;
        }
        _bakedSignature = nil;
        _artworkOnDisk  = nil;
    }
    if (trackChanged && track) {
        [self beginReloadHold];
    }
    [self commitState:next artwork:artwork writeArtwork:writeArtwork];

    // An offer that arrived before its track was adopted bakes now; so does
    // art that decoded after the offer, for the one theme that reads it — the
    // signature decides, so for every other theme this is a compare and out.
    if (_waveform && (trackChanged || writeArtwork)) {
        [self bakeWaveformIfNeeded];
    }
    [self endReloadHoldIfComplete];
}

// The one place the plist is written. TRAP: the images must land before the
// plist. The widget reads the plist first and loads the files it names, so a
// plist that arrives first pairs the new title with no artwork for as long as
// the encode takes. The images are named by track, so the plist can never
// name another track's; the sweep runs LAST and spares the outgoing track's
// set, so an extension that read the previous plist a moment ago still finds
// the images it names.
- (void)commitState:(VibeWidgetState *)state artwork:(VibeImage *)artwork
       writeArtwork:(BOOL)writeArtwork {
    if (writeArtwork) {
        _artworkOnDisk = artwork;
    }
    // Taken here, on main, and only the CGImage crosses to the queue: on the
    // mac this is the NSImage the header is drawing, and NSImage is not safe
    // to draw concurrently (the Now Playing artwork trap, System/CLAUDE.md).
    CGImageRef cgArtwork = writeArtwork ? CGImageRetain(VibeCGImageOfImage(artwork)) : NULL;
    NSString *outgoingKey = _committedKey;
    _committedKey = state.trackKey;
    BOOL sweep = !VibeNowPlayingStringsEqual(outgoingKey, state.trackKey);
    BOOL reload = [self reloadAfterWrite];
    dispatch_async(_queue, ^{
        if (writeArtwork) {
            [self writeArtwork:cgArtwork toURL:state.artworkURL];
            CGImageRelease(cgArtwork);
        }
        [state save];
        if (reload) {
            [self scheduleReload];
        }
        if (sweep) {
            NSArray<NSString *> *keep = @[state.trackKey ?: @"", outgoingKey ?: @""];
            for (NSURL *url in [VibeWidgetState imageURLsNotForTrackKeys:keep]) {
                [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            }
        }
    });
}

// On _queue. One reload per burst of writes: the first write to land enqueues
// the reload behind everything already queued, and a write queued meanwhile
// rides the same one. A track change with an envelope in hand is two writes
// and was two reloads — each an extension launch rendering a whole timeline.
- (void)scheduleReload {
    if (_reloadQueued) {
        return;
    }
    _reloadQueued = YES;
    dispatch_async(_queue, ^{
        self->_reloadQueued = NO;
        [VibeWidgetReloaderClass() reload];
    });
}

// Main, as a write is enqueued: whether that write sends the reload itself,
// or an open hold owes it.
- (BOOL)reloadAfterWrite {
    if (_holdingReload) {
        _reloadOwed = YES;
        return NO;
    }
    return YES;
}

// Main. Restarted by every track change, so a run of skips reloads once, when
// it stops.
- (void)beginReloadHold {
    _holdingReload = YES;
    NSUInteger generation = ++_reloadHoldGeneration;
    __weak WidgetPublisher *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWidgetTrackChangeHold * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf endReloadHoldForGeneration:generation];
    });
}

// The hold ends early once both the cover and the strip are queued for
// writing. A track with no art has nothing to wait for but the deadline.
- (void)endReloadHoldIfComplete {
    if (_holdingReload && _artworkOnDisk && _bakedSignature) {
        [self endReloadHoldForGeneration:_reloadHoldGeneration];
    }
}

- (void)endReloadHoldForGeneration:(NSUInteger)generation {
    if (!_holdingReload || generation != _reloadHoldGeneration) {
        return;
    }
    _holdingReload = NO;
    if (_reloadOwed) {
        _reloadOwed = NO;
        // Queued behind every write the hold covered, so the reload follows them.
        dispatch_async(_queue, ^{
            [self scheduleReload];
        });
    }
}

// Republished on a structural change or a seek, never on the tick that merely
// advanced the playhead — that one the widget computes for itself. Cheapest
// tests first: the scalars and the pointer, then the two lines (a tagged
// file's are stored strings), and the drift arithmetic last.
- (BOOL)needsPublishForTrack:(AudioTrack *)track
                     playing:(BOOL)playing
                    duration:(NSTimeInterval)duration
                    position:(NSTimeInterval)position
                startPending:(BOOL)startPending {
    VibeWidgetState *last = _published;
    if (!last || track != _publishedTrack) {
        return YES;
    }
    if (last.hasTrack != (track != nil) || last.playing != playing) {
        return YES;
    }
    if (fabs(last.duration - duration) > 0.5) {
        return YES;
    }
    // A track whose tags land after it started playing keeps its identity but
    // changes its lines; that is a publish, and it is the only reason the
    // strings are read at all.
    if (!VibeNowPlayingStringsEqual(last.title, track.displayTitle)
            || !VibeNowPlayingStringsEqual(last.artist, track.displayArtist)) {
        return YES;
    }
    if (startPending) {
        return NO;      // position is pinned at 0 while the open runs; not a seek
    }
    // The same seek test the lock screen uses, with its own tolerance — the
    // parameter exists for exactly this second caller (System/NowPlayingRules.h).
    return VibeNowPlayingPositionIsDirty(last.position,
                                         CFDateGetAbsoluteTime((__bridge CFDateRef)last.positionDate),
                                         1.0, last.playing, position,
                                         CFAbsoluteTimeGetCurrent(), kWidgetPositionTolerance);
}

- (void)publishEmptyForTermination {
    if (!_widgetPlaced) {
        return;     // nothing was ever written, so nothing claims a track
    }
    // Strips the empty state never shows are not worth waiting for.
    if (_pendingBake) {
        dispatch_block_cancel(_pendingBake);
    }
    // A hold with no deadline: every write from here owes its reload to the
    // one sent below.
    _holdingReload = YES;
    _reloadHoldGeneration++;
    if (_published.hasTrack) {
        VibeWidgetState *empty = [[VibeWidgetState alloc] init];
        empty.theme = _theme;
        _published = empty;
        _publishedTrack = nil;
        [self commitState:empty artwork:nil writeArtwork:NO];
    }
    BOOL reload = _reloadOwed;
    _reloadOwed = NO;
    // Behind every queued write, so the widget's last read is the empty state.
    dispatch_sync(_queue, ^{
        if (reload) {
            [VibeWidgetReloaderClass() reload];
        }
    });
}

#pragma mark - Settings

- (void)settingsDidChange {
    // Not captured while nobody looks: republish captures and bakes when one
    // appears.
    if (!_widgetPlaced) {
        return;
    }
    if ([self captureTheme] && _published) {
        // A copy: the snapshot in _published may still be on its way to disk.
        VibeWidgetState *next = [_published copy];
        next.theme = _theme;
        _published = next;
        [self commitState:next artwork:nil writeArtwork:NO];
    }
    // After the theme, since whether the strip needs a light half follows it.
    [self bakeWaveformIfNeeded];
}

#if TARGET_OS_OSX
static NSArray<NSNumber *> *VibeWidgetComponents(NSColor *color) {
    NSColor *srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return srgb ? @[@(srgb.redComponent), @(srgb.greenComponent), @(srgb.blueComponent),
                    @(srgb.alphaComponent)] : nil;
}

// One appearance's palette. Two cases, because the widget's surface is its
// own dark tile unless the theme paints one:
//   - a solid theme paints the surface, so the palette is the window's whole
//     look for that side — the background, and the labels resolved over their
//     defaults (the dark defaults' white text would vanish on a light cover);
//     buttons the theme leaves unset follow the title, not the factory white.
//   - otherwise only what the theme SETS, and the widget reads only the dark
//     side's: a color picked for a light window must not land on a dark tile.
static NSDictionary *VibeWidgetPalette(AppTheme *theme, BOOL isDark) {
    NSMutableDictionary *palette = [NSMutableDictionary dictionary];
    BOOL paintsSurface = [theme.windowBackgroundStyle isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    NSColor *title = paintsSurface ? [theme displayColorForBase:kVibeThemeColorTitle dark:isDark]
                                   : [theme titleColorForDark:isDark];
    NSColor *artist = paintsSurface ? [theme displayColorForBase:kVibeThemeColorArtist dark:isDark]
                                    : [theme artistColorForDark:isDark];
    NSColor *buttonFallback = paintsSurface ? title : nil;
    palette[kVibeWidgetColorTitle]      = VibeWidgetComponents(title);
    palette[kVibeWidgetColorArtist]     = VibeWidgetComponents(artist);
    palette[kVibeWidgetColorPlayButton] =
            VibeWidgetComponents([theme colorForBase:kVibeThemeColorPlayButton dark:isDark] ?: buttonFallback);
    palette[kVibeWidgetColorNextButton] =
            VibeWidgetComponents([theme colorForBase:kVibeThemeColorNextButton dark:isDark] ?: buttonFallback);
    if (paintsSurface) {
        palette[kVibeWidgetColorBackground] =
                VibeWidgetComponents([theme displayColorForBase:kVibeThemeColorWindowBackground dark:isDark]);
    }
    return palette;
}

// The glyph the window draws, when the theme changed it from the factory's;
// nil is the widget's own glyph, which is the factory one.
static NSString *VibeWidgetGlyph(NSString *glyph, NSString *factory) {
    NSString *resolved = glyph.length ? [AppTheme resolvedGlyph:glyph factory:factory] : factory;
    return [resolved isEqualToString:factory] ? nil : resolved;
}

// One side's no-artwork image, at the cover's published size.
static CGImageRef VibeWidgetPlaceholder(NSString *reference) CF_RETURNS_RETAINED {
    NSImage *image = [[AppTheme imageForReference:reference]
            resizedImage:NSMakeSize(kWidgetArtworkSide, kWidgetArtworkSide)];
    return CGImageRetain(VibeCGImageOfImage(image));
}
#endif

// Main. Takes the theme's current answer, and says whether anything the widget
// draws moved — the live-effect funnel calls this on every theme edit,
// continuous drags included, so an unmoved theme must cost a compare.
- (BOOL)captureTheme {
#if TARGET_OS_OSX
    AppTheme *appTheme = AppSettings.sharedInstance.currentTheme;
    // Single mode is one look whatever the appearance, kept in the dark slots.
    NSMutableDictionary *theme = [NSMutableDictionary dictionary];
    theme[kVibeWidgetThemeDark]       = VibeWidgetPalette(appTheme, YES);
    theme[kVibeWidgetThemeLight]      = VibeWidgetPalette(appTheme, appTheme.isSingleMode);
    theme[kVibeWidgetThemePlayGlyph]  = VibeWidgetGlyph(appTheme.playButtonGlyph,
                                                        kVibeThemePlayButtonGlyphDefault);
    theme[kVibeWidgetThemePauseGlyph] = VibeWidgetGlyph(appTheme.pauseButtonGlyph,
                                                        kVibeThemePauseButtonGlyphDefault);
    theme[kVibeWidgetThemeNextGlyph]  = VibeWidgetGlyph(appTheme.nextButtonGlyph,
                                                        kVibeThemeNextButtonGlyphDefault);
    // The light image only for a light surface, the one place it is drawn.
    // References, not images: single mode already answers the dark one for
    // the light slot.
    NSString *darkReference = [appTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark];
    NSString *lightReference = theme[kVibeWidgetThemeLight][kVibeWidgetColorBackground]
            ? [appTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight] : nil;
    NSString *placeholderSignature = [NSString stringWithFormat:@"%@|%@", darkReference, lightReference];
    BOOL themeMoved = ![theme isEqualToDictionary:_theme ?: @{}];
    BOOL placeholderMoved = !VibeNowPlayingStringsEqual(placeholderSignature, _placeholderSignature);
    _theme = theme;
    if (placeholderMoved) {
        _placeholderSignature = placeholderSignature;
        // Drawn on main, like the cover, and written ahead of the commit that
        // follows every move, whose reload shows them.
        CGImageRef dark = VibeWidgetPlaceholder(darkReference);
        CGImageRef light = lightReference ? VibeWidgetPlaceholder(lightReference) : NULL;
        dispatch_async(_queue, ^{
            VibeWidgetWriteImage(dark, [VibeWidgetState placeholderURLForDark:YES]);
            VibeWidgetWriteImage(light, [VibeWidgetState placeholderURLForDark:NO]);
            CGImageRelease(dark);
            CGImageRelease(light);
        });
    }
    return themeMoved || placeholderMoved;
#else
    return NO;
#endif
}

#pragma mark - The waveform strip

- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track {
    if (!waveform || !track) {
        return;
    }
    // Kept whichever side of the adoption it lands on; only the bake waits for
    // the track to be the published one, so an offer for a page the user is
    // merely swiping past cannot overwrite the strip.
    _waveform      = waveform;
    _waveformTrack = track;
    if (track == _publishedTrack) {
        [self bakeWaveformIfNeeded];
    }
}

// The cover's dominant colour, for the album_art theme; nil until the art
// decodes, or for art too gray to read. Memoized per image: the bake is asked
// on every tick of a settings slider, and each answer resamples the cover.
- (VibeColor *)artworkColor {
    VibeImage *art = _publishedTrack.cachedArt;
    if (!art) {
        return nil;
    }
    if (art != _artworkColorImage) {
        _artworkColorImage = art;
        _artworkColor = VibeDominantColorOfImage(art);
    }
    return _artworkColor;
}

- (void)bakeWaveformIfNeeded {
    CodableAudioWaveform *waveform = _waveform;
    // _widgetPlaced before the signature is taken, so the bake is still owed.
    if (!waveform || _waveformTrack != _publishedTrack || !_widgetPlaced) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    // The widget's own background is dark, so the strip resolves dark — there
    // is no appearance to follow in a view this process does not own — except
    // a light strip beside it for a theme that paints the light-side surface.
    // With no artwork colour the album_art theme resolves to Mono's.
    VibeColor *artworkColor = self.artworkColor;
    WaveformTheme *lightTheme = nil;
#if TARGET_OS_OSX
    // The window's waveform exactly: the theme's style, palette, gradient and
    // bar geometry, and the Normalize and Gain settings.
    AppTheme *appTheme = settings.currentTheme;
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:appTheme.waveformStyle];
    const BOOL normalize = settings.waveformNormalize;
    const float gainDB = (float)settings.waveformGainDB;
    const double barDensity = appTheme.waveformBarDensity;
    const double barWidth = appTheme.waveformBarWidth;
    WaveformTheme *theme = [WaveformTheme themeForAppTheme:appTheme isDark:YES
                                              artworkColor:artworkColor];
    // Not in single mode, whose light side is its dark one (captureTheme): the
    // widget then finds no light strip and draws the dark pair.
    if (_theme[kVibeWidgetThemeLight][kVibeWidgetColorBackground] && !appTheme.isSingleMode) {
        lightTheme = [WaveformTheme themeForAppTheme:appTheme isDark:NO artworkColor:artworkColor];
    }
#else
    // The widget's own style when the user picked one, else the app's. nil
    // means "match app", and resolveStyleIdentifier: turns an unregistered or
    // absent identifier into the default either way.
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:settings.widgetWaveformStyle ?: settings.waveformStyle];
    // The scrubber draws the normalized mapping with no gain and the style's
    // own bars — Normalize, Gain and bar geometry are macOS settings — and the
    // strip matches it.
    const BOOL normalize = YES;
    const float gainDB = 0;
    const double barDensity = 1;
    const double barWidth = 1;
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                      isDark:YES
                                                artworkColor:artworkColor
                                                customPlayed:[settings waveformCustomPlayedColorForDark:YES]
                                              customUnplayed:[settings waveformCustomUnplayedColorForDark:YES]];
#endif
    // The signature is the RESOLVED palette, not the inputs: a cover arriving
    // under a theme that ignores it changes nothing here and bakes nothing,
    // while under album_art it moves both colours and bakes once more.
    // Nothing of the track: every track change clears it.
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%d|%d|%.4f|%.4f|%.4f",
                           style, VibeHexStringFromColor(theme.playedColor) ?: @"",
                           VibeHexStringFromColor(theme.unplayedColor) ?: @"",
                           VibeHexStringFromColor(lightTheme.playedColor) ?: @"",
                           VibeHexStringFromColor(lightTheme.unplayedColor) ?: @"",
                           theme.flatFill, normalize, gainDB, barDensity, barWidth];
    if (VibeNowPlayingStringsEqual(signature, _bakedSignature)) {
        return;
    }
    _bakedSignature = signature;
    // A bake still waiting behind the queue is superseded, not run. One that
    // has started runs to completion; this one then lands after it.
    if (_pendingBake) {
        dispatch_block_cancel(_pendingBake);
    }
    VibeWidgetState *state = _published;
    BOOL reload = [self reloadAfterWrite];
    _pendingBake = dispatch_block_create(0, ^{
        // The whole envelope in each side's colours, played and unplayed. The
        // widget reveals the played one up to the playhead, which is what
        // keeps a moving playhead free of a re-render. With no light palette
        // the light pair is removed, not left from an earlier theme.
        for (int strip = 0; strip < 4; strip++) {
            BOOL played = (strip & 1) != 0;
            BOOL light = (strip & 2) != 0;
            CGImageRef baked = light && !lightTheme ? NULL : [WaveformRendererRegistry newImageForCodableWaveform:waveform
                    identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
                      progress:played ? 1 : 0 dark:!light theme:light ? lightTheme : theme
                    barDensity:barDensity barWidth:barWidth normalize:normalize gainDB:gainDB];
            VibeWidgetWriteImage(baked, [state waveformURLPlayed:played light:light]);
            CGImageRelease(baked);
        }
        // The plist names nothing about the waveform, but the widget only
        // re-renders when WidgetKit is told to.
        if (reload) {
            [self scheduleReload];
        }
    });
    dispatch_async(_queue, _pendingBake);
    [self endReloadHoldIfComplete];
}

#pragma mark - Artwork

// The cover bounded to kWidgetArtworkSide on its longer edge, never enlarged,
// and opaque so it encodes as JPEG. Only a BOUND: the widget draws it
// scaledToFill and clipped, blurred or not, so the square is cut where it is
// drawn and cutting it here too would only throw pixels away twice.
static CGImageRef VibeWidgetBoundedArtwork(CGImageRef artwork) CF_RETURNS_RETAINED {
    CGFloat width = CGImageGetWidth(artwork);
    CGFloat height = CGImageGetHeight(artwork);
    CGFloat longest = MAX(width, height);
    if (longest <= 0) {
        return NULL;
    }
    CGFloat scale = MIN(1, kWidgetArtworkSide / longest);
    size_t boundedWidth = MAX(1, (size_t)round(width * scale));
    size_t boundedHeight = MAX(1, (size_t)round(height * scale));
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = space ? CGBitmapContextCreate(NULL, boundedWidth, boundedHeight, 8, 0, space,
                                                         (CGBitmapInfo)kCGImageAlphaNoneSkipLast) : NULL;
    if (space) {
        CGColorSpaceRelease(space);
    }
    if (!context) {
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, boundedWidth, boundedHeight), artwork);
    CGImageRef bounded = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return bounded;
}

// Removing the file for a track with no art is as load-bearing as writing one:
// the file would otherwise survive from an earlier decode of the same track.
- (void)writeArtwork:(CGImageRef)artwork toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    CGImageRef bounded = artwork ? VibeWidgetBoundedArtwork(artwork) : NULL;
    VibeWidgetWriteImage(bounded, url);     // opaque, so JPEG
    if (bounded) {
        CGImageRelease(bounded);
    }
}

@end
