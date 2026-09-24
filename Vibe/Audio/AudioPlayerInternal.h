//
//  AudioPlayerInternal.h
//  Vibe
//
//  The private surface shared between AudioPlayer.m and its categories: the
//  player state enum, the error constructors, and the class extension holding
//  the ivars and queue-side helpers the categories reach. Do not use it
//  outside the AudioPlayer implementation files; everything else goes through
//  AudioPlayer.h.
//
//  Ownership, in one place. The PLAYER QUEUE runs every transport verb and
//  every output mutation. _stateLock guards only the snapshot the main-thread
//  getters read — the published tuple that publishState:… writes whole. The
//  audio itself is the bus's (AudioVoiceBus.h): the transport starts voices,
//  ramps them, retires them, and drains the three events it needs back.
//
//  Two categories are platform-specific and only one is ever compiled:
//  AudioPlayer+Devices.m on macOS, Audio/iOS/AudioPlayer+Recovery.m on iOS.
//

#import "AudioPlayer.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenTimeoutMath.h"
#import "AudioLevelTap.h"
#import "AudioVoiceBus.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

// The category family, declared once here because every implementation file in
// it calls across category lines. A file outside the family imports the one
// category it uses. Exactly one platform member is compiled.
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#import "AudioOutputUnit.h"
#import <AudioToolbox/AudioToolbox.h>
#endif
#import "AudioPlayer+Diagnostics.h"
#import "AudioPlayer+Graph.h"
#import "AudioPlayer+Prefetch.h"

NS_ASSUME_NONNULL_BEGIN

// The pipeline's audio-thread state, AudioPlayer+Graph.m's.
typedef struct VibeMasterBus VibeMasterBus;

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // A play was requested and the file open is in flight, potentially for
    // the snapshotted cloud-open timeout budget. There is no voice or file
    // yet. isPlaying/isPaused reflect the pending start intent, while
    // position and duration read 0 rather than the previous track's values.
    VibePlayerStateLoading,
};

// Defined in AudioPlayer.m.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);

// Seconds → start frame, clamped to [0, fileLength - 1]: a past-the-end start
// lands on the last frame rather than on nothing.
static inline AVAudioFramePosition VibeClampedStartFrame(NSTimeInterval seconds, double sampleRate, AVAudioFramePosition fileLength) {
    AVAudioFramePosition frame = (AVAudioFramePosition)(seconds * sampleRate);
    return MAX(0, MIN(frame, fileLength - 1));
}

@interface AudioPlayer () {
    dispatch_queue_t        _queue;
    os_unfair_lock          _stateLock;
    BOOL                    _terminating; // queue-confined; no new work after quit cleanup

    // ---- The published tuple, under _stateLock, written whole by publishState:….
    VibePlayerState         _state;
    VibeVoiceID             _voice;             // the current voice, 0 while none
    AVAudioFile             *_file;             // its file; after a promote, the successor
    double                  _fileSampleRate;    // scalars, so a getter never messages an object
    AVAudioFramePosition    _fileLength;
    double                  _busSampleRate;
    NSTimeInterval          _voiceStartSeconds; // where in the file the voice began
    uint64_t                _promotedBaseFrames; // bus frames the voice consumed before its current file began
    BOOL                    _gaplessArmedForUI;
    BOOL                    _outputAudioActive;
    float                   _pitch;             // percent; see the warning at the pitch accessor below
    // Monotonic identity minted synchronously by every explicit play. Under
    // _stateLock because queue-side settlements and iOS recovery completions
    // compare against submissions made from main.
    uint64_t                _nextSubmittedPlayIdentifier;

    // ---- Queue-confined transport state.
    // The explicit play submission that owns the current voice. A promote
    // preserves it; a newer play, stop or failure clears it. Deliveries
    // capture it so a same-row replay cannot pass a track-identity guard.
    uint64_t                _activeSubmittedPlayIdentifier;
    PlaybackRequestCoordinator *_pendingRequest;
    // The fade-in length for the play in flight: the user's crossfade when it
    // replaced an audibly playing track, the declick minimum otherwise.
    uint64_t                _incomingFadeMilliseconds;
    // Voices fading out after a track change, seek or stop. Each leaves when
    // the drain reports it ended; together with the current voice they are
    // what outputAudioActive folds over.
    NSMutableArray<NSNumber *> *_retiringVoices;
    // The current voice's decode format, for the report and dump_state.
    AVAudioFormat           *_decodeFormat;

    // ---- The pending open: its token, and the abandon deadline in monotonic
    // uptime. A new underlying open snapshots its configuration; a same-row
    // replay preserves that open identifier and snapshot.
    AudioFileOpenToken      *_playOpenToken;
    uint64_t                _playOpenRequestId;
    NSTimeInterval          _openSubmittedUptime;
    NSTimeInterval          _openLastPositiveMovementUptime;
    VibeAudioOpenTimeoutConfiguration _openTimeoutSnapshot;

    // ---- The park and the successor (AudioPlayer+Prefetch.m).
    NSString                *_prefetchedPath;
    AVAudioFile             *_prefetchedFile;
    AudioTrack              *_prefetchedTrack;
    uint64_t                _prefetchGeneration;
    AudioTrack              *_requestedPrefetchTrack;
    NSString                *_requestedPrefetchPath;
    VibeAudioPrefetchRequestState _prefetchRequestState;
    AudioFileOpenToken      *_prefetchOpenToken;
    AudioTrack              *_successorTrack;   // the row queued on the current voice, else nil
    AVAudioFile             *_successorFile;    // the park's instance the bus was handed

    // ---- The render pipeline (AudioPlayer+Graph.m).
    VibeMasterBus           *_masterBus;        // what the audio thread reads; allocated once, freed at dealloc
    AVAudioFormat           *_masterFormat;     // the pipeline's format: stereo at the output's rate
    NSMutableArray          *_retiredRenderState; // objects a render would not leave in time, released at a later edge
    AudioVoiceBus           *_voiceBus;         // the source segment; nil until the first settlement
    BOOL                    _fxEnabled;         // the saved preference; bit-perfect outranks it
    uint64_t                _outputIdleStopGeneration;
    dispatch_source_t       _drainTimer;        // hardware only: 10 ms while the output runs voices
    id                      _manualPump;        // VibeManualRenderPump, debug builds only
#if !TARGET_OS_OSX
    AVAudioEngine           *_engine;           // the carrier: one source node into its output node
    AVAudioSourceNode       *_sourceNode;
#endif
    // The equalizer's tap: queue-confined intent and installation; the
    // publisher is stable for the player's lifetime.
    BOOL                    _levelsWanted;
    VibeAudioLevelNormalizationMode _levelNormalizationMode;
    AudioLevelPublisher     *_levelPublisher;
    AudioLevelTap           *_levelTap;

    // ---- Beta diagnostics (AudioPlayer+Diagnostics.m). Present in every
    // build so the header carries no conditional; unused otherwise.
    BOOL                    _signalProbeWanted;
    uint64_t                _signalProbeRequest;
    NSDictionary            *_positionDiagnostic; // _stateLock; consumed once by main
    uint64_t                _firstRenderVoice;

#if TARGET_OS_OSX
    // ---- The output device. The hosted HAL output unit that pulls the
    // pipeline is AudioPlayer+Graph.m's: its bound device is the output, and
    // it is nil under the debug pump, which has no device.
    // AudioPlayer+Devices.m owns every field below it.
    AudioOutputUnit         *_outputUnit;
    // The launch preference awaiting a successful HAL snapshot and bind.
    // Queue-confined. Until binding succeeds the engine honestly follows
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
    // The device configureOutputDeviceOnQueue: is rebinding to, for the
    // duration of that call, else kAudioObjectUnknown.
    AudioDeviceID           _rebindDeviceID;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    BOOL                    _exclusiveOutputWanted;
    // Possible ownership, or kAudioObjectUnknown; retained until release is
    // confirmed, never overwritten by another device.
    AudioDeviceID           _hoggedDeviceID;
#endif
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

// Readonly so that an accidental write from a category is a compile error
// rather than a race. Queue-confined unless noted.
//
// TRAP: these getters are auto-synthesized and nonatomic, so they are plain
// ivar reads and safe to call while holding _stateLock. The PUBLIC `pitch`
// accessor in AudioPlayer.h is not — it takes _stateLock itself, so code
// already holding the lock must read `_pitch` directly. os_unfair_lock is not
// recursive, so getting this wrong aborts the process on the first play.

// The in-flight open's identity, row and intent; see PlaybackRequestCoordinator.
@property (nonatomic, readonly, nullable) PlaybackRequestCoordinator *pendingRequest;

// The loading intent, mirrored under _stateLock so that main-thread getters and
// a seek's identity snapshot never touch queue-confined pending state. The
// submitted-play identity binds a seek to the exact queued play: a play can be
// submitted just before seekToPosition: snapshots the mirror, and without these
// the seek would evaporate in that gap.
@property (nonatomic, readonly, nullable) AudioTrack *loadingTrack;
@property (nonatomic, readonly) uint64_t loadingSubmittedPlayIdentifier;
@property (nonatomic, readonly) uint64_t lastSubmittedPlayIdentifier;
@property (nonatomic, readonly, nullable) AudioTrack *lastSubmittedPlayTrack;
@property (nonatomic, readonly) BOOL loadingStartPaused;

// Readwrite here, readonly in AudioPlayer.h: currentTrack is written on
// _queue, the device id from the init and device-switch paths.
@property (nullable, strong, readwrite) AudioTrack *currentTrack;
@property (atomic, readwrite) NSInteger currentlyRequestedAudioDeviceId;

#pragma mark - Queue-side helpers implemented in AudioPlayer.m

// Runs block beside the mutable state and returns only once it has: inline
// when the caller is already on _queue, because dispatch_sync onto our own
// queue deadlocks.
- (void)runSyncOnQueue:(NS_NOESCAPE dispatch_block_t)block;

// The audio-time clock for FX sweeps, drains and the idle stop: the debug
// pump's under manual rendering, else dispatch_after on _queue. Wall-clock
// deadlines (the open timeout, the system-output bind retry) use dispatch_after
// directly, because rendered frames must not advance them.
- (void)scheduleAfterSeconds:(NSTimeInterval)seconds block:(dispatch_block_t)block;

// The mode: bit-perfect output wanted. Always NO on iOS.
- (BOOL)bitPerfectOnQueue;
// Whether a real output device is being driven: the hosted unit on macOS,
// the engine's own output node on iOS; never under the debug pump.
- (BOOL)drivesOutputDeviceOnQueue;

// The terminus every file open lands in, whether the play opened it or the
// prefetch did.
- (void)finishPlayOnQueueWithFile:(nullable AVAudioFile *)file
                            error:(nullable NSError *)error
                     openRequestId:(uint64_t)openId;
// Drops the pending open, token and identifier both.
- (void)cancelPlayOpenOnQueue;
// The current track is done: natural end, or finishCurrentTrack.
- (void)finishPlaybackOnQueue;
- (void)stopOnQueue;
- (void)resetToStoppedStateOnQueue;
// Pauses the current voice where it is and tells the delegate. Under a
// stopped engine the pause is a cut, applied at the next render.
- (void)pauseCurrentVoiceOnQueue;

// The voice vocabulary the transport speaks. Every declick-length ramp is a
// cut with Declick off, and under bit-perfect output every ramp is at most
// the declick; a retire at the declick length stops the voice's reads, so
// its file may be handed on. Retired voices are tracked until they end.
- (VibeVoiceRamp)rampOnQueueToGain:(float)gain milliseconds:(uint64_t)milliseconds action:(VibeVoiceAction)action;
- (VibeVoiceID)startVoiceOnQueueForFile:(AVAudioFile *)file atFrame:(AVAudioFramePosition)frame
                       fadeMilliseconds:(uint64_t)milliseconds paused:(BOOL)paused;
- (void)retireVoiceOnQueue:(VibeVoiceID)voice milliseconds:(uint64_t)milliseconds;
- (void)cutRetiringVoicesToDeclickOnQueue;
// A new voice for the current file at `position`, the old one retiring beside
// it; requires a current voice and file.
- (void)revoiceOnQueueAtPosition:(NSTimeInterval)position;

// The writer model for the published tuple: this is the FULL-TUPLE publisher,
// and the two unpublish variants are the only partial writers. Anything that
// moves the position must come through here.
- (void)publishState:(VibePlayerState)state
               voice:(VibeVoiceID)voice
                file:(nullable AVAudioFile *)file
        startSeconds:(NSTimeInterval)startSeconds
          baseFrames:(uint64_t)baseFrames;
- (VibeVoiceID)unpublishVoiceOnQueue;
- (VibeVoiceID)unpublishVoiceOnQueueEnteringTerminalState:(VibePlayerState)state;

// Recomputes and, on an edge, publishes the output-liveness fold: the engine
// running and either the current voice playing or a retiring voice alive.
- (void)refreshOutputAudioActiveOnQueue;

- (void)sendDelegateError:(NSError *)error;
// Thread-safe submission identity check, used inside every main-thread
// delivery: what matters is whether a newer play existed when it ran.
- (BOOL)submittedPlayIsCurrent:(uint64_t)submittedPlayIdentifier;
// The play-path variant drops an error whose submission a newer play has
// replaced. Every error carrying kVibeAudioErrorTrackURLKey must use it.
- (void)sendDelegateError:(NSError *)error forSubmittedPlay:(uint64_t)submittedPlayIdentifier;

@end

NS_ASSUME_NONNULL_END
