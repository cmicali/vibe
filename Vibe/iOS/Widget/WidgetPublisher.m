//
//  WidgetPublisher.m
//  Vibe (iOS)
//
//  See WidgetPublisher.h.
//

#import "WidgetPublisher.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import "PlayerDisplaySettings.h"
#import "UIImage+SquareFill.h"
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

// nil equals nil: a track legitimately has no artist, and -isEqual: on nil
// would read two absences as a change and republish on every tick.
static BOOL VibeWidgetEqualStrings(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

@implementation WidgetPublisher {
    // What the widget was last told. nil until the first publish.
    VibeWidgetState      *_published;
    // The track that snapshot describes, held only to compare identity on the
    // 3 Hz tick. A pointer compare, deliberately: AudioTrack.cacheKey stats the
    // file and hashes its path, and its failure path does not memoize — on a
    // dropped mount that would be a blocking syscall three times a second.
    __weak AudioTrack    *_publishedTrack;
    // Whether artwork.jpg on disk belongs to _publishedTrack. Cleared on a
    // track change, set once a decode has actually been written.
    BOOL                  _artworkOnDisk;

    // The last complete envelope offered, and the track it came from, so a
    // settings change can re-bake without the card being asked again.
    CodableAudioWaveform *_waveform;
    __weak AudioTrack    *_waveformTrack;
    // Everything the bake reads. A settings change that does not move one of
    // these is not a re-bake — which is what makes this safe to hang off
    // VibeDisplaySettingsDidChangeNotification, whose posters include a
    // continuous slider and a colour well.
    NSString             *_bakedSignature;

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
    }
    return self;
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
    UIImage *artwork = track.cachedArt;
    BOOL trackChanged = (track != _publishedTrack);
    BOOL writeArtwork = trackChanged || (artwork && !_artworkOnDisk);

    NSTimeInterval effectivePosition = startPending ? 0 : position;
    if (!writeArtwork
            && ![self needsPublishForTrackChanged:trackChanged
                                          hasTrack:(track != nil)
                                           playing:playing
                                          duration:duration
                                          position:effectivePosition
                                      startPending:startPending
                                             track:track]) {
        return;
    }

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    next.playing      = playing;
    next.duration     = duration;
    next.position     = effectivePosition;
    next.positionDate = [NSDate date];

    _published      = next;
    _publishedTrack = track;
    if (writeArtwork) {
        _artworkOnDisk = (artwork != nil);
    }
    if (trackChanged) {
        // The retained envelope belongs to the outgoing track; drop it so a
        // settings change cannot re-bake it under the new title.
        _waveform       = nil;
        _waveformTrack  = nil;
        _bakedSignature = nil;
    }

    dispatch_async(_queue, ^{
        // TRAP: the images must land before the plist. The widget reads the
        // plist first and loads the files it names, so a plist that arrives
        // first pairs the new title with the previous track's artwork for as
        // long as the encode takes.
        if (writeArtwork) {
            [self writeArtwork:artwork];
        }
        if (trackChanged) {
            // The strip on disk is the OUTGOING track's.
            [NSFileManager.defaultManager removeItemAtURL:VibeWidgetState.waveformPlayedURL
                                                    error:NULL];
            [NSFileManager.defaultManager removeItemAtURL:VibeWidgetState.waveformUnplayedURL
                                                    error:NULL];
        }
        [next save];
        [VibeWidgetReloader reload];
    });
}

// Republished on a structural change or a seek, never on the tick that merely
// advanced the playhead — that one the widget computes for itself. The order
// is deliberate: every test above the drift check is a scalar or a pointer, so
// the common tick costs no allocation and no string work.
- (BOOL)needsPublishForTrackChanged:(BOOL)trackChanged
                           hasTrack:(BOOL)hasTrack
                            playing:(BOOL)playing
                           duration:(NSTimeInterval)duration
                           position:(NSTimeInterval)position
                       startPending:(BOOL)startPending
                              track:(AudioTrack *)track {
    VibeWidgetState *last = _published;
    if (!last || trackChanged) {
        return YES;
    }
    if (last.hasTrack != hasTrack || last.playing != playing) {
        return YES;
    }
    if (fabs(last.duration - duration) > 0.5) {
        return YES;
    }
    // A track whose tags land after it started playing keeps its identity but
    // changes its lines; that is a publish, and it is the only reason the
    // strings are read at all.
    if (!VibeWidgetEqualStrings(last.title, track.displayTitle)
            || !VibeWidgetEqualStrings(last.artist, track.displayArtist)) {
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
    if (!waveform || !track || track != _publishedTrack) {
        return;
    }
    _waveform      = waveform;
    _waveformTrack = track;
    [self bakeWaveformIfNeeded];
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
    if (!waveform || !_waveformTrack) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    // The widget's own style when the user picked one, else the app's. nil
    // means "match app", and resolveStyleIdentifier: turns an unregistered or
    // absent identifier into the default either way.
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:settings.widgetWaveformStyle ?: settings.waveformStyle];
    BOOL normalize = settings.waveformNormalize;
    float gainDB = (float)settings.waveformGainDB;
    VibeColor *played = [settings waveformCustomPlayedColorForDark:YES];
    VibeColor *unplayed = [settings waveformCustomUnplayedColorForDark:YES];

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%@|%d|%.4f|%p",
                           style, settings.waveformTheme, played, unplayed,
                           normalize, gainDB, (void *)_waveformTrack];
    if (VibeWidgetEqualStrings(signature, _bakedSignature)) {
        return;
    }
    _bakedSignature = signature;

    // The widget's own background is always dark, so it resolves dark — there
    // is no appearance to follow in a view this process does not own. A nil
    // artwork colour is a real answer: the album_art theme resolves to Mono's.
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                      isDark:YES
                                                artworkColor:nil
                                                customPlayed:played
                                              customUnplayed:unplayed];
    dispatch_async(_queue, ^{
        [self writeWaveform:waveform style:style theme:theme
                  normalize:normalize gainDB:gainDB];
        // The plist names nothing about the waveform, but the widget only
        // re-renders when WidgetKit is told to, so the reload is the whole
        // point of writing it.
        [VibeWidgetReloader reload];
    });
}

- (void)writeWaveform:(CodableAudioWaveform *)waveform style:(NSString *)style
                theme:(WaveformTheme *)theme normalize:(BOOL)normalize gainDB:(float)gainDB {
    // 1 and 0: the whole envelope in each side's colours. The widget reveals
    // the played one up to the playhead, which is what keeps a moving playhead
    // free of a re-render.
    [self writeWaveformImage:waveform progress:1 style:style theme:theme
                   normalize:normalize gainDB:gainDB toURL:VibeWidgetState.waveformPlayedURL];
    [self writeWaveformImage:waveform progress:0 style:style theme:theme
                   normalize:normalize gainDB:gainDB toURL:VibeWidgetState.waveformUnplayedURL];
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

// Removing the file for a track with no art is as load-bearing as writing one:
// the widget draws whatever is on disk, so a leftover cover would outlive the
// track it belonged to.
- (void)writeArtwork:(UIImage *)artwork {
    NSURL *url = VibeWidgetState.artworkURL;
    if (!url) {
        return;
    }
    NSData *jpeg = artwork
            ? UIImageJPEGRepresentation([artwork vibeSquareFilledToSide:kWidgetArtworkSide], 0.8)
            : nil;
    if (jpeg) {
        [jpeg writeToURL:url atomically:YES];
    }
    else {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
}

@end
