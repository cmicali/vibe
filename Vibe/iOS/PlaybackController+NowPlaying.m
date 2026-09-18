//
//  PlaybackController+NowPlaying.m
//  Vibe (iOS)
//
//  See PlaybackController+NowPlaying.h.
//

#import "PlaybackController+NowPlaying.h"
#import "PlaybackControllerInternal.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Recovery.h"
#import "AudioPlayer+Seek.h"
#import "AudioTrack.h"
#import "AppSettings.h"
#import "NowPlayingRules.h"
#import "PlayerDisplaySettings.h"   // the widget's own waveform style
#import "Vibe-Swift.h"                 // VibeWidgetReloader; WidgetCenter has no ObjC API
#import "VibeWidgetState.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

// How far the real playhead may drift from what the widget would extrapolate
// before the snapshot is republished. It is a seek detector: playing straight
// through never trips it, because the widget's own arithmetic is right.
static const NSTimeInterval kWidgetPositionTolerance = 2.0;

// The published artwork's longest side. The widget draws it at 68pt and again
// blurred as the background, so 256 is generous at 3x and keeps the encode off
// the critical path of a track change.
static const CGFloat kWidgetArtworkSide = 256;

// nil equals nil: every one of these fields is legitimately absent (no artist,
// file info switched off), and -isEqual: on nil would read two absences as a
// change and republish on every tick.
static BOOL VibeWidgetEqualStrings(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

// Square, kWidgetArtworkSide a side. The widget's own frame is square, so the
// aspect fill happens here once rather than per render in the extension.
static UIImage *VibeWidgetScaledArtwork(UIImage *artwork) {
    CGSize side = CGSizeMake(kWidgetArtworkSide, kWidgetArtworkSide);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;                 // the side is already in pixels
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:side
                                                                              format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGSize source = artwork.size;
        if (source.width <= 0 || source.height <= 0) {
            return;
        }
        CGFloat scale = MAX(side.width / source.width, side.height / source.height);
        CGSize filled = CGSizeMake(source.width * scale, source.height * scale);
        [artwork drawInRect:CGRectMake((side.width - filled.width) / 2,
                                       (side.height - filled.height) / 2,
                                       filled.width, filled.height)];
    }];
}

@implementation PlaybackController (NowPlaying)

// The card's art is not dispatched here: the current page's art is the same
// decode, and the pager's art window (PlayerViewController+Pager) owns it and
// republishes the card when it lands. Until then cachedArt reads nil and the
// card falls back to the thumbnail, which is more than large enough for it.
- (void)publishNowPlaying {
    NowPlayingPlaybackState state = VibeNowPlayingStateForPlayer(_player.isPlaying,
                                                                 _player.isPaused);
    AudioTrack *track = self.displayedTrack;
    // The player's duration is 0 while pending or parked-unopened; the
    // track's metadata duration keeps the card's timeline real there.
    NSTimeInterval playerDuration = _player.duration;
    [_nowPlaying updateWithTrack:track
                        position:(_trackStartPending ? 0 : _player.position)
                        duration:(playerDuration > 0 ? playerDuration : track.duration)
                           state:state
                            rate:1.0
                         hasNext:_playlist.hasNextTrack
                     hasPrevious:_playlist.hasPreviousTrack];
    [self publishWidgetSnapshot];
}

#pragma mark - The home-screen widget

// The widget rides this publish rather than observing separately: "what is
// playing, for something outside the app" is one concern and this is where it
// already lives. What it needs beyond the lock screen is artwork on disk
// rather than in an MPMediaItemArtwork, and the waveform strip below.
- (void)publishWidgetSnapshot {
    AudioTrack *track = self.displayedTrack;
    NSTimeInterval playerDuration = _player.duration;

    VibeWidgetState *next = [[VibeWidgetState alloc] init];
    next.hasTrack     = (track != nil);
    next.trackKey     = track.cacheKey;
    next.title        = track.displayTitle;
    next.artist       = track.displayArtist;
    next.playing      = _player.isPlaying;
    next.duration     = playerDuration > 0 ? playerDuration : track.duration;
    next.position     = _trackStartPending ? 0 : _player.position;
    next.positionDate = [NSDate date];

    // TRAP: cachedArt is nil until the artwork DECODES, so a track change
    // almost always publishes before there is any art to write — and writing
    // nil deletes the file. Keying the write on the track alone therefore
    // cleared the artwork on every track change and never wrote it back, since
    // by the time the decode landed the track had stopped being "new". The
    // write is keyed on what is on disk instead, so the first publish that
    // sees decoded art writes it; the 3 Hz tick makes that arrive promptly,
    // and the pager's own publish when art lands makes it certain.
    UIImage *artwork = track.cachedArt;
    BOOL trackChanged = !VibeWidgetEqualStrings(next.trackKey,
                                                _publishedWidgetState.trackKey);
    BOOL artworkIsOwed = artwork
            && !VibeWidgetEqualStrings(_publishedWidgetArtworkKey, next.trackKey);
    BOOL writeArtwork = trackChanged || artworkIsOwed;

    if (!writeArtwork && ![self widgetSnapshotNeedsPublish:next]) {
        return;
    }
    next.generation = _publishedWidgetState.generation + 1;

    // TRAP: the images must land before the plist. The widget reads the plist
    // first and loads the files named by it, so a plist that arrives first
    // pairs the new title with the previous track's artwork for as long as the
    // encode takes.
    _publishedWidgetState = next;
    if (writeArtwork) {
        // nil art records nil, which is the "still owed" state a later publish
        // acts on — not an assertion that this track has no artwork.
        _publishedWidgetArtworkKey = artwork ? next.trackKey : nil;
    }

    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.commonwealthrecordings.Vibe.widget-publish",
                                      DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(queue, ^{
        if (writeArtwork) {
            [self writeWidgetArtwork:artwork];
        }
        if (trackChanged) {
            // The strip on disk is the OUTGOING track's. Clearing it here
            // rather than leaving it until the new one bakes is what stops the
            // widget drawing one track's envelope under another's title.
            [NSFileManager.defaultManager removeItemAtURL:VibeWidgetState.waveformPlayedURL
                                                    error:NULL];
            [NSFileManager.defaultManager removeItemAtURL:VibeWidgetState.waveformUnplayedURL
                                                    error:NULL];
        }
        [next save];
        [VibeWidgetReloader reload];
    });
}

// The snapshot is republished on a structural change or a seek, never on the
// tick that merely advanced the playhead — that one the widget computes.
- (BOOL)widgetSnapshotNeedsPublish:(VibeWidgetState *)next {
    VibeWidgetState *last = _publishedWidgetState;
    if (!last) {
        return YES;
    }
    if (last.hasTrack != next.hasTrack || last.playing != next.playing) {
        return YES;
    }
    if (!VibeWidgetEqualStrings(last.trackKey, next.trackKey)
            || !VibeWidgetEqualStrings(last.title, next.title)
            || !VibeWidgetEqualStrings(last.artist, next.artist)) {
        return YES;
    }
    if (fabs(last.duration - next.duration) > 0.5) {
        return YES;
    }
    NSTimeInterval extrapolated = [last positionAtDate:next.positionDate];
    return fabs(extrapolated - next.position) > kWidgetPositionTolerance;
}

// The strip the widget draws, in points; it stretches to whatever the widget
// gives it, so only the ASPECT and the bar count really matter here. Baked to
// the medium widget's shape, which is the taller of the two — the small
// family's thinner strip scales down cleanly, where the reverse would stretch
// the envelope's amplitude up. 3x because that is every current iPhone, and
// the file is written once per track.
static const CGSize  kWidgetWaveformSize  = (CGSize){320, 64};
static const CGFloat kWidgetWaveformScale = 3;

- (void)publishWidgetWaveform:(CodableAudioWaveform *)waveform
                     forTrack:(AudioTrack *)track
                     complete:(BOOL)complete {
    // The delivered URL must match the current one — a decode outlives the
    // track change that superseded it (root CLAUDE.md's async-delivery rule).
    // A partial envelope is dropped rather than published and replaced: the
    // cache delivers about ten times a second, and each publish is two bakes,
    // two PNG encodes and a WidgetKit reload.
    if (!complete || !waveform || !track || track != self.displayedTrack) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    // The widget's own style when the user picked one, else the app's. nil
    // from the setting means "match app", and resolveStyleIdentifier: turns an
    // unregistered or absent identifier into the default either way.
    NSString *style = [WaveformRendererRegistry
            resolveStyleIdentifier:VibeWidgetWaveformStyle() ?: settings.waveformStyle];
    // The widget's own background is always dark, so it resolves dark — there
    // is no appearance to follow in a view this process does not own. The
    // artwork color is nil for the same reason the scrubber accepts nil: the
    // album_art theme then resolves to Mono's answer, a real result.
    WaveformTheme *theme = [WaveformTheme themeForIdentifier:settings.waveformTheme
                                                      isDark:YES
                                                artworkColor:nil
                                                customPlayed:[settings waveformCustomPlayedColorForDark:YES]
                                              customUnplayed:[settings waveformCustomUnplayedColorForDark:YES]];
    NSString *trackKey = track.cacheKey;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self writeWidgetWaveform:waveform style:style theme:theme settings:settings];
        // The plist names nothing about the waveform, but the widget only
        // reloads when it is republished — so bump the snapshot to make the
        // freshly written strip appear rather than waiting for the next track.
        [self noteWidgetWaveformWrittenForTrackKey:trackKey];
    });
}

- (void)writeWidgetWaveform:(CodableAudioWaveform *)waveform style:(NSString *)style
                      theme:(WaveformTheme *)theme settings:(AppSettings *)settings {
    NSURL *playedURL = VibeWidgetState.waveformPlayedURL;
    NSURL *unplayedURL = VibeWidgetState.waveformUnplayedURL;
    if (!playedURL || !unplayedURL) {
        return;
    }
    // 1 and 0: the whole envelope in each side's colours. The widget reveals
    // the played one to the playhead, which is what keeps a moving playhead
    // free of a re-render.
    [self writeWidgetWaveformImage:waveform progress:1 style:style theme:theme
                          settings:settings toURL:playedURL];
    [self writeWidgetWaveformImage:waveform progress:0 style:style theme:theme
                          settings:settings toURL:unplayedURL];
}

- (void)writeWidgetWaveformImage:(CodableAudioWaveform *)waveform progress:(CGFloat)progress
                           style:(NSString *)style theme:(WaveformTheme *)theme
                        settings:(AppSettings *)settings toURL:(NSURL *)url {
    CGImageRef baked = [WaveformRendererRegistry newImageForCodableWaveform:waveform
            identifier:style pointSize:kWidgetWaveformSize scale:kWidgetWaveformScale
              progress:progress dark:YES theme:theme
            barDensity:1 barWidth:1
             normalize:settings.waveformNormalize gainDB:(float)settings.waveformGainDB];
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

// Republishes so WidgetKit picks the strip up, but only while the snapshot
// still describes the track it was baked for — a track change during the bake
// has already written its own snapshot and cleared these files.
- (void)noteWidgetWaveformWrittenForTrackKey:(NSString *)trackKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!VibeWidgetEqualStrings(trackKey, self->_publishedWidgetState.trackKey)) {
            return;
        }
        self->_publishedWidgetState.generation += 1;
        VibeWidgetState *state = self->_publishedWidgetState;
        [state save];
        [VibeWidgetReloader reload];
    });
}

// Removing the file for a track with no art is as load-bearing as writing one:
// the widget draws whatever is on disk, so a leftover cover would outlive the
// track it belonged to.
- (void)writeWidgetArtwork:(nullable UIImage *)artwork {
    NSURL *url = VibeWidgetState.artworkURL;
    if (!url) {
        return;
    }
    NSData *jpeg = artwork ? UIImageJPEGRepresentation(VibeWidgetScaledArtwork(artwork), 0.8) : nil;
    if (jpeg) {
        [jpeg writeToURL:url atomically:YES];
    }
    else {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
}

#pragma mark - NowPlayingControllerDelegate

// Play and Pause from the lock screen, Control Center or a car head unit name
// destination states, unlike the on-screen toggle, so they go to the player's
// idempotent operations, which decide beside the mutable state on the player
// queue rather than from a main-thread snapshot. Two Pause commands in quick
// succession therefore both mean paused, where a toggle would have cancelled
// itself. Same rule as the mac's MainPlayerController+NowPlaying.
//
// The one main-thread read left is isStopped, and only to pick which funnel
// owns the request: a stopped player has no loaded row to resume, so the
// playlist has to choose and load one. Safe stale in both directions — resume
// no-ops on a player that has since stopped, and playCurrentTrack replays the
// current row on one that has since started.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller {
    if (_player.isStopped) {
        [self playCurrentTrack]; // activates the session itself
        return;
    }
    // Loading is not the exception it looks like: it is a parked landing (a
    // pause verdict mid-load, or the media-reset re-park), and resume flips
    // that landing to playing without a fresh play: that would restart the
    // open and lose the re-park's captured position. Same verdict playPause
    // reaches for the same state.
    [_audioSession activate];
    [_player resume];
    [_player recoverFromEngineConfigurationChange];
}

- (void)nowPlayingControllerPause:(NowPlayingController *)controller {
    [_player pause];
}

- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller {
    [self playPause];
}

- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller {
    [self next];
}

- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller {
    [self previous];
}

- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position {
    [self seekToPosition:position];
}

@end
