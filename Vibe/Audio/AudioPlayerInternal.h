//
//  AudioPlayerInternal.h
//  Vibe
//
//  The private surface AudioPlayer.m and its categories share; nothing else
//  imports it. The PLAYER QUEUE runs every transport verb and output mutation;
//  _stateLock guards only the published tuple the main-thread getters read,
//  which publishState:… writes whole.
//

#import "AudioPlayer.h"
#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLevelMeter.h"
#import "AudioOutputUnit.h"
#import "AudioVoiceBus.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFAudio/AVFAudio.h>
#import <os/lock.h>

// Every member calls across category lines; exactly one platform member is
// compiled.
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#else
#import "AudioPlayer+Recovery.h"
#endif
#import "AudioPlayer+Diagnostics.h"
#import "AudioPlayer+Pipeline.h"
#import "AudioPlayer+Prefetch.h"

NS_ASSUME_NONNULL_BEGIN

// What differs per platform about the one hosted output unit (AudioOutputUnit,
// _outputUnit): how it is made, started and fed a rate. Implemented by Devices
// on macOS and Recovery on iOS; player queue only. The platform-blind half —
// the attach, the counters, the failures — is AudioPlayer+Pipeline's.
@interface AudioPlayer (PlatformOutput)

// Brings the output's rate before a segment is built or a voice started at the
// old one: macOS makes a unit it could not make at init; iOS follows the
// route's rate. NO only when that left the player reset or parked and said
// why; a unit still missing is the start's to report.
- (BOOL)followOutputRateOnQueue;
- (void)prepareOutputOnQueue;
- (BOOL)startOutputUnitOnQueueWithError:(NSError * _Nullable * _Nullable)error;
- (void)releaseIdleOutputUnitOnQueue;
- (BOOL)adoptOutputFormatOnQueue:(AVAudioFormat *)format;
// Report-only: the platform's keys for the output stage, then any stages past
// it.
- (NSArray<NSDictionary<NSString *, id> *> *)outputUnitAudioPathOnQueue;

@end

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // The open is in flight; no voice or file yet. isPlaying/isPaused reflect
    // the pending intent; position and duration read 0.
    VibePlayerStateLoading,
};

// The hardware drain: the bus reports its events within the prompt interval
// of their render while anything is due (updateDrainTimerOnQueue); otherwise
// it only tops up rings at least half a second deep, and a tenth of the
// wakeups do. The steady interval is also how late a track-end crossfade's
// drain can be.
static const uint64_t kDrainIntervalNanos = 10 * NSEC_PER_MSEC;
static const uint64_t kDrainSteadyIntervalNanos = 100 * NSEC_PER_MSEC;

// Defined in AudioPlayer.m.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);

@interface AudioPlayer () {
    dispatch_queue_t        _queue;
    os_unfair_lock          _stateLock;
    BOOL                    _terminating; // queue-confined; no new work after quit cleanup

    // ---- The published tuple, under _stateLock, written whole by publishState:….
    VibePlayerState         _state;
    VibeVoiceID             _voice;             // the current voice, 0 while none
    AudioFileHandle             *_file;             // its file; after a promote, the successor
    double                  _fileSampleRate;    // scalars, so a getter never messages an object
    NSRange                 _window;            // the track's frames of the file, all of it but for a cue row
    double                  _busSampleRate;
    NSTimeInterval          _voiceStartSeconds; // where in the window the voice began
    uint64_t                _promotedBaseFrames; // bus frames the voice consumed before its current file began
    BOOL                    _gaplessArmedForUI;
    BOOL                    _outputAudioActive;
    BOOL                    _buffering;         // the current voice held for its stream's bytes (updateBufferingOnQueue)
    // The stall's park: Paused with no voice and no file, the window and rate
    // kept, which resume replays and a seek holds for it. Set only by
    // publishPausedWithoutVoiceOnQueueAtSeconds:, cleared by every other
    // publication.
    BOOL                    _stalled;
    BOOL                    _outputIdle;
    float                   _pitch;             // percent; see the trap below
    // Minted on main by every explicit play; only ever increments.
    uint64_t                _nextSubmittedPlayIdentifier;

    // ---- Queue-confined transport state.
    // The play that owns the current voice. A promote keeps it; a newer play,
    // stop or failure clears it.
    uint64_t                _activeSubmittedPlayIdentifier;
    // The published window came from an estimated length, which the drain
    // grows and, once settled, republishes (republishEstimatedWindowOnQueue).
    BOOL                    _windowEstimated;
    PlaybackRequestCoordinator *_pendingRequest;
    // Voices fading out; each leaves when the drain reports it ended.
    NSMutableArray<NSNumber *> *_retiringVoices;
    // Files a retired bus's decoder may still be inside, counted per retired
    // bus; the current bus withholds reads of them until the count is zero.
    NSCountedSet<AudioFileHandle *> *_retiredDecoderFiles;

    // ---- The park and the successor (AudioPlayer+Prefetch.m). Keyed by the
    // track's sourceKey, so another window of the same file is another park.
    NSString                *_prefetchedKey;
    AudioFileHandle             *_prefetchedFile;
    AudioTrack              *_prefetchedTrack;
    uint64_t                _prefetchGeneration;
    AudioTrack              *_requestedPrefetchTrack;
    NSString                *_requestedPrefetchKey;
    VibeAudioPrefetchRequestState _prefetchRequestState;
    AudioFileOpenToken      *_prefetchOpenToken;
    AudioTrack              *_successorTrack;   // the row queued on the current voice, else nil
    AudioFileHandle             *_successorFile;    // the park's instance the bus was handed

    // ---- The render pipeline (AudioPlayer+Pipeline.m).
    VibeMasterBus           *_masterBus;        // what the audio thread reads; allocated in init, freed at dealloc
    AVAudioFormat           *_masterFormat;     // the pipeline's format: stereo at the output's rate
    AudioVoiceBus           *_voiceBus;         // the source segment; nil until the first settlement
    BOOL                    _fxEnabled;         // the saved preference; bit-perfect outranks it
    uint64_t                _outputIdleStopGeneration;
    dispatch_source_t       _drainTimer;        // hardware only, while the output runs voices
    uint64_t                _drainTimerInterval; // its period: prompt, or steady while nothing is due
    id                      _manualPump;        // VibeManualRenderPump, debug builds only
#if VIBE_VERBOSE_LOGGING
    // Ticks only while the player has work that can stall
    // (refreshQueueStallWatcherOnQueue).
    dispatch_source_t       _queueStallWatcher;
    BOOL                    _queueStallWatcherRunning;
    NSUInteger              _diagnosticPhaseDepth;
    uint64_t                _renderClockFrames, _renderClockAdvancedAt, _renderClockStalledSince, _renderClockDropouts;
    uint64_t                _renderClockLateCycles, _renderClockJumps, _renderClockSkippedFrames;
    VibeVoiceID             _underrunVoice;     // the voice _underrunFrames last read
    uint64_t                _underrunFrames;
#endif
    // Teardowns parked behind a stuck render (afterRenderLeavesOnQueue:). A
    // stuck render is waited for once: later withdrawals park at once until a
    // slice has finished since.
    NSMutableArray<dispatch_block_t> *_renderLeaveWork;
    BOOL                    _renderStuck;
    uint64_t                _renderStuckFrames;
    // nil under the debug pump, and on iOS until the first start.
    AudioOutputUnit         *_outputUnit;
    // The equalizer's meter: queue-confined intent and installation; the
    // publisher is stable for the player's lifetime.
    BOOL                    _levelsWanted;
    VibeAudioLevelNormalizationMode _levelNormalizationMode;
    AudioLevelPublisher     *_levelPublisher;
    AudioLevelMeter           *_levelMeter;

    // ---- Beta diagnostics (AudioPlayer+Diagnostics.m), in every build.
    BOOL                    _signalProbeWanted;
    uint64_t                _signalProbeRequest;
    NSDictionary            *_positionDiagnostic; // _stateLock; consumed once by main
    uint64_t                _firstRenderVoice;

#if TARGET_OS_OSX
    // ---- The output device: the device _outputUnit is bound to.
    // AudioPlayer+Devices.m owns every field below.
    // The bound device's nominal rate and hog owner, watched in every mode:
    // another process moving the rate rebinds the unit at the new rate, and
    // one taking the device parks playback and refuses starts until it lets
    // go (_boundDeviceHeldElsewhere). Delivered on the queue.
    AudioObjectPropertyListenerBlock _boundDeviceListener;
    AudioDeviceID           _boundDeviceListenerDeviceID;
    BOOL                    _boundDeviceHeldElsewhere;
    // The launch preference awaiting a successful HAL snapshot and bind.
    // Queue-confined. Until binding succeeds the output honestly follows
    // System Output (-1).
    NSString                *_pendingSavedDeviceUID;
    NSString                *_pendingSavedDeviceModelUID;
    NSString                *_pendingSavedDeviceName;
    // The concrete device this player last committed to, so a device that
    // VANISHES can be told apart from System Output the user chose.
    NSString                *_boundDeviceUID;
    NSString                *_boundDeviceModelUID;
    NSString                *_boundDeviceName;
    // Set only across one selectOutputDeviceOnQueue: call, when a wanted device
    // was found by its model UID under a new device UID: whose remembered modes
    // that bind should read. Nil means the device's own.
    NSString                *_modesUIDForNextSelection;
    // _stateLock: destination -> source until main has persisted the carry.
    NSMutableDictionary<NSString *, NSString *> *_unpersistedOutputModeSources;
    // Covers the async manager lookup and its checked bind, so a failed bind
    // resetting to Stopped cannot start another attempt.
    BOOL                    _pendingSavedDeviceLookupInFlight;
    // Coalesces the single delayed retry after a system-default read fails.
    BOOL                    _systemOutputBindRetryScheduled;
    // Bit-perfect output: the settings' queue-side intent.
    BOOL                    _bitPerfectWanted;
    BOOL                    _allowBitPerfectOnAnyDevice;
    // The device configureOutputDeviceOnQueue: is rebinding to, for the
    // duration of that call, else kAudioObjectUnknown.
    AudioDeviceID           _rebindDeviceID;
    BOOL                    _exclusiveOutputWanted;
    // Possible ownership, or kAudioObjectUnknown; retained until release is
    // confirmed, never overwritten by another device.
    AudioDeviceID           _hoggedDeviceID;
    // The one device whose format this run changed and has not yet put back.
    AudioDeviceID           _changedFormatDeviceID;
    AudioStreamID           _changedFormatStreamID;
    AudioStreamBasicDescription _formatBeforeChange;
    // The device the last prepare set up: its first output stream, the format
    // asked of it, and the listeners the HAL holds on it.
    AudioDeviceID           _preparedDeviceID;
    AudioStreamID           _preparedStreamID;
    AudioStreamBasicDescription _preparedFormat;
    AudioObjectPropertyListenerBlock _outputLevelListener;
    // The prepared device's volume, balance and mute as the report last read
    // them, trusted only while _outputLevelListener is registered.
    AudioDeviceID           _outputControlsDeviceID;
    AudioStreamID           _outputControlsStreamID;
    UInt32                  _outputControlsChannels;
    Float32                 _outputControlsVolume;
    Float32                 _outputControlsBalance;
    BOOL                    _outputControlsMuted;
    // The published report, under _stateLock.
    VibeBitPerfectReport    _bitPerfectReport;
#endif
}

#pragma mark - Read by the categories, written only by AudioPlayer.m

// Queue-confined unless noted. TRAP: these are plain nonatomic ivar reads,
// safe under _stateLock; the public `pitch` getter takes _stateLock itself,
// so code holding it reads `_pitch` directly — os_unfair_lock is not
// recursive, and re-taking it aborts.

// The in-flight open's identity, row and intent; see PlaybackRequestCoordinator.
@property (nonatomic, readonly, nullable) PlaybackRequestCoordinator *pendingRequest;

// The loading intent, mirrored under _stateLock for the main-thread getters
// and a seek's identity snapshot. The last submitted play binds a seek to a
// play submitted just before it, which the mirror does not show yet.
@property (nonatomic, readonly, nullable) AudioTrack *loadingTrack;
@property (nonatomic, readonly) uint64_t loadingSubmittedPlayIdentifier;
@property (nonatomic, readonly) uint64_t lastSubmittedPlayIdentifier;
@property (nonatomic, readonly, nullable) AudioTrack *lastSubmittedPlayTrack;
@property (nonatomic, readonly) BOOL loadingStartPaused;

@property (nullable, strong, readwrite) AudioTrack *currentTrack;
@property (atomic, readwrite) NSInteger currentlyRequestedAudioDeviceId;

#pragma mark - Queue-side helpers implemented in AudioPlayer.m

// Inline when already on _queue, where dispatch_sync would deadlock.
- (void)runSyncOnQueue:(NS_NOESCAPE dispatch_block_t)block;

// The audio-time clock for FX sweeps and the idle stop: the debug pump's under
// manual rendering, else dispatch_after on _queue. Wall-clock deadlines (the
// open timeout, the bind retry) use dispatch_after directly.
- (void)scheduleAfterSeconds:(NSTimeInterval)seconds block:(dispatch_block_t)block;

// The mode: bit-perfect output wanted. Always NO on iOS.
- (BOOL)bitPerfectOnQueue;
// Whether a real output is being driven by the hosted unit; never under the
// debug pump.
- (BOOL)drivesOutputDeviceOnQueue;

// The terminus every file open lands in, whether the play opened it or the
// prefetch did.
- (void)finishPlayOnQueueWithFile:(nullable AudioFileHandle *)file
                            error:(nullable NSError *)error
                     openRequestId:(uint64_t)openId;
// Drops the pending open, token and identifier both.
- (void)cancelPlayOpenOnQueue;
// The current track is done: natural end, or finishCurrentTrack.
- (void)finishPlaybackOnQueue;
- (void)stopOnQueue;
- (void)resetToStoppedStateOnQueue;
// Pauses the current voice where it is and tells the delegate. Under a
// stopped output the pause is a cut, applied at the next render.
- (void)pauseCurrentVoiceOnQueue;

// The voice vocabulary the transport speaks. Every declick-length ramp is a
// cut with Declick off, and under bit-perfect output every ramp is at most
// the declick; a retire at the declick length stops the voice's reads, so
// its file may be handed on. Retired voices are tracked until they end.
- (VibeVoiceRamp)rampOnQueueToGain:(float)gain milliseconds:(uint64_t)milliseconds action:(VibeVoiceAction)action;
// `frame` and `endFrame` are file frames; the stream ends at `endFrame`, 0 for
// the file's own end (AudioTrack endFrameInFile:).
- (VibeVoiceID)startVoiceOnQueueForFile:(AudioFileHandle *)file atFrame:(AVAudioFramePosition)frame
                               endFrame:(AVAudioFramePosition)endFrame
                       fadeMilliseconds:(uint64_t)milliseconds paused:(BOOL)paused;
- (void)retireVoiceOnQueue:(VibeVoiceID)voice milliseconds:(uint64_t)milliseconds;
- (void)cutRetiringVoicesToDeclickOnQueue;
// A new voice for the current file at `position`, the old one retiring beside
// it; requires a current voice and file.
- (void)revoiceOnQueueAtPosition:(NSTimeInterval)position;

// The full-tuple publisher; the two unpublish variants are the only partial
// writers. Anything that moves the position comes through here. `window` is
// the track's frames of `file` — its duration — and `startSeconds` is where in
// it the voice began.
- (void)publishState:(VibePlayerState)state
               voice:(VibeVoiceID)voice
                file:(nullable AudioFileHandle *)file
              window:(NSRange)window
        startSeconds:(NSTimeInterval)startSeconds
          baseFrames:(uint64_t)baseFrames;
- (VibeVoiceID)unpublishVoiceOnQueue;
- (VibeVoiceID)unpublishVoiceOnQueueEnteringTerminalState:(VibePlayerState)state;

// Recomputes and, on an edge, publishes the output-liveness fold: the output
// running and either the current voice playing or a retiring voice alive.
- (void)refreshOutputAudioActiveOnQueue;
// Publishes outputIdle; only the YES edge reaches the delegate.
- (void)publishOutputIdleOnQueue:(BOOL)idle;

- (void)sendDelegateError:(NSError *)error;
// Any thread. Checked inside every main-thread delivery: what matters is
// whether a newer play existed when it ran.
- (BOOL)submittedPlayIsCurrent:(uint64_t)submittedPlayIdentifier;
// The play-path variant drops an error whose submission a newer play has
// replaced. Every error carrying kVibeAudioErrorTrackURLKey must use it.
- (void)sendDelegateError:(NSError *)error forSubmittedPlay:(uint64_t)submittedPlayIdentifier;

- (void)handleVoiceEventOnQueue:(VibeVoiceEvent)event voice:(VibeVoiceID)voice;
// The buffering hold's decision, after every drain.
- (void)updateBufferingOnQueue;
// An estimated length's window, grown as the length grows and republished
// once, with the duration, when it settles: at every drain, a seek, a stall
// and a voice's end.
- (void)republishEstimatedWindowOnQueue;
@end

NS_ASSUME_NONNULL_END
