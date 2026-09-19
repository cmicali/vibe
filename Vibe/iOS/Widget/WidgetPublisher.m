//
//  WidgetPublisher.m
//  Vibe (iOS)
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
#import "PlayerDisplaySettings.h"
#import "UIImage+DominantColor.h"
#import "Vibe-Swift.h"                 // VibeWidgetReloader; WidgetCenter has no ObjC API
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

// How far the real playhead may drift from what the widget would extrapolate
// before the snapshot is republished. It is a seek detector: playing straight
// through never trips it, because the widget's own arithmetic is right. Looser
// than the lock screen's, because a widget entry is minutes of wall clock.
static const NSTimeInterval kWidgetPositionTolerance = 2.0;

// The published artwork's longest side, in pixels. The widget draws it at 67pt
// and again blurred as the background, so 256 is generous at 3x.
static const CGFloat kWidgetArtworkSide = 256;

// The strip the widget draws, in points; it stretches to whatever the widget
// gives it, so only the ASPECT and the bar count really matter here. Baked to
// the medium widget's shape, which is the taller of the two — the small
// family's thinner strip scales down cleanly, where the reverse would stretch
// the envelope's amplitude up. 3x because that is every current iPhone.
static const CGSize  kWidgetWaveformSize  = (CGSize){320, 64};
static const CGFloat kWidgetWaveformScale = 3;

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

    // Whether at least one widget is on a Home screen, as last known. Two
    // sources, because each can only be right about one direction: WidgetKit's
    // own answer (refreshPlaced) is authoritative but asked only at launch and
    // on foreground, so it is what turns this OFF; the extension's read signal
    // arrives the instant a widget renders, wherever the app is, so it is what
    // turns it ON. Nothing is written while NO — see updateWithTrack:.
    BOOL                  _widgetPlaced;
    int                   _readToken;

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
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(displaySettingsDidChange)
                                                   name:VibeDisplaySettingsDidChangeNotification
                                                 object:nil];
        // The extension's "a widget just read the snapshot", on main so it is
        // ordered with everything else that touches _published.
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

// The gate has just opened. Everything a widget needs is already in hand —
// the snapshot, the track's decoded art, the offered envelope — so it is
// written as if the track had just changed, which from the widget's side is
// exactly what happened. A widget added while a track plays in the background
// renders once from whatever was on disk, its read lands here, and the next
// render is current.
- (void)republish {
    VibeWidgetState *state = _published;
    if (!state) {
        return;     // nothing handed over yet; the first update publishes
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
    // TRAP: cachedArt is nil until the artwork DECODES, so a track change
    // almost always arrives before there is any art to write — and writing nil
    // deletes the file. Keyed on the track alone, a change therefore cleared
    // the artwork and never wrote it back, because by the time the decode
    // landed the track had stopped being new. _artworkOnDisk is the state that
    // makes the write re-fire: nil art leaves it clear, and the next tick that
    // sees decoded art writes it.
    //
    // The gate is folded in here rather than tested below so that a quiet tick
    // with no widget placed stays allocation-free: republish writes the art
    // fresh from the track when one appears, so nothing is owed meanwhile.
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
    if (!_widgetPlaced) {
        return;     // bookkeeping only: nobody is looking
    }
    [self commitState:next artwork:artwork writeArtwork:writeArtwork];

    // An offer that arrived before its track was adopted bakes now; so does
    // art that decoded after the offer, for the one theme that reads it — the
    // signature decides, so for every other theme this is a compare and out.
    if (_waveform && (trackChanged || writeArtwork)) {
        [self bakeWaveformIfNeeded];
    }
}

// The one place the plist is written. TRAP: the images must land before the
// plist. The widget reads the plist first and loads the files it names, so a
// plist that arrives first pairs the new title with no artwork for as long as
// the encode takes. The images are named by track, so the plist can never
// name another track's; the sweep runs LAST and spares the outgoing track's
// set, so an extension that read the previous plist a moment ago still finds
// the images it names.
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
        [VibeWidgetReloader reload];
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
// TRAP: the posters of this notification include the gain slider, which is
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
    // The widget's own style when the user picked one, else the app's. nil
    // means "match app", and resolveStyleIdentifier: turns an unregistered or
    // absent identifier into the default either way.
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:settings.widgetWaveformStyle ?: settings.waveformStyle];
    // The app's scrubber draws the normalized mapping with no gain — Normalize
    // and Gain are macOS settings (AppSettings+Mac.h) — and the strip matches it.
    const BOOL normalize = YES;
    const float gainDB = 0;
    VibeColor *played = [settings waveformCustomPlayedColorForDark:YES];
    VibeColor *unplayed = [settings waveformCustomUnplayedColorForDark:YES];

    // The widget's own background is always dark, so it resolves dark — there
    // is no appearance to follow in a view this process does not own. The
    // artwork colour is the cover's, memoized on the image by the page that
    // installed it, so this read is free; nil until the art decodes, or for
    // art too gray to read, and the album_art theme then resolves to Mono's
    // until it does.
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                      isDark:YES
                                                artworkColor:_publishedTrack.cachedArt.vibeDominantColor
                                                customPlayed:played
                                              customUnplayed:unplayed];
    // The signature is the RESOLVED palette, not the inputs: a cover arriving
    // under a theme that ignores it changes nothing here and bakes nothing,
    // while under album_art it moves both colours and bakes once more.
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%d|%.4f|%p",
                           style, VibeHexStringFromColor(theme.playedColor) ?: @"",
                           VibeHexStringFromColor(theme.unplayedColor) ?: @"",
                           normalize, gainDB, (void *)_waveformTrack];
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
        [self writeWaveformImage:waveform progress:1 style:style theme:theme
                       normalize:normalize gainDB:gainDB toURL:state.waveformPlayedURL];
        [self writeWaveformImage:waveform progress:0 style:style theme:theme
                       normalize:normalize gainDB:gainDB toURL:state.waveformUnplayedURL];
        // The plist names nothing about the waveform, but the widget only
        // re-renders when WidgetKit is told to, so the reload is the whole
        // point of writing it.
        [self scheduleReload];
    });
    dispatch_async(_queue, _pendingBake);
}

- (void)writeWaveformImage:(CodableAudioWaveform *)waveform progress:(CGFloat)progress
                     style:(NSString *)style theme:(WaveformTheme *)theme
                 normalize:(BOOL)normalize gainDB:(float)gainDB toURL:(NSURL *)url {
    if (!url) {
        return;
    }
    CGImageRef baked = [WaveformRendererRegistry newImageForCodableWaveform:waveform
            identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
              progress:progress dark:YES theme:theme
            barDensity:1 barWidth:1 normalize:normalize gainDB:gainDB];
    if (!baked) {
        return;
    }
    UIImage *image = [UIImage imageWithCGImage:baked];
    CGImageRelease(baked);
    NSData *png = UIImagePNGRepresentation(image);   // PNG, not JPEG: the strip is transparent
    if (png) {
        [png writeToURL:url atomically:YES];
    }
}

#pragma mark - Artwork

// The cover bounded to kWidgetArtworkSide on its longer edge, never enlarged.
// Only a BOUND: the widget draws it scaledToFill and clipped, blurred or not,
// so the square is cut where it is drawn and cutting it here too would only
// throw pixels away twice.
static UIImage *VibeWidgetBoundedArtwork(UIImage *artwork) {
    CGSize source = artwork.size;
    CGFloat longest = MAX(source.width, source.height);
    if (longest <= 0) {
        return artwork;
    }
    CGFloat scale = MIN(1, kWidgetArtworkSide / longest);
    CGSize bounded = CGSizeMake(round(source.width * scale), round(source.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;                 // the side is already in pixels
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounded
                                                                              format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [artwork drawInRect:(CGRect){CGPointZero, bounded}];
    }];
}

// Removing the file for a track with no art is as load-bearing as writing one:
// the widget draws whatever the plist names, and the file would otherwise
// survive from an earlier decode of the same track.
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
