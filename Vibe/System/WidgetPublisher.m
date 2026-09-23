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
#import "NSURL+Hash.h"
#import "NowPlayingRules.h"
#import "PlatformColor.h"           // VibeHexStringFromColor, the palette signature
#import "PlatformImage.h"
#import "Vibe-Swift.h"              // VibeWidgetReloader; WidgetCenter has no ObjC API
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#import "AppTheme.h"
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

@implementation WidgetPublisher {
    // What the widget was last told. nil until the first update. Kept current
    // whether or not anything is written, so the moment a widget appears the
    // truth is in hand rather than a tick away — and a tick is not guaranteed
    // in the background, where that moment usually comes.
    VibeWidgetState      *_published;
    // The track that snapshot describes, held only to compare identity on the
    // 3 Hz tick. A pointer compare, deliberately: AudioTrack.cacheKey stats the
    // file and hashes its path, and its failure path does not memoize — on a
    // dropped mount that would be a blocking syscall three times a second.
    __weak AudioTrack    *_publishedTrack;
    // Whether the published track's artwork has been written. Cleared on a
    // track change, set once a decode has actually been written.
    BOOL                  _artworkOnDisk;
    // The track the plist on disk names, so the sweep after the next commit
    // can keep that track's images through one more publish.
    NSString             *_committedKey;

    // The last complete envelope offered, and the track it came from, so a
    // settings change can re-bake without the card being asked again.
    CodableAudioWaveform *_waveform;
    __weak AudioTrack    *_waveformTrack;
    // Everything the bake reads. A settings change that does not move one of
    // these is not a re-bake — which is what makes this safe to hang off
    // VibeDisplaySettingsDidChangeNotification, whose posters include a
    // continuous slider and a colour well.
    NSString             *_bakedSignature;
    // The bake not yet started, so the next request can cancel it. TRAP: the
    // gain slider posts a distinct value per half-dB of a drag, and each is a
    // new signature — without this a one-second drag queued dozens of bakes,
    // all but the last thrown away after they ran.
    dispatch_block_t      _pendingBake;
    // Queue-only: whether a reload is already enqueued behind the writes.
    BOOL                  _reloadQueued;
    // The track-change hold (kWidgetTrackChangeHold). Main's side says whether
    // one is open, and the generation drops a deadline a newer hold replaced;
    // the queue's side defers the reloads asked for meanwhile, so the one it
    // sends lands behind every write.
    BOOL                  _holdingReload;
    NSUInteger            _reloadHoldGeneration;
    BOOL                  _reloadHeld;      // queue-only
    BOOL                  _reloadOwed;      // queue-only

    // The theme every snapshot carries (VibeWidgetState.theme); nil on iOS.
    // The placeholder images follow their own inputs and are written with the
    // first commit after those move, and only then.
    NSDictionary         *_theme;
    NSString             *_placeholderSignature;
    BOOL                  _placeholdersOwed;

    // Whether at least one widget is placed, as last known. Two
    // sources, because each can only be right about one direction: WidgetKit's
    // own answer (queryPlaced) is authoritative but asked only at launch and
    // on foreground, so it is what turns this OFF; the extension's read signal
    // arrives the instant a widget renders, wherever the app is, so it is what
    // turns it ON. While NO, nothing is computed, captured or written: every
    // entry point returns at this flag, and updateWithTrack: only records its
    // inputs (below) for republish to replay.
    BOOL                  _widgetPlaced;
    int                   _readToken;

    // The last update while no widget was placed, as handed in — a quiet tick
    // with nobody looking is these stores and nothing else.
    __weak AudioTrack    *_heldTrack;
    NSTimeInterval        _heldPosition;
    NSTimeInterval        _heldDuration;
    CFAbsoluteTime        _heldAt;
    BOOL                  _heldPlaying;
    BOOL                  _heldStartPending;
    BOOL                  _heldInput;

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
        // The mac shell calls displaySettingsDidChange from its live-effect
        // funnel instead; its settings post no notification.
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(displaySettingsDidChange)
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
        [self queryPlaced];
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
        [self queryPlaced];
    }
}

- (void)queryPlaced {
    __weak WidgetPublisher *weakSelf = self;
    [VibeWidgetReloader queryPlaced:^(BOOL placed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setWidgetPlaced:placed];
        });
    }];
}

- (void)setWidgetPlaced:(BOOL)placed {
    if (_widgetPlaced == placed) {
        return;
    }
    _widgetPlaced = placed;
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
    _artworkOnDisk  = NO;
    if (!_heldInput) {
        return;     // nothing handed over yet; the first update publishes
    }
    _heldInput = NO;
    NSTimeInterval position = _heldPosition;
    if (_heldPlaying && !_heldStartPending) {
        position += CFAbsoluteTimeGetCurrent() - _heldAt;   // clamped on read
    }
    [self updateWithTrack:_heldTrack position:position duration:_heldDuration
                  playing:_heldPlaying startPending:_heldStartPending];
}

#pragma mark - What is playing

- (void)updateWithTrack:(AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending {
    // TRAP: cachedArt is nil until the artwork DECODES, so a track change
    // almost always arrives before there is any art to write — and writing nil
    // deletes the file. Keyed on the track alone, a change therefore cleared
    // the artwork and never wrote it back, because by the time the decode
    // landed the track had stopped being new. _artworkOnDisk is the state that
    // makes the write re-fire: nil art leaves it clear, and the next tick that
    // sees decoded art writes it.
    //
    if (!_widgetPlaced) {
        _heldTrack        = track;
        _heldPosition     = position;
        _heldDuration     = duration;
        _heldPlaying      = playing;
        _heldStartPending = startPending;
        _heldAt           = CFAbsoluteTimeGetCurrent();
        _heldInput        = YES;
        return;
    }
    VibeImage *artwork = track.cachedArt;
    BOOL trackChanged = (track != _publishedTrack);
    BOOL writeArtwork = trackChanged || (artwork && !_artworkOnDisk);

    if (!writeArtwork && ![self needsPublishForTrack:track playing:playing duration:duration
                                            position:position startPending:startPending]) {
        return;
    }

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    // TRAP: no track, no key, whatever trackChanged says. _publishedTrack is
    // weak, so closing the playlist frees the track before this call and nil
    // meets nil as "unchanged" — carrying the old key into a trackless
    // snapshot, whose widget then drew the closed track's cover and strip.
    next.trackKey     = !track ? nil : (trackChanged ? track.url.pathKey : _published.trackKey);
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
        if (!track || _waveformTrack != track) {
            _waveform      = nil;
            _waveformTrack = nil;
        }
        _bakedSignature = nil;
        _artworkOnDisk  = NO;
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
        _artworkOnDisk = (artwork != nil);
    }
    // Taken here, on main, and only the CGImage crosses to the queue: on the
    // mac this is the NSImage the header is drawing, and NSImage is not safe
    // to draw concurrently (the Now Playing artwork trap, System/CLAUDE.md).
    CGImageRef cgArtwork = writeArtwork ? CGImageRetain(VibeCGImageOfImage(artwork)) : NULL;
    // Drawn on main for the same reason.
    CGImageRef placeholders[2] = { NULL, NULL };
    BOOL writePlaceholders = _placeholdersOwed;
    if (writePlaceholders) {
        _placeholdersOwed = NO;
        [self drawPlaceholders:placeholders];
    }
    NSString *outgoingKey = _committedKey;
    _committedKey = state.trackKey;
    BOOL sweep = !VibeNowPlayingStringsEqual(outgoingKey, state.trackKey);
    CGImageRef darkPlaceholder = placeholders[0];
    CGImageRef lightPlaceholder = placeholders[1];
    dispatch_async(_queue, ^{
        if (writeArtwork) {
            [self writeArtwork:cgArtwork toURL:state.artworkURL];
            CGImageRelease(cgArtwork);
        }
        if (writePlaceholders) {
            VibeWidgetWriteImage(darkPlaceholder, [VibeWidgetState placeholderURLForDark:YES]);
            VibeWidgetWriteImage(lightPlaceholder, [VibeWidgetState placeholderURLForDark:NO]);
            CGImageRelease(darkPlaceholder);
            CGImageRelease(lightPlaceholder);
        }
        [state save];
        [self scheduleReload];
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
        if (self->_reloadHeld) {
            self->_reloadOwed = YES;    // sent when the hold ends
            return;
        }
        [VibeWidgetReloader reload];
    });
}

// Main. Restarted by every track change, so a run of skips reloads once, when
// it stops.
- (void)beginReloadHold {
    _holdingReload = YES;
    NSUInteger generation = ++_reloadHoldGeneration;
    dispatch_async(_queue, ^{
        self->_reloadHeld = YES;
    });
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
    // Queued behind every write the hold covered, so the reload follows them.
    dispatch_async(_queue, ^{
        self->_reloadHeld = NO;
        if (self->_reloadOwed) {
            self->_reloadOwed = NO;
            [self scheduleReload];
        }
    });
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
    [self endReloadHoldForGeneration:_reloadHoldGeneration];
    if (_published.hasTrack) {
        VibeWidgetState *empty = [[VibeWidgetState alloc] init];
        empty.theme = _theme;
        _published = empty;
        _publishedTrack = nil;
        [self commitState:empty artwork:nil writeArtwork:NO];
    }
    // Three deep: the hold's end can enqueue a reload, which enqueues its send.
    dispatch_sync(_queue, ^{});
    dispatch_sync(_queue, ^{});
    dispatch_sync(_queue, ^{});
}

#pragma mark - The theme

- (void)themeDidChange {
    // Not captured while nobody looks: republish captures it when one appears.
    if (!_widgetPlaced || ![self captureTheme] || !_published) {
        return;
    }
    // A copy: the snapshot in _published may still be on its way to disk.
    VibeWidgetState *next = [_published copy];
    next.theme = _theme;
    _published = next;
    [self commitState:next artwork:nil writeArtwork:NO];
    [self bakeWaveformIfNeeded];    // a light-side surface needs its own strip
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

// A glyph the theme changed from the factory's, if this macOS draws it — the
// window falls back to the factory glyph for a name it has no symbol for, and
// the widget's own glyph is that fallback.
static NSString *VibeWidgetGlyph(NSString *glyph, NSString *factory) {
    if (!glyph.length || [glyph isEqualToString:factory]
            || ![NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil]) {
        return nil;
    }
    return glyph;
}

// The window's no-artwork image as one appearance draws it, at the cover's
// published size. The theme's image is a dynamic wrapper that picks its side
// by the drawing appearance, so each side is drawn under its own.
static CGImageRef VibeWidgetPlaceholder(AppTheme *theme, NSAppearanceName appearance) CF_RETURNS_RETAINED {
    NSImage *image = theme.resolvedDefaultArtworkImage;
    NSInteger side = (NSInteger)kWidgetArtworkSide;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:side pixelsHigh:side bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *context = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
    if (!image || !context) {
        return NULL;
    }
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = context;
    [[NSAppearance appearanceNamed:appearance] performAsCurrentDrawingAppearance:^{
        [image drawInRect:NSMakeRect(0, 0, side, side) fromRect:NSZeroRect
                operation:NSCompositingOperationCopy fraction:1];
    }];
    [NSGraphicsContext restoreGraphicsState];
    return CGImageRetain(rep.CGImage);
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
    NSString *placeholderSignature = [NSString stringWithFormat:@"%@|%@|%d",
            [appTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark],
            [appTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkLight],
            appTheme.isSingleMode];
    BOOL themeMoved = ![theme isEqualToDictionary:_theme ?: @{}];
    BOOL placeholderMoved = !VibeNowPlayingStringsEqual(placeholderSignature, _placeholderSignature);
    _theme = theme;
    if (placeholderMoved) {
        _placeholderSignature = placeholderSignature;
        _placeholdersOwed = YES;
    }
    return themeMoved || placeholderMoved;
#else
    return NO;
#endif
}

// Main: dark into [0], light into [1], +1 each.
- (void)drawPlaceholders:(CGImageRef _Nullable [_Nonnull 2])placeholders {
#if TARGET_OS_OSX
    AppTheme *appTheme = AppSettings.sharedInstance.currentTheme;
    placeholders[0] = VibeWidgetPlaceholder(appTheme, NSAppearanceNameDarkAqua);
    placeholders[1] = VibeWidgetPlaceholder(appTheme, NSAppearanceNameAqua);
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

// A settings change re-bakes only when it moved something the bake reads.
// TRAP: the posters include the gain slider, which is
// continuous and documents that it is deliberately unthrottled *because every
// consumer compares equal and does nothing*. A bake is two renders, two PNG
// encodes and two file writes, so this consumer has to honour that contract or
// a one-second drag queues a hundred of them.
- (void)displaySettingsDidChange {
    [self bakeWaveformIfNeeded];
}

- (void)bakeWaveformIfNeeded {
    CodableAudioWaveform *waveform = _waveform;
    if (!waveform || !_waveformTrack || _waveformTrack != _publishedTrack) {
        return;
    }
    if (!_widgetPlaced) {
        return;     // before the signature is taken, so the bake is still owed
    }
    AppSettings *settings = AppSettings.sharedInstance;
    // The widget's own background is dark, so the strip resolves dark — there
    // is no appearance to follow in a view this process does not own — except
    // a light strip beside it for a theme that paints the light-side surface.
    // The artwork colour is nil until the art decodes, or for art too gray to
    // read, and the album_art theme then resolves to Mono's until it does.
    // A 32x32 downsample, and this runs on a track or settings change only.
    VibeColor *artworkColor = VibeDominantColorOfImage(_publishedTrack.cachedArt);
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
    if (_theme[kVibeWidgetThemeLight][kVibeWidgetColorBackground]) {
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
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%d|%d|%.4f|%.4f|%.4f|%p",
                           style, VibeHexStringFromColor(theme.playedColor) ?: @"",
                           VibeHexStringFromColor(theme.unplayedColor) ?: @"",
                           VibeHexStringFromColor(lightTheme.playedColor) ?: @"",
                           VibeHexStringFromColor(lightTheme.unplayedColor) ?: @"",
                           theme.flatFill, normalize, gainDB, barDensity, barWidth,
                           (void *)_waveformTrack];
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
    _pendingBake = dispatch_block_create(0, ^{
        // 1 and 0: the whole envelope in each side's colours. The widget reveals
        // the played one up to the playhead, which is what keeps a moving
        // playhead free of a re-render.
        [self writeWaveformImage:waveform progress:1 style:style theme:theme dark:YES
                      barDensity:barDensity barWidth:barWidth
                       normalize:normalize gainDB:gainDB toURL:state.waveformPlayedURL];
        [self writeWaveformImage:waveform progress:0 style:style theme:theme dark:YES
                      barDensity:barDensity barWidth:barWidth
                       normalize:normalize gainDB:gainDB toURL:state.waveformUnplayedURL];
        if (lightTheme) {
            [self writeWaveformImage:waveform progress:1 style:style theme:lightTheme dark:NO
                          barDensity:barDensity barWidth:barWidth
                           normalize:normalize gainDB:gainDB toURL:state.waveformPlayedLightURL];
            [self writeWaveformImage:waveform progress:0 style:style theme:lightTheme dark:NO
                          barDensity:barDensity barWidth:barWidth
                           normalize:normalize gainDB:gainDB toURL:state.waveformUnplayedLightURL];
        }
        // The plist names nothing about the waveform, but the widget only
        // re-renders when WidgetKit is told to, so the reload is the whole
        // point of writing it.
        [self scheduleReload];
    });
    dispatch_async(_queue, _pendingBake);
    [self endReloadHoldIfComplete];
}

- (void)writeWaveformImage:(CodableAudioWaveform *)waveform progress:(CGFloat)progress
                     style:(NSString *)style theme:(WaveformTheme *)theme dark:(BOOL)isDark
                barDensity:(double)barDensity barWidth:(double)barWidth
                 normalize:(BOOL)normalize gainDB:(float)gainDB toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    CGImageRef baked = [WaveformRendererRegistry newImageForCodableWaveform:waveform
            identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
              progress:progress dark:isDark theme:theme
            barDensity:barDensity barWidth:barWidth normalize:normalize gainDB:gainDB];
    NSData *png = VibeEncodedImageData(baked);   // PNG: the strip is transparent
    if (baked) {
        CGImageRelease(baked);
    }
    [png writeToURL:url atomically:YES];
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
