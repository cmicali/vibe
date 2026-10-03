//
//  PlaybackControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared by PlaybackController.m and its categories; no
//  other file imports it. The debug surface is Debug/iOS/PlaybackController+Debug.h.
//  This header is the cost of the split: a category that pushes more state in
//  here than it takes out of PlaybackController.m is not worth making.
//

#import "PlaybackController.h"
#import "AudioSessionController.h"
#import "AudioTrackMetadataCache.h"
#import "FolderSession.h"
#import "Playlist.h"

@class AudioPlayer;
@class NowPlayingController;
@class UIUpdateTimer;
@class WidgetPublisher;

NS_ASSUME_NONNULL_BEGIN

// AudioPlayerDelegate and NowPlayingControllerDelegate are declared on the
// categories that implement them, so the compiler checks each against its file.
@interface PlaybackController () <PlaylistObserver, FolderSessionDelegate,
        AudioSessionControllerDelegate, AudioTrackMetadataCacheDelegate> {
    AudioPlayer             *_player;
    Playlist                *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    // Main thread: moved by every replace a user asks for and every open, so
    // a replace behind asynchronous work answers to the newest request.
    uint64_t                 _replaceRequestSerial;
    UIUpdateTimer           *_updateTimer;
    NSInteger                _levelConsumers;
    // Foreground-active, from the scene delegate; NO until it says otherwise.
    BOOL                     _sceneActive;

    float                   _pendingSeekProgress;
    BOOL                    _seekInFlight;
    // Until didStartPlaying: lands, the player's getters still serve the
    // OUTGOING track, so the screens render the incoming track at rest.
    BOOL                    _trackStartPending;
    // Header, waveform and metadata loaded; no file open, nothing playing.
    BOOL                    _parked;
    NSString                *_errorText;

    // The slow open the card shows loading, from didBeginLoading: to its
    // settlement; its progress is CloudTransferRegistry's (+PlayerEvents).
    // The path is the URL standardized once, the key its transfer moves by.
    NSURL                   *_loadingURL;
    NSString                *_loadingPath;
    uint64_t                 _loadingOpenRequestIdentifier;
    float                    _loadingProgress;

    // Owns all widget state, so this header carries none of it.
    WidgetPublisher         *_widgetPublisher;

    // An array: two widget taps can land in the seconds a restore takes.
    NSMutableArray<void (^)(void)> *_launchOpenWaiters;
    BOOL                     _launchOpenSettled;

    // The generation keeps playlist A's fallback timer from starting playlist
    // B's sweep while B's first track is still opening.
    BOOL                    _metadataLoadPending;
    NSUInteger              _metadataLoadGeneration;
}

#pragma mark - The broadcast

- (void)notifyDidMoveToCurrentTrackAnimated:(BOOL)animated;
- (void)notifyDidRenderCurrentTrack;
- (void)notifyDidChangePlayState;
- (void)notifyDidChangeOutputRoute;
// Publishes Now Playing first, so the lock screen never lags the screens.
- (void)notifyDidTick;
- (void)notifyDidBeginLoading;
// Idempotent: every later pick reaches the same delegate methods.
- (void)settleLaunchOpen;
- (void)notifyDidUpdateLoadingProgress:(float)fraction;
- (void)notifyDidFinishLoading;
- (void)notifyDidFailCurrentTrack;

#pragma mark - On track end

// Nil at the end of the playlist and under On track end = Pause. Every
// prefetchTrack: call site asks this; a bypass splices past a track end the
// setting says to park on (root AGENTS.md).
- (nullable AudioTrack *)successorPrefetchTrack;

#pragma mark - Transport follow-ups

// Re-arms the successor unless the player is Stopped; successorPrefetchTrack
// decides what.
- (void)prefetchSuccessor;

// Parks on track and opens it paused at position: parked, the player holds no
// file, and the screens rest on the track until didStartPlaying: lands. The
// caller notifies.
- (void)openParkedTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position;

// Ends the loading open's progress: its URL, identifier and fraction together.
- (void)endLoadingProgress;

#pragma mark - The deferred metadata sweep

// Starts the deferred sweep if one is still pending.
- (void)startPendingMetadataLoad;

@end

NS_ASSUME_NONNULL_END
