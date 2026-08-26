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
//  Two of those categories are platform-specific and only one is ever
//  compiled: AudioPlayer+Devices.m on macOS, Audio/iOS/AudioPlayer+Recovery.m
//  on iOS.
//

#import "AudioPlayer.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenTimeoutMath.h"
#import "AudioLevelTap.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

// The category family, declared once here because every implementation file in
// it calls across category lines. Do not prune as unused: the .m files depend
// on them transitively. A file outside the family imports the one category it
// uses.
//
// Exactly one platform member is compiled: +Devices on macOS (the CoreAudio
// HAL layer, Audio/Mac/Devices/), +Recovery on iOS (Audio/iOS/). Neither target
// sees the other's, so this one import is conditional.
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#endif
#import "AudioPlayer+Engine.h"
#import "AudioPlayer+Fades.h"
#import "AudioPlayer+Gapless.h"
#import "AudioPlayer+Graph.h"
#import "AudioPlayer+Seek.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // A play was requested and the file open is in flight, potentially for
    // the snapshotted cloud-open timeout budget. There is no node or file yet.
    // isPlaying/isPaused reflect the pending start intent, while position and
    // duration read 0 rather than the previous track's values.
    VibePlayerStateLoading,
};

// Defined in AudioPlayer.m.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying);
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError * _Nullable underlying, NSURL * _Nullable trackURL);

// Seconds → start frame for scheduling, clamped to [0, fileLength - 1]: a
// past-the-end start lands on the last frame rather than scheduling an empty
// segment.
static inline AVAudioFramePosition VibeClampedStartFrame(NSTimeInterval seconds, double sampleRate, AVAudioFramePosition fileLength) {
    AVAudioFramePosition frame = (AVAudioFramePosition)(seconds * sampleRate);
    return MAX(0, MIN(frame, fileLength - 1));
}

// A retired node/varispeed pair whose fade-out is in flight; see
// AudioPlayer+Fades.h. Declared here because _retiredFades is typed on it.
@interface VibeRetiredFade : NSObject
@property (nonatomic, strong) AVAudioPlayerNode *node;
@property (nonatomic, strong) AVAudioUnitVarispeed *varispeed;
@property (nonatomic) BOOL countedAsOutput;
@property (nonatomic) uint64_t outputGeneration;
@end

// Only the state a category also touches lives here; the rest stays private to
// AudioPlayer.m.
@interface AudioPlayer () {
    dispatch_queue_t        _queue;
    AVAudioEngine           *_engine;
    AVAudioPlayerNode       *_node;
    AVAudioFile             *_file;
    AVAudioFramePosition    _segmentStartFrame;
    uint64_t                _segmentGeneration;
    // Monotonic identity minted synchronously by every explicit play. It is
    // guarded by _stateLock because queue-side settlements and iOS recovery
    // completions compare against submissions made from main.
    uint64_t                _nextSubmittedPlayIdentifier;
    // The explicit play submission which owns the currently sounding graph.
    // Gapless promotion preserves it; a newer explicit play, stop, or failure
    // clears it. Natural-end and promotion deliveries capture it so replaying
    // the same row cannot pass a track-identity guard on main.
    uint64_t                _activeSubmittedPlayIdentifier;
    // Bumped by every path that preempts an async volume ramp: pause, resume,
    // seek, skip and device switch. Each ramp step aborts once its captured
    // value goes stale, so a resume fade-in cannot drive the volume back up
    // after a pause.
    uint64_t                _rampGeneration;
    // Bumped by startEngineAndPlayNode:, the single funnel for starting
    // playback, to dissolve a deferred idle engine stop. AudioPlayer+Engine.m
    // owns it. Queue-confined.
    uint64_t                _engineIdleStopGeneration;
    VibePlayerState         _state;
    os_unfair_lock          _stateLock;
    // Guarded by _stateLock, in percent, so the UI can read it without touching
    // the queue. See the warning below about the public pitch accessor.
    float                   _pitch;

    // ---- The next track's park and splice, owned by AudioPlayer+Gapless.m;
    // see its header for the rules they live by.
    NSString                *_prefetchedPath;
    AVAudioFile             *_prefetchedFile;
    AudioTrack              *_prefetchedTrack;
    uint64_t                _prefetchGeneration;
    AudioTrack              *_requestedPrefetchTrack;
    NSString                *_requestedPrefetchPath;
    VibeAudioPrefetchRequestState _prefetchRequestState;

    // ---- Delivery tokens for the bounded open coordinator. Cancelling one
    // detaches this player and aborts materialization, but an AVAudioFile open
    // already blocked in the OS remains registered by standardized path until
    // it returns. A retry can therefore bind to that claim instead of creating
    // another stranded worker. Queue-confined.
    AudioFileOpenToken      *_playOpenToken;
    uint64_t                _playOpenRequestId;
    AudioFileOpenToken      *_prefetchOpenToken;

    // ---- The pending open's abandon deadline, queue-confined and measured
    // in monotonic uptime. A new underlying open snapshots its configuration;
    // a same-row replay preserves that open identifier and snapshot. Positive
    // movement alone stamps the second clock. One logical deadline re-arms
    // for the remainder, and stale firings fail the open-identifier check.
    NSTimeInterval          _openSubmittedUptime;
    NSTimeInterval          _openLastPositiveMovementUptime;
    VibeAudioOpenTimeoutConfiguration _openTimeoutSnapshot;

    // _gaplessFile is a private handle opened separately from the prefetch
    // park: AVAudioFile has one stateful read position and the node pre-reads
    // scheduled files on its own worker, so the armed segment must never share
    // the instance a play: would consume. All queue-confined; _gaplessQueued
    // additionally mirrors to _gaplessArmedForUI (under _stateLock) for
    // isGaplessArmed to snapshot, through setGaplessQueuedOnQueue:, the flag's
    // sole writer. ALWAYS: every [node stop] of the current node drops its
    // queued segment, so every such site clears the flag first and, when it
    // keeps playing the same file, re-arms after its reschedule.
    AudioTrack              *_gaplessTrack;
    AVAudioFile             *_gaplessFile;
    BOOL                    _gaplessQueued;
    uint64_t                _gaplessOpenGeneration;
    NSString                *_gaplessOpenPath; // in-flight open's claim, the prefetch pattern
    AudioFileOpenToken      *_gaplessOpenToken;
    BOOL                    _gaplessArmedForUI; // _stateLock

#if TARGET_OS_OSX
    // The launch preference awaiting a successful HAL snapshot and bind.
    // Queue-confined. It is not the reported requested ID: until binding
    // succeeds the engine honestly follows System Output (-1).
    NSString                *_pendingSavedDeviceUID;
    NSString                *_pendingSavedDeviceName;
    // Covers the async manager lookup and its checked bind. A Stopped-state
    // hook cannot start another attempt while a failed bind is resetting back
    // to Stopped, which would otherwise create an immediate retry loop.
    BOOL                    _pendingSavedDeviceLookupInFlight;
    // Coalesces the single delayed retry after a system-default property read
    // fails. It stays set through that retry so a persistent failure cannot
    // create a polling loop.
    BOOL                    _systemOutputBindRetryScheduled;
#endif

    // ---- The fades, owned by AudioPlayer+Fades.m.
    // Crossfade-length retired fades in flight, registered by retireNode:.
    // Queue-confined. Stop, pause, a parked play and the failure reset preempt
    // them through preemptRetiredFadesOnQueue, so an outgoing track cannot stay
    // audible for up to the full crossfade; declick-length retires never register.
    NSMutableArray<VibeRetiredFade *> *_retiredFades;
    // A pause fade is in flight. Queue-confined. A second playPause during the
    // fade-out cancels the pending pause and ramps back up rather than pausing
    // twice. The fade's completion clears it, and runs on preemption too, as
    // does preemptRampsOnQueue eagerly. The iOS config-change recovery must
    // yield to a pending pause, which owns the transport.
    BOOL                    _pausePending;

    // ---- The equalizer indicator's level tap.
    // The public levelsEnabled's intent, carried onto the queue by its setter
    // and queue-confined thereafter. It is read again by every master-bus
    // wiring, which is how a media-services rebuild comes back with the tap it
    // had; the public property is main-thread state and must not be read here.
    BOOL                    _levelsWanted;
    // Queue-confined analyzer mode. Debug may replace the active tap to change it.
    VibeAudioLevelNormalizationMode _levelNormalizationMode;
    // Stable for the AudioPlayer lifetime. Engine resets replace only the tap
    // session, so main-thread readers never load an atomic Objective-C owner and a
    // snapshot sequence never goes backwards.
    AudioLevelPublisher     *_levelPublisher;
    // Queue-confined. Display readers use _levelPublisher, not this object.
    AudioLevelTap           *_levelTap;

    // ---- Actual modeled audio-output liveness.
    // _activeRetiredOutputCount and its generation are queue-confined. The
    // published bool is guarded by _stateLock for the shell's nonblocking
    // getter. A generation lets a completion retained by a dead engine no-op
    // after media-services reset has cleared the count.
    NSUInteger              _activeRetiredOutputCount;
    uint64_t                _retiredOutputGeneration;
    BOOL                    _outputAudioActive;

    // ---- Read by AudioPlayer+State, written by publishPlaybackState:.
    // Last position computed from a valid playerTime, guarded by _stateLock.
    // When the engine stops itself, on a device unplug or format change,
    // lastRenderTime goes nil before the recovery path can read the position.
    // Without this cache, recovery restores from the segment start and the
    // track restarts at 0:00, or at the last seek point.
    //
    // An ivar rather than one of the readonly properties below, because the
    // position getter is a second writer: it computes off-lock and stores the
    // result back under the epoch check. Everything else in the position state
    // keeps the write protection.
    NSTimeInterval          _lastValidPosition;
#if TARGET_OS_IOS
    // Tags the iOS player-owned sampling loop which refreshes the cache while
    // a backgrounded screen has stopped its UI timer. Queue-confined; every
    // published state starts or dissolves a loop.
    uint64_t                _recoveryPositionGeneration;
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

// Sits between the current player node and the mixer. playOnQueue: mints a
// fresh one per track, so a track change crossfades on two independent chains
// without rerouting the live node; nil until the first play.
@property (nonatomic, readonly, nullable) AVAudioUnitVarispeed *varispeed;

// The in-flight open's generation, path, current rebound row and start intent;
// see PlaybackRequestCoordinator.
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

// Unclamped twin of the paused position, written by every publish and
// overridden by completePauseOfNode: with the true rendered position. The
// position getter clamps to the file's duration, so a pause landing just after
// a gapless boundary records the frames already rendered into the queued next
// track only here; promoteGaplessOnQueue's paused fallback is the one reader.
@property (nonatomic, readonly) NSTimeInterval pausedRawPosition;

// The position state AudioPlayer+State's readers answer from, all under
// _stateLock. The paused position is what position returns once the node stops
// reporting; the epoch is bumped by every queue-side write of the three, and is
// what lets the position getter tell its own off-lock result from one a seek or
// a track change has since superseded. loadingStartPaused is the pending
// start's intent, which is what isPlaying and isPaused report while Loading.
@property (nonatomic, readonly) NSTimeInterval pausedPosition;
@property (nonatomic, readonly) uint64_t positionEpoch;
@property (nonatomic, readonly) BOOL loadingStartPaused;

// Readwrite here, readonly in AudioPlayer.h: currentTrack is written on
// _queue, the device id from the init and device-switch paths.
@property (nullable, strong, readwrite) AudioTrack *currentTrack;
@property (atomic, readwrite) NSInteger currentlyRequestedAudioDeviceId;

// Queue-side helpers implemented in AudioPlayer.m, which carries their
// contracts. All run on _queue. The first two are the entry points the
// categories call back into: the segment completion that routes a boundary or
// a natural end, and the terminus every file open lands in, whether the play
// opened it or the prefetch did.
- (void)segmentDidCompleteWithGeneration:(uint64_t)generation;
- (void)finishPlayOnQueueWithFile:(nullable AVAudioFile *)file
                            error:(nullable NSError *)error
                     openRequestId:(uint64_t)openId;

- (void)resetToStoppedStateOnQueue;
// Forgets every reference bound to the current engine without messaging it;
// the iOS media-services-reset rebuild's first half.
- (void)dropEngineBoundStateOnQueue;
// Wires the master bus on a fresh engine: the FX segment, or, with FX
// disabled, the mixer straight to the output. The rebuild's second half.
- (void)installMasterBusOnQueue;
// Reconciles tap demand. Also called after a successful engine start so a
// temporary unusable-format failure can recover without toggling demand.
- (void)applyLevelTapOnQueue;
// Creates the engine and wires the master bus, debug argv flags
// (--no-audio-hw, --silent) included — the init path and the iOS
// media-services rebuild must configure the engine identically.
- (void)createEngineAndMasterBusOnQueue;
// The permitted partial writers of the published playback state; the full
// model, and why there are exactly three of them, is at publishPlaybackState:
// in AudioPlayer.m. Both return the node they unpublished, for the caller to
// stop and detach off the lock.
- (nullable AVAudioPlayerNode *)unpublishNodeOnQueue;
- (nullable AVAudioPlayerNode *)unpublishNodeOnQueueEnteringTerminalState:(VibePlayerState)state;
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(nullable AVAudioPlayerNode *)node
                        file:(nullable AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position;
// Recomputes and, on an edge, publishes current-node + retired-fade output
// liveness. Every tracked fade completion and state publication funnels here.
- (void)refreshOutputAudioActiveOnQueue;
- (void)sendDelegateError:(NSError *)error;
// Thread-safe submission identity check. Delivery sites call it inside their
// main hop; the gapless park also uses it on _queue before starting work for a
// playback settlement a newer submission already superseded.
- (BOOL)submittedPlayIsCurrent:(uint64_t)submittedPlayIdentifier;
// The play-path variant, which drops an error whose submission a newer play
// has already replaced. Every error carrying kVibeAudioErrorTrackURLKey must
// use it: the shells cannot tell a superseded same-row failure from a current
// one, and acting on it strips state the newer play has already set up.
- (void)sendDelegateError:(NSError *)error forSubmittedPlay:(uint64_t)submittedPlayIdentifier;

@end

NS_ASSUME_NONNULL_END
