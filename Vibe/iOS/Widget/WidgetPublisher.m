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
#import "PlayerScreenRules.h"
#import "UIImage+DominantColor.h"
#import "Vibe-Swift.h"                 // WidgetCenter has no ObjC API
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

// Allow the title and the later waveform bake to request separate reloads.
static const uint64_t kWidgetReloadMinInterval = NSEC_PER_SEC / 4;

// Request fresh dense entries during playback. WidgetKit controls delivery.
static const NSTimeInterval kWidgetPlayingReloadInterval = 60;

// Pixels. The large widget draws it at up to 190pt, at 3x.
static const CGFloat kWidgetArtworkSide = 576;

// Stretched to fit, so only the ASPECT matters. It is the medium widget's.
// The small waveform tile draws the same images narrower and slightly taller.
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
    // Main; runs only while placed and playing (updatePlayingReloads).
    NSTimer              *_playingReloadTimer;

    // Two sources, each right about one direction: WidgetKit's answer, asked
    // only at launch and foreground, turns it OFF; the extension's read
    // signal, the instant a widget renders, turns it ON.
    BOOL                  _widgetPlaced;
    int                   _readToken;

    dispatch_queue_t      _queue;
}

+ (NSString *)trackKeyForTrack:(AudioTrack *)track {
    return [track keyByAppendingWindowTo:track.url.pathKey];
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
    [_playingReloadTimer invalidate];
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
    else {
        [self updatePlayingReloads];
    }
}

// Runs iff a placed widget shows a playing track. The timer only reloads:
// the widget extrapolates the playhead from the plist it has, and a stall
// that moves the real position past the seek tolerance republishes anyway.
- (void)updatePlayingReloads {
    BOOL wanted = _widgetPlaced && _published.hasTrack && _published.playing;
    if (wanted == (_playingReloadTimer != nil)) {
        return;
    }
    if (!wanted) {
        [_playingReloadTimer invalidate];
        _playingReloadTimer = nil;
        return;
    }
    __weak WidgetPublisher *weakSelf = self;
    _playingReloadTimer = [NSTimer scheduledTimerWithTimeInterval:kWidgetPlayingReloadInterval
                                                          repeats:YES block:^(NSTimer *timer) {
        WidgetPublisher *publisher = weakSelf;
        if (publisher) {
            dispatch_async(publisher->_queue, ^{
                [publisher scheduleReload];
            });
        }
    }];
    _playingReloadTimer.tolerance = kWidgetPlayingReloadInterval / 10;
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
    BOOL writeArtwork = VibeWidgetWritesArtwork(_widgetPlaced, trackChanged, artwork != nil, _artworkOnDisk);

    if (!writeArtwork && !VibeWidgetNeedsPublish(_published, !trackChanged, track != nil,
                                                 track.displayTitle, track.displayArtist, playing,
                                                 duration, position, startPending,
                                                 CFAbsoluteTimeGetCurrent())) {
        return;
    }

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    next.trackKey     = trackChanged ? [WidgetPublisher trackKeyForTrack:track] : _published.trackKey;
    next.playing      = playing;
    next.duration     = duration;
    next.position     = position;
    next.positionDate = [NSDate date];
    next.playheadLine = [self widgetDrawsPlayheadLine];

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

// TRAP: write artwork before the plist. The waveform bake may follow later.
// Sweep last and spare the outgoing track images that a reader may still need.
- (void)commitState:(VibeWidgetState *)state artwork:(UIImage *)artwork
       writeArtwork:(BOOL)writeArtwork {
    if (writeArtwork) {
        _artworkOnDisk = (artwork != nil);
    }
    NSString *outgoingKey = _committedKey;
    _committedKey = state.trackKey;
    BOOL sweep = !VibeNowPlayingStringsEqual(outgoingKey, state.trackKey);
    [self updatePlayingReloads];
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

// Queue-only. Throttle requests to four per second with one trailing request.
// Queue the first request at once before the app can be suspended.
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

// nil widget style means "match app", and then every widget setting reads
// as the card's (AppSettings.h).
- (NSString *)widgetWaveformStyle {
    AppSettings *settings = AppSettings.sharedInstance;
    return [WaveformRendererRegistry resolveStyleIdentifier:settings.widgetWaveformStyle ?: settings.waveformStyle];
}

- (BOOL)widgetDrawsPlayheadLine {
    return [WaveformRendererRegistry drawsPlayheadLineForIdentifier:[self widgetWaveformStyle]
                                                             chosen:[AppSettings.sharedInstance waveformPlayheadLineForWidget:YES]];
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
    NSString *style = [self widgetWaveformStyle];

    // Always dark: the widget's background is. The artwork colour is memoized
    // on the image; nil (not decoded, or too gray) resolves album_art to Mono.
    WaveformTheme *theme = [WaveformTheme themeForSettings:settings widget:YES isDark:YES
                                              artworkColor:_publishedTrack.cachedArt.vibeDominantColor];
    // The RESOLVED palette, not the inputs, so a cover arriving under a theme
    // that ignores it bakes nothing. The waveform, not its track: the
    // signature clears on a track change, and a new waveform for the same
    // track, the bands' decode, must bake.
    BOOL centered = [settings waveformCenteredForWidget:YES];
    BOOL line = [self widgetDrawsPlayheadLine];
    NSString *signature = [NSString stringWithFormat:@"%@|%d|%d|%@|%p",
                           style, centered, line, theme.paletteSignature, (void *)waveform];
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
        // played one up to the playhead without a re-render. Under a playhead
        // line both are the whole strip as played, and the widget draws the
        // line (VibeWidgetState.playheadLine).
        [self writeWaveformImage:waveform progress:1 style:style centered:centered theme:theme
                           toURL:state.waveformPlayedURL];
        [self writeWaveformImage:waveform progress:line ? 1 : 0 style:style centered:centered theme:theme
                           toURL:state.waveformUnplayedURL];
        // The widget re-renders only on a reload.
        [self scheduleReload];
    });
    dispatch_async(_queue, _pendingBake);
    // A line setting flipped since the plist was written. Committed after the
    // bake, so the plist lands behind the images that match it.
    if (state.playheadLine != line) {
        state.playheadLine = line;
        [self commitState:state artwork:nil writeArtwork:NO];
    }
}

- (void)writeWaveformImage:(CodableAudioWaveform *)waveform progress:(CGFloat)progress
                     style:(NSString *)style centered:(BOOL)centered theme:(WaveformTheme *)theme
                     toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    // Matches the scrubber: Normalize and Gain are macOS-only.
    CGImageRef baked = [WaveformRendererRegistry newImageForCodableWaveform:waveform
            identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
              progress:progress dark:YES theme:theme
            barDensity:1 barWidth:1 centered:centered normalize:YES gainDB:0];
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
