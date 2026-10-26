//
//  PlaybackControllerInternal.h
//  Vibe (iOS)
//
//  The private surface shared by PlaybackController.m and its categories; no
//  other file imports it. The debug surface is Debug/iOS/Seams/PlaybackController+Debug.h.
//  This header is the cost of the split: a category that pushes more state in
//  here than it takes out of PlaybackController.m is not worth making.
//

#import "PlaybackController.h"
#import "AudioSessionController.h"
#import "AudioTrackMetadataCache.h"
#import "FolderSession.h"
#import "VibePlaylist.h"

@class AudioPlayer;
@class NowPlayingController;
@class UIUpdateTimer;
@class WidgetPublisher;

NS_ASSUME_NONNULL_BEGIN

// AudioPlayerDelegate and NowPlayingControllerDelegate are declared on the
// categories that implement them, so the compiler checks each against its file.
@interface PlaybackController () <VibePlaylistObserver,
        AudioSessionControllerDelegate, AudioTrackMetadataCacheDelegate> {
    AudioPlayer             *_player;
    VibePlaylist<AudioTrack *> *_playlist;
    AudioTrackMetadataCache *_metadataCache;
    NowPlayingController    *_nowPlaying;
    AudioSessionController  *_audioSession;
    FolderSession           *_folderSession;
    // Main thread: moved by every replace a user asks for and every open, so
    // a replace behind asynchronous work answers to the newest request.
    uint64_t                 _replaceRequestSerial;
    // The row openingPath names, the serial that asked for it, and the serial
    // of the last replace handed to the session, the one whose settle ends it.
    NSString                *_openingPath;
    uint64_t                 _openingSerial;
    uint64_t                 _submittedOpenSerial;
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

// A handler may add or drop an observer mid-delivery.
- (NSArray<id<PlaybackObserver>> *)observerSnapshot;
- (void)notifyDidMoveToCurrentTrackAnimated:(BOOL)animated;
- (void)notifyDidRenderCurrentTrack;
- (void)notifyDidChangePlayState;
- (void)notifyDidChangeOutputRoute;
// Publishes Now Playing first, so the lock screen never lags the screens.
- (void)notifyDidTick;
- (void)notifyDidBeginLoading;
- (void)notifyDidUpdateLoadingProgress:(float)fraction;
- (void)notifyDidFinishLoading;
- (void)notifyDidFailCurrentTrack;
- (void)notifyHasNothingToRestore;

#pragma mark - Transport follow-ups

// Parks on the playlist's current track: the screens describe it, and
// nothing opens.
- (void)parkCurrentTrack;

// Hands the playlist's neighborhood to the metadata cache's ranking.
- (void)updateMetadataNeighborhood;

// Re-arms the playlist's trackEndSuccessor unless the player is Stopped.
- (void)prefetchSuccessor;

// Parks on track and opens it paused at position: parked, the player holds no
// file, and the screens rest on the track until didStartPlaying: lands. The
// caller notifies.
- (void)openParkedTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position;

// Ends the loading open's progress: its URL, identifier and fraction together.
- (void)endLoadingProgress;

#pragma mark - The deferred metadata sweep

// Marks the sweep pending, and arms its fallback timer.
- (void)scheduleDeferredMetadataLoad;
// Starts the deferred sweep if one is still pending.
- (void)startPendingMetadataLoad;

@end

// The private half of PlaybackController+Opening.m.
@interface PlaybackController (OpeningInternal) <FolderSessionDelegate>

// Idempotent: every later pick reaches the same delegate methods.
- (void)settleLaunchOpen;

// Clears openingPath. The row's spinner goes.
- (void)endOpening;

@end

NS_ASSUME_NONNULL_END
