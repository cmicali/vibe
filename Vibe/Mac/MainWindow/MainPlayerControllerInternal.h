//
//  MainPlayerControllerInternal.h
//  Vibe
//
//  The private surface MainPlayerController.m and its categories share. Only
//  the debug channel imports it from outside; the channel's own additions stay
//  in Debug/Mac/Introspection/MainPlayerController+Debug.h, so no production
//  file declares a tool that does not ship.
//

#import "MainPlayerController.h"
#import "TrackDisplayController.h" // TrackDisplayState, returned below
#import "MainWindow.h"             // FileDropDelegate, adopted below
#import "PitchControlPanel.h"      // PitchControlPanelDelegate, adopted below
#import "EqualizerLevelSource.h"

@class ArtworkDisplayController;
@class AudioTrack;
@class AudioWaveformView;
@class MainPlayerContentView;
@class NowPlayingController;
@class PlaylistTableView;
@class SymbolButton;
@class UIUpdateTimer;

NS_ASSUME_NONNULL_BEGIN

// The conformances MainPlayerController.m implements; every other one is
// declared on the category that implements it.
@interface MainPlayerController () <FileDropDelegate, PitchControlPanelDelegate, EqualizerLevelSource> {
    UIUpdateTimer*              _uiTimer;
    // The slow open the shimmer is up for, from didBeginLoading: to its
    // settlement; its progress is CloudTransferRegistry's (+PlayerEvents).
    // A same-row replay keeps the identifier; a later open of the URL does not.
    // The path is the URL standardized once, the key its transfer moves by.
    NSURL*                      _loadingURL;
    NSString*                   _loadingPath;
    uint64_t                     _loadingOpenRequestIdentifier;
    float                        _loadingProgress;
    // From didStartPlaying:: the live duration reads 0 while Loading. Zeroed
    // on Close, a play error and the end-of-track park.
    NSTimeInterval              _currentTrackDuration;
    // The last track whose row was rebuilt; a same-track refresh skips the
    // rebuild. Written by every path that already rendered the row.
    __weak AudioTrack*          _lastReloadedTrack;
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
    // The waveform provider's bands answer as of the last style change, so
    // only the change into a style reading them asks for the track again.
    BOOL                        _waveformBandsWanted;
}

@property (readwrite, strong) OutputDevicesMenuController *devicesMenuController;
@property (readwrite, strong) AudioPlayer *audioPlayer;
@property (readwrite, strong) PlaylistController *playlistController;
@property (readwrite, strong) AudioTrackMetadataCache *metadataCache;
@property (readwrite, strong) AudioWaveformCache *waveformCache;
@property (readwrite, strong) AudioFileConverter *fileConverter;

@property (strong) NowPlayingController *nowPlayingController;
@property (strong) TrackDisplayController *trackDisplay;

@property (weak) SymbolButton *nextButton;
@property (weak) SymbolButton *playButton;

@property (weak) PlaylistTableView *playlistTableView;
@property (weak) MainPlayerContentView *playerContentView;
// Kept so applyWindowChrome can re-shape and re-color them live.
@property (weak) NSView *windowBackdropView;
@property (weak) NSView *windowBackgroundOverlayView;
// Per-track rendering goes through trackDisplay; this is for wiring.
@property (weak) AudioWaveformView *waveformView;

// The debug channel is its only setter. An always-nil block pointer keeps
// `#if DEBUG` out of this header.
@property (copy, nullable) void (^conversionUndoRedoSettledHandler)(
        BOOL committed, NSString *_Nullable reason);

// The convert swap's resume hint, so Now Playing in the swap's Loading gap
// shows the resume position rather than 0. Written at the swap, read gated on
// track identity, cleared by the per-track refresh. Weak, so a replaced
// playlist dissolves it.
@property (weak, nullable) AudioTrack *convertSwapResumeTrack;
@property NSTimeInterval convertSwapResumePosition;

#pragma mark - The refresh funnel

// The whole-header refresh every state change funnels through.
- (void)updateUI;
// The position tick, and the refresh after a seek or a rate change.
- (void)updatePlaybackUI;
// Only the rate-dependent labels, cheap enough for fader ticks.
- (void)updateRateDependentUI;
// Every effective-tempo and key change funnels through here.
- (void)effectiveTempoDidChange;
// The header's display state and the track it describes (nil while empty or
// in error). Rendering both together takes one currentTrack read through the
// ForTrack:/ForState: pair; the no-argument forms are for lone reads.
- (TrackDisplayState)displayState;
- (TrackDisplayState)displayStateForTrack:(nullable AudioTrack *)track;
- (nullable AudioTrack *)displayedTrack;
- (nullable AudioTrack *)displayedTrackForState:(TrackDisplayState)state
                                          track:(nullable AudioTrack *)track;

#pragma mark - Settings live effects

- (void)applyPitchRange;
- (void)applyEndOfTrackAction;
- (void)applyReopenLastPlaylist;
- (void)syncUITimerRate;
// One update aimed just past the time label's next change, after a start, resume or seek.
- (void)scheduleUpdateAtNextDisplayedSecond;
- (void)refreshFolderArt;
- (void)refreshWindowTint;

#pragma mark - The update timer

- (void)pauseUIUpdateTimer;
- (void)resumeUIUpdateTimer;

// Reconciles the playing row's renderer and the band-level producer with real
// output and material window/row visibility.
- (void)syncEqualizerActivity;

#pragma mark - The loading open

// Ends the loading open's progress: its URL, identifier and fraction together.
- (void)endLoadingProgress;

#pragma mark - The successor prefetch

// The track every prefetch site parks: the next track, or nil past the end or
// under On track end = Pause. The audio half of that setting: with nothing
// parked nothing splices, and didFinishPlaying: re-reads it to park.
- (nullable AudioTrack *)successorPrefetchTrack;

#pragma mark - Saving the playlist

// Extended M3U, noted in Open Recent; the playlist is snapshotted at the
// write. Shared with the save_playlist debug verb.
- (BOOL)writePlaylistToURL:(NSURL *)url error:(NSError **)error;

#pragma mark - Deferred metadata load and the error mask

- (void)startPendingMetadataLoad;
// The only writers of the error mask.
- (void)setErrorMaskForTrack:(nullable AudioTrack *)track status:(nullable NSString *)status;
- (void)clearErrorMask;

// The right time label's click.
- (IBAction)toggleTimeDisplayMode:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
