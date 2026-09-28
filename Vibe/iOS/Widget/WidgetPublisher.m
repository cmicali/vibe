//
//  WidgetPublisher.m
//  Vibe (iOS)
//

#import "WidgetPublisher.h"

#import <notify.h>

#import "AppSettings.h"
#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "NowPlayingRules.h"
#import "PlatformColor.h"
#import "PlayerDisplaySettings.h"
#import "UIImage+DominantColor.h"
#import "Vibe-Swift.h"                 // WidgetCenter has no ObjC API
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

static const uint64_t kWidgetReloadMinInterval = NSEC_PER_SEC;

// A seek detector against the widget's own extrapolation; looser than the lock
// screen's, since a widget entry spans minutes.
static const NSTimeInterval kWidgetPositionTolerance = 2.0;

// Pixels; the widget draws it at 67pt.
static const CGFloat kWidgetArtworkSide = 256;

// Stretched to fit, so only the ASPECT matters: the medium widget's, the
// taller, since scaling down is clean and scaling up stretches the amplitude.
static const CGSize  kWidgetWaveformSize  = (CGSize){320, 64};
static const CGFloat kWidgetWaveformScale = 3;

@implementation WidgetPublisher {
    // Kept current whether or not anything is written: a widget usually
    // appears in the background, where no tick is guaranteed.
    VibeWidgetState      *_published;
    // A pointer compare, deliberately: AudioTrack.cacheKey stats the file and
    // does not memoize a failure, a blocking syscall at 3 Hz on a dropped mount.
    __weak AudioTrack    *_publishedTrack;
    BOOL                  _artworkOnDisk;
    // So the sweep after the next commit keeps this track's images once more.
    NSString             *_committedKey;

    CodableAudioWaveform *_waveform;
    __weak AudioTrack    *_waveformTrack;
    // Everything the bake reads; see displaySettingsDidChange.
    NSString             *_bakedSignature;
    // Not yet started, so the next request can cancel it.
    dispatch_block_t      _pendingBake;
    // Queue-only; scheduleReload's throttle (uptime nanos).
    BOOL                  _reloadQueued;
    uint64_t              _lastReloadAt;

    // Two sources, each right about one direction: WidgetKit's answer, asked
    // only at launch and foreground, turns it OFF; the extension's read
    // signal, the instant a widget renders, turns it ON.
    BOOL                  _widgetPlaced;
    int                   _readToken;

    dispatch_queue_t      _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Serial: an image must never land after the plist naming it, and two
        // bakes must never interleave writing the same PNGs.
        _queue = dispatch_queue_create("com.commonwealthrecordings.Vibe.widget-publish",
                                       DISPATCH_QUEUE_SERIAL);
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(displaySettingsDidChange)
                                                   name:VibeDisplaySettingsDidChangeNotification
                                                 object:nil];
        // On main, ordered with everything that touches _published.
        __weak WidgetPublisher *weakSelf = self;
        _readToken = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kVibeWidgetReadNotification, &_readToken,
                                 dispatch_get_main_queue(), ^(int token) {
            [weakSelf setWidgetPlaced:YES];
        });
        [self refreshPlaced];
    }
    return self;
}

- (void)dealloc {
    if (_readToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(_readToken);
    }
}

#pragma mark - Whether anyone is looking

- (void)refreshPlaced {
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

// The gate just opened: write everything in hand as if the track had just
// changed, which from the widget's side it has.
- (void)republish {
    VibeWidgetState *state = _published;
    if (!state) {
        return;
    }
    _bakedSignature = nil;
    [self commitState:state artwork:_publishedTrack.cachedArt writeArtwork:YES];
    [self bakeWaveformIfNeeded];
}

#pragma mark - What is playing

- (void)updateWithTrack:(AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending {
    // TRAP: cachedArt is nil until the art DECODES, so a track change usually
    // writes nil, which deletes the file. Keyed on the track alone, the art
    // never comes back; _artworkOnDisk re-fires the write on the first tick
    // with decoded art. The gate is folded in so a quiet unplaced tick stays
    // allocation-free; republish writes the art when a widget appears.
    UIImage *artwork = track.cachedArt;
    BOOL trackChanged = (track != _publishedTrack);
    BOOL writeArtwork = _widgetPlaced && (trackChanged || (artwork && !_artworkOnDisk));

    if (!writeArtwork && ![self needsPublishForTrack:track playing:playing duration:duration
                                            position:position startPending:startPending]) {
        return;
    }

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    next.trackKey     = trackChanged ? track.url.pathKey : _published.trackKey;
    next.playing      = playing;
    next.duration     = duration;
    next.position     = position;
    next.positionDate = [NSDate date];

    _published      = next;
    _publishedTrack = track;
    if (trackChanged) {
        // Kept only if offered FOR this track: a played track's offer arrives
        // before this call, so the pairing is checked, not the order assumed.
        if (!track || _waveformTrack != track) {
            _waveform      = nil;
            _waveformTrack = nil;
        }
        _bakedSignature = nil;
        _artworkOnDisk  = NO;
    }
    if (!_widgetPlaced) {
        return;     // bookkeeping only
    }
    [self commitState:next artwork:artwork writeArtwork:writeArtwork];

    // An early offer bakes now, as does art that decoded after it (album_art);
    // the signature decides.
    if (_waveform && (trackChanged || writeArtwork)) {
        [self bakeWaveformIfNeeded];
    }
}

// The one place the plist is written. TRAP: the images must land before the
// plist, which the widget reads first; otherwise the new title shows with no
// art for as long as the encode takes. The sweep runs LAST and spares the
// outgoing track's images, which a just-read previous plist still names.
- (void)commitState:(VibeWidgetState *)state artwork:(UIImage *)artwork
       writeArtwork:(BOOL)writeArtwork {
    if (writeArtwork) {
        _artworkOnDisk = (artwork != nil);
    }
    NSString *outgoingKey = _committedKey;
    _committedKey = state.trackKey;
    BOOL sweep = !VibeNowPlayingStringsEqual(outgoingKey, state.trackKey);
    dispatch_async(_queue, ^{
        if (writeArtwork) {
            [self writeArtwork:artwork toURL:state.artworkURL];
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

// On _queue. One reload per burst of writes, each reload being an extension
// launch, and at most one a second: a burst costs one trailing reload. The
// first of a quiet period goes at once — the app may be suspended before a
// timer fires — and the trailing one always goes.
- (void)scheduleReload {
    if (_reloadQueued) {
        return;
    }
    _reloadQueued = YES;
    dispatch_block_t reload = ^{
        self->_reloadQueued = NO;
        self->_lastReloadAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [VibeWidgetReloader reload];
    };
    uint64_t since = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _lastReloadAt;
    if (_lastReloadAt == 0 || since >= kWidgetReloadMinInterval) {
        dispatch_async(_queue, reload);
    }
    else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWidgetReloadMinInterval - since)), _queue, reload);
    }
}

// On a structural change or a seek, never a plain tick, which the widget
// extrapolates itself. Cheapest tests first.
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
    // Tags landing after the start change the lines, not the identity.
    if (!VibeNowPlayingStringsEqual(last.title, track.displayTitle)
            || !VibeNowPlayingStringsEqual(last.artist, track.displayArtist)) {
        return YES;
    }
    if (startPending) {
        return NO;      // pinned at 0 while the open runs
    }
    // The lock screen's seek test, with this caller's tolerance.
    return VibeNowPlayingPositionIsDirty(last.position,
                                         CFDateGetAbsoluteTime((__bridge CFDateRef)last.positionDate),
                                         1.0, last.playing, position,
                                         CFAbsoluteTimeGetCurrent(), kWidgetPositionTolerance);
}

#pragma mark - The waveform strip

- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track {
    if (!waveform || !track) {
        return;
    }
    // Kept either side of the adoption; only the bake waits for the published
    // track, so a page swiped past cannot overwrite the strip.
    _waveform      = waveform;
    _waveformTrack = track;
    if (track == _publishedTrack) {
        [self bakeWaveformIfNeeded];
    }
}

// Re-bakes only when a setting moved something the bake reads.
// TRAP: the Custom theme's colour wells post continuously while dragged, each a
// new signature. A bake is two renders, two PNG encodes and two writes, so the
// signature compare and the _pendingBake cancel keep a drag from queuing
// dozens.
- (void)displaySettingsDidChange {
    [self bakeWaveformIfNeeded];
}

- (void)bakeWaveformIfNeeded {
    CodableAudioWaveform *waveform = _waveform;
    if (!waveform || !_waveformTrack || _waveformTrack != _publishedTrack) {
        return;
    }
    if (!_widgetPlaced) {
        return;     // before the signature, so the bake is still owed
    }
    AppSettings *settings = AppSettings.sharedInstance;
    // nil widget style means "match app".
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:settings.widgetWaveformStyle ?: settings.waveformStyle];
    VibeColor *played = [settings waveformCustomPlayedColorForDark:YES];
    VibeColor *unplayed = [settings waveformCustomUnplayedColorForDark:YES];

    // Always dark: the widget's background is. The artwork colour is memoized
    // on the image; nil (not decoded, or too gray) resolves album_art to Mono.
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                      isDark:YES
                                                artworkColor:_publishedTrack.cachedArt.vibeDominantColor
                                                customPlayed:played
                                              customUnplayed:unplayed];
    // The RESOLVED palette, not the inputs, so a cover arriving under a theme
    // that ignores it bakes nothing.
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%p",
                           style, VibeHexStringFromColor(theme.playedColor) ?: @"",
                           VibeHexStringFromColor(theme.unplayedColor) ?: @"",
                           (void *)_waveformTrack];
    if (VibeNowPlayingStringsEqual(signature, _bakedSignature)) {
        return;
    }
    _bakedSignature = signature;
    // A queued bake is superseded; a started one completes first.
    if (_pendingBake) {
        dispatch_block_cancel(_pendingBake);
    }
    VibeWidgetState *state = _published;
    _pendingBake = dispatch_block_create(0, ^{
        // The whole envelope in each side's colours; the widget reveals the
        // played one up to the playhead without a re-render.
        [self writeWaveformImage:waveform progress:1 style:style theme:theme
                           toURL:state.waveformPlayedURL];
        [self writeWaveformImage:waveform progress:0 style:style theme:theme
                           toURL:state.waveformUnplayedURL];
        // The widget re-renders only on a reload.
        [self scheduleReload];
    });
    dispatch_async(_queue, _pendingBake);
}

- (void)writeWaveformImage:(CodableAudioWaveform *)waveform progress:(CGFloat)progress
                     style:(NSString *)style theme:(WaveformTheme *)theme
                     toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    // Matches the scrubber: Normalize and Gain are macOS-only.
    CGImageRef baked = [WaveformRendererRegistry newImageForCodableWaveform:waveform
            identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
              progress:progress dark:YES theme:theme
            barDensity:1 barWidth:1 normalize:YES gainDB:0];
    if (!baked) {
        return;
    }
    UIImage *image = [UIImage imageWithCGImage:baked];
    CGImageRelease(baked);
    NSData *png = UIImagePNGRepresentation(image);   // transparent
    if (png) {
        [png writeToURL:url atomically:YES];
    }
}

#pragma mark - Artwork

// Only a BOUND, never a crop: the widget crops where it draws.
static UIImage *VibeWidgetBoundedArtwork(UIImage *artwork) {
    CGSize source = artwork.size;
    CGFloat longest = MAX(source.width, source.height);
    if (longest <= 0) {
        return artwork;
    }
    CGFloat scale = MIN(1, kWidgetArtworkSide / longest);
    CGSize bounded = CGSizeMake(round(source.width * scale), round(source.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;                 // the side is in pixels
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounded
                                                                              format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [artwork drawInRect:(CGRect){CGPointZero, bounded}];
    }];
}

// Removing a file is as load-bearing as writing one, or an earlier decode's
// art survives.
- (void)writeArtwork:(UIImage *)artwork toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    NSData *jpeg = artwork ? UIImageJPEGRepresentation(VibeWidgetBoundedArtwork(artwork), 0.8) : nil;
    if (jpeg) {
        [jpeg writeToURL:url atomically:YES];
    }
    else {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
}

@end
