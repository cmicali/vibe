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
//  compiled: AudioPlayer+Devices.m on macOS, Vibe/iOS/AudioPlayer+Recovery.m
//  on iOS.
//

#import "AudioPlayer.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

// The category family, declared once here because every implementation file in
// it calls across category lines. Do not prune as unused: the .m files depend
// on them transitively. A file outside the family imports the one category it
// uses.
//
// Exactly one platform member is compiled: +Devices on macOS (the CoreAudio
// HAL layer, Audio/Devices/), +Recovery on iOS (Vibe/iOS/). Neither target
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
    // A play was requested and the file open is in flight, which can take up
    // to kFileOpenTimeoutSeconds for a cloud placeholder. There is no node or
    // file yet. isPlaying/isPaused reflect the pending start intent, while
    // position and duration read 0 rather than the previous track's values.
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
    uint64_t                _prefetchRequestId;

    // _gaplessFile is a private handle opened separately from the prefetch
    // park: AVAudioFile has one stateful read position and the node pre-reads
    // scheduled files on its own worker, so the armed segment must never share
    // the instance a play: would consume. All queue-confined; _gaplessQueued
    // additionally mirrors to _gaplessArmedForUI (under _stateLock) for the
    // lock-free isGaplessArmed, through setGaplessQueuedOnQueue:, the flag's
    // sole writer. INVARIANT: every [node stop] of the current node drops its
    // queued segment, so every such site clears the flag first and, when it
    // keeps playing the same file, re-arms after its reschedule.
    AudioTrack              *_gaplessTrack;
    AVAudioFile             *_gaplessFile;
    BOOL                    _gaplessQueued;
    uint64_t                _gaplessOpenRequestId;
    NSString                *_gaplessOpenPath; // in-flight open's claim, the prefetch pattern
    BOOL                    _gaplessArmedForUI; // _stateLock

    // ---- The fades, owned by AudioPlayer+Fades.m.
    // Crossfade-length retired fades in flight, registered by retireNode:.
    // Queue-confined. Stop, pause and the failure reset preempt them through
    // preemptRetiredFadesOnQueue, so an outgoing track cannot stay audible
    // for up to the full crossfade; declick-length retires never register.
    NSMutableArray<VibeRetiredFade *> *_retiredFades;
    // A pause fade is in flight. Queue-confined. A second playPause during the
    // fade-out cancels the pending pause and ramps back up rather than pausing
    // twice. The fade's completion clears it, and runs on preemption too, as
    // does preemptRampsOnQueue eagerly. The iOS config-change recovery must
    // yield to a pending pause, which owns the transport.
    BOOL                    _pausePending;
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
// Creates the engine and wires the master bus, debug argv flags
// (--no-audio-hw, --silent) included — the init path and the iOS
// media-services rebuild must configure the engine identically.
- (void)createEngineAndMasterBusOnQueue;
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(nullable AVAudioPlayerNode *)node
                        file:(nullable AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position;
- (void)sendDelegateError:(NSError *)error;

@end

NS_ASSUME_NONNULL_END
