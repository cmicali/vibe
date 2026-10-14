//
//  MainPlayerControllerInternal.h
//  Vibe
//
//  The private surface MainPlayerController.m and its categories share. Only
//  the debug channel imports it from outside; the channel's own additions stay
//  in Debug/Mac/Seams/MainPlayerController+Debug.h, so no production
//  file declares a tool that does not ship.
//

#import "MainPlayerController.h"
#import "TrackDisplayController.h" // TrackDisplayState, returned below
#import "MainWindow.h"             // FileDropDelegate, adopted below
#import "EqualizerLevelSource.h"
#import "AudioWaveformLoader.h"    // VibeWaveformAnalysis, held below

@class ArtworkDisplayController;
@class AudioTrack;
@class WaveformView;
@class MainPlayerContentView;
@class PitchControlPanel;
@class NowPlayingController;
@class PlaylistTableView;
@class SymbolButton;
@class UIUpdateTimer;

NS_ASSUME_NONNULL_BEGIN

// The conformances MainPlayerController.m implements; every other one is
// declared on the category that implements it.
@interface MainPlayerController () <FileDropDelegate, EqualizerLevelSource> {
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
    // The waveform provider's answer as of the last style or detection change,
    // so only a widened ask (the bands, a tempo, a key) requests the track again.
    VibeWaveformAnalysis        _waveformAnalysisWanted;
    // The playlist the empty header names (revealEmptyStateNamingPlaylist:);
    // cleared by every load and by Close.
    NSString*                   _unplayablePlaylistName;
    // The launch grace (revealEmptyStateNamingPlaylist:). Once cleared, never
    // set again.
    BOOL                        _emptyStateSuppressed;
    BOOL                        _folderArtRefreshScheduled;
    // Set once a hold outlasts kVibeBufferingNoticeDelaySeconds. The
    // generation pairs each delay with its own hold. The uptime is when a
    // shown notice last ended.
    BOOL                        _bufferingNoticeShown;
    NSUInteger                  _bufferingNoticeGeneration;
    NSTimeInterval              _bufferingNoticeEndedUptime;
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
@property (weak) WaveformView *waveformView;

// The debug channel is its only setter. An always-nil block pointer keeps
// `#if DEBUG` out of this header.
@property (copy, nullable) void (^undoRedoSettledHandler)(
        BOOL committed, NSString *_Nullable reason);
// Fires undoRedoSettledHandler once an undo's or redo's file moves settle.
- (void)undoRedoDidSettleCommitted:(BOOL)committed reason:(nullable NSString *)reason;

// YES until an undoable action's file moves settle, so the action cannot be
// re-entered nor undone before its files land.
@property (nonatomic, readonly, getter=isFileMoveInFlight) BOOL fileMoveInFlight;

// A same-track replay's resume hint (the convert swap, an MP3 decoder change),
// so Now Playing in its Loading gap shows the resume position rather than 0.
// Written at the replay, read gated on
// track identity, cleared by the per-track refresh. Weak, so a replaced
// playlist dissolves it.
@property (weak, nullable) AudioTrack *replayResumeTrack;
@property NSTimeInterval replayResumePosition;

#pragma mark - The refresh funnel

// The whole-header refresh every state change funnels through.
- (void)updateUI;
// The position tick, and the refresh after a seek or a rate change.
- (void)updatePlaybackUI;
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
// What the header draws: the display state, or Notice over it while one is
// held. Only the header's writes read it. Playback, Now Playing, and the
// delay's tempo read the display state.
- (TrackDisplayState)headerState;
// The held notice's status, nil for none.
@property (nonatomic, readonly, copy, nullable) NSString *noticeStatus;
// Buffering… stands in for the file info line: the play still holds, and
// the hold outlasted kVibeBufferingNoticeDelaySeconds. The player's flag is
// read too, since a newer play drops the old hold's end.
@property (nonatomic, readonly) BOOL bufferingNoticeShown;

#pragma mark - Settings live effects

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

#pragma mark - Loading a playlist

- (void)loadTracks:(NSArray<AudioTrack *> *)tracks selectingIndex:(NSUInteger)index startPaused:(BOOL)startPaused;

#pragma mark - Deferred metadata load and the error mask

- (void)startPendingMetadataLoad;
- (void)cancelDeferredMetadataLoad;
// The only writers of the error mask.
- (void)setErrorMaskForTrack:(nullable AudioTrack *)track status:(nullable NSString *)status;
- (void)clearErrorMask;

// The right time label's click.
- (IBAction)toggleTimeDisplayMode:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
