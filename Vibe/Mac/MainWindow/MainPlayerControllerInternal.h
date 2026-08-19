//
//  MainPlayerControllerInternal.h
//  Vibe
//
//  The private surface shared between MainPlayerController.m and its
//  categories: the class extension holding the outlets, the collaborator
//  handles, the ivars a category touches, and the internal methods the
//  categories call. Do not use it outside the MainPlayerController
//  implementation files; everything else goes through MainPlayerController.h.
//
//  The debug command channel is deliberately NOT here: its extra surface stays
//  in Debug/Mac/Introspection/MainPlayerController+Debug.h, so that no production
//  file carries a declaration for a tool that does not ship.
//

#import "MainPlayerController.h"
#import "TrackDisplayController.h" // TrackDisplayState, returned below
#import "MainWindow.h"             // FileDropDelegate, adopted below
#import "PitchControlPanel.h"      // PitchControlPanelDelegate, adopted below
#import "EqualizerLevelSource.h"

@class ArtworkDisplayController;
@class AudioTrack;
@class AudioWaveformView;
@class DownloadProgressMonitor;
@class MainPlayerContentView;
@class NowPlayingController;
@class PlaylistTableView;
@class SymbolButton;
@class UIUpdateTimer;

NS_ASSUME_NONNULL_BEGIN

// These conformances stay on the class because MainPlayerController.m
// implements them. Every other one is declared on the category that implements
// it, so the compiler checks each against the file that holds it.
//
// Only the state a category also touches lives here; the rest stays private to
// MainPlayerController.m.
@interface MainPlayerController () <FileDropDelegate, PitchControlPanelDelegate, EqualizerLevelSource> {
    // The occlusion-gated position-update timer. It drives updatePlaybackUI
    // only while playback wants updates and the window is unoccluded, at the
    // rate syncUITimerRate scales to the playhead's on-screen speed. +Window
    // feeds it the visibility gate.
    UIUpdateTimer*              _uiTimer;
    // Playing-row indicators currently reading band levels. The tap is off at
    // zero; see syncEqualizerActivity.
    NSInteger                   _levelConsumers;
    // Polls (and on macOS subscribes to) a materializing cloud file's
    // download progress while the loading shimmer is up; nil otherwise. The
    // player events start and cancel it.
    DownloadProgressMonitor*    _downloadMonitor;
    // The underlying playback open this monitor observes. A same-row replay
    // preserves it; a later open of the same URL does not. Main-confined.
    uint64_t                     _downloadMonitorOpenRequestIdentifier;
    // Stamped on every play at the pre-submit edge (willSubmitPlayForTrack:),
    // captured by didStartPlaying:'s prefetch acknowledgement, and compared at
    // delivery: an acknowledgement outrun by a newer submission must not
    // release the hold that submission re-asserted. Track identity cannot
    // carry this — replaying the same row reuses the same AudioTrack, so a
    // track-only guard has an ABA hole. Main-confined.
    NSUInteger                  _foregroundHoldGeneration;
    // A duration snapshot from didStartPlaying:. The live player duration
    // reads 0 while a track is Loading, and updatePlaybackUI runs in that gap.
    // It is cleared when playback goes idle, on an error or at the end of the
    // playlist.
    NSTimeInterval              _currentTrackDuration;
    // The last track whose playlist row was fully rebuilt, so that a refresh
    // for the same track touches only the play-state cell. Written by every
    // path that has already rendered the row itself.
    __weak AudioTrack*          _lastReloadedTrack;
    PitchControlPanel*          _pitchPanel;
    ArtworkDisplayController*   _artworkController;
}

// The system Now Playing bridge. The publish and command-routing code lives in
// MainPlayerController+NowPlaying.
// The public collaborators' single assignment point is init's construction
// path; they are readonly in MainPlayerController.h.
@property (readwrite, strong) OutputDevicesMenuController *devicesMenuController;
@property (readwrite, strong) AudioPlayer *audioPlayer;
@property (readwrite, strong) PlaylistController *playlistController;
@property (readwrite, strong) AudioTrackMetadataCache *metadataCache;
@property (readwrite, strong) AudioWaveformCache *waveformCache;
@property (readwrite, strong) AudioFileConverter *fileConverter;

@property (strong) NowPlayingController *nowPlayingController;

// The header and waveform rendering surface: the labels, times, codec and BPM
// corner, and waveform states. This controller resolves the TrackDisplayState
// and hands it what to draw.
@property (strong) TrackDisplayController *trackDisplay;

@property (weak) SymbolButton *nextButton;
@property (weak) SymbolButton *playButton;

@property (weak) PlaylistTableView *playlistTableView;
@property (weak) MainPlayerContentView *playerContentView;
// Kept alongside trackDisplay's rendering role. The controller wires the
// view's delegate, style and appearance, the Menus category included, while
// the per-track rendering states go through trackDisplay.
@property (weak) AudioWaveformView *waveformView;

// Conversion undo/redo moves files asynchronously after NSUndoManager has
// already moved its stack. Menus, actions and debug commands share this gate
// so the inverse cannot start against a half-mutated conversion record.
@property (nonatomic, getter=isConversionUndoRedoInFlight) BOOL conversionUndoRedoInFlight;

// The undo/redo settled hook MainPlayerController+Convert fires. The debug
// channel is its only setter, through +Debug.h; in a shipping build it costs
// one always-nil block pointer, which is what keeps an `#if DEBUG` out of a
// shipping header.
@property (copy, nullable) void (^conversionUndoRedoSettledHandler)(void);

// The convert swap's resume hint: the swapped-in track and the file-time
// playhead its replay resumes at, so the Now Playing publish in the swap's
// Loading gap carries the resume position instead of rewinding to 0. +Convert
// writes it at the swap, +NowPlaying reads it gated on the track identity, and
// didStartPlaying: clears it. Weak, like the other track marks, so a replaced
// playlist dissolves the hint.
@property (weak, nullable) AudioTrack *convertSwapResumeTrack;
@property NSTimeInterval convertSwapResumePosition;

#pragma mark - The refresh funnel

// Implemented in MainPlayerController.m, which carries their contracts.

// The whole-header refresh every state change funnels through.
- (void)updateUI;
// The position tick, and the refresh after a seek or a rate change.
- (void)updatePlaybackUI;
// Only the rate-dependent labels; far cheaper than updateUI, for fader ticks.
- (void)updateRateDependentUI;
// Every effective-tempo and key change funnels through here.
- (void)effectiveTempoDidChange;
// The display state the header should render, resolved in one place, and the
// track it should describe — nil while the empty or error state is up.
- (TrackDisplayState)displayState;
- (nullable AudioTrack *)displayedTrack;

#pragma mark - The update timer

- (void)pauseUIUpdateTimer;
- (void)resumeUIUpdateTimer;

// Reconciles the playing row's renderer and the band-level producer with real
// output and material window/row visibility.
- (void)syncEqualizerActivity;

#pragma mark - Deferred metadata load and the error mask

- (void)scheduleDeferredMetadataLoad;
- (void)cancelDeferredMetadataLoad;
- (void)startPendingMetadataLoad;
// The only writers of the error-mask ivar pair, which stays private to
// MainPlayerController.m.
- (void)setErrorMaskForTrack:(nullable AudioTrack *)track status:(nullable NSString *)status;
- (void)clearErrorMask;

// The right time label's click action, wired to a gesture recognizer by
// +Window's content build.
- (IBAction)toggleTimeDisplayMode:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
