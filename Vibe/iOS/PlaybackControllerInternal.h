//
//  PlaybackControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared between PlaybackController.m and its categories:
//  the class extension holding the collaborators and the display-state flags,
//  and the notify helpers a category fires. Do not use it outside the
//  PlaybackController implementation files; everything else goes through
//  PlaybackController.h.
//
//  The debug command channel is deliberately NOT here: its extra surface stays
//  in Debug/iOS/PlaybackController+Debug.h, so that no production file carries
//  a declaration for a tool that does not ship.
//
//  This header is the cost of the split, so it is the thing to watch: a
//  category that would push more state into it than it takes out of
//  PlaybackController.m is not worth making.
//

#import "PlaybackController.h"
#import "AudioSessionController.h"     // AudioSessionControllerDelegate, adopted below
#import "AudioTrackMetadataCache.h"    // AudioTrackMetadataCacheDelegate, adopted below
#import "FolderSession.h"              // FolderSessionDelegate, adopted below
#import "Playlist.h"                   // PlaylistObserver, adopted below

@class AudioPlayer;
@class DownloadProgressMonitor;
@class NowPlayingController;
@class UIUpdateTimer;

NS_ASSUME_NONNULL_BEGIN

// These four conformances stay on the class because PlaybackController.m
// implements them. AudioPlayerDelegate and NowPlayingControllerDelegate are
// declared on the categories that implement them, so the compiler checks each
// against the file that holds it.
@interface PlaybackController () <PlaylistObserver, FolderSessionDelegate,
        AudioSessionControllerDelegate, AudioTrackMetadataCacheDelegate> {
    AudioPlayer             *_player;
    Playlist                *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    UIUpdateTimer           *_updateTimer;
    // Indicators currently consuming band levels. The tap is off at zero; see
    // syncLevelsEnabled.
    NSInteger                _levelConsumers;
    // Foreground-active, supplied by the scene delegate. Defaults false so a
    // controller that has not joined an active scene cannot start UI work.
    BOOL                     _sceneActive;

    float                   _pendingSeekProgress;
    BOOL                    _seekInFlight;
    // Until didStartPlaying: lands, the player's getters still serve the
    // OUTGOING track, so the screens render the incoming track at rest.
    BOOL                    _trackStartPending;
    // A restored track is parked: header, waveform and metadata are loaded,
    // but nothing plays until the user asks.
    BOOL                    _parked;
    NSString                *_errorText;

    // Polls a materializing cloud file's size while an open is in flight; nil
    // otherwise.
    DownloadProgressMonitor *_downloadMonitor;
    uint64_t                 _downloadMonitorOpenRequestIdentifier;

    // The deferred playlist-wide metadata sweep; see scheduleDeferredMetadataLoad.
    // The generation pairs each open's fallback timer with its own playlist, so
    // a timer armed by playlist A and firing after a replacement cannot start
    // playlist B's sweep while B's first track is still opening.
    BOOL                    _metadataLoadPending;
    NSUInteger              _metadataLoadGeneration;
}

#pragma mark - The broadcast

// One per event in PlaybackObserver, so a category fires an event by name
// rather than by re-deriving which observers implement it.
- (void)notifyDidMoveToCurrentTrackAnimated:(BOOL)animated;
- (void)notifyDidRenderCurrentTrack;
- (void)notifyDidChangePlayState;
// Publishes the Now Playing card, then ticks the observers. The publish rides
// along because every caller wants both and the card must never lag the
// screens.
- (void)notifyDidTick;
- (void)notifyDidBeginLoading;
- (void)notifyDidUpdateLoadingProgress:(float)fraction;
- (void)notifyDidFinishLoading;
- (void)notifyDidFailCurrentTrack;

#pragma mark - The deferred metadata sweep

// Starts the playlist-wide sweep if one is still pending. The player-event
// category calls it the moment the current track's own open settles, which is
// the whole point of deferring it.
- (void)startPendingMetadataLoad;

@end

NS_ASSUME_NONNULL_END
