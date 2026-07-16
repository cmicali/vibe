//
//  AudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioDeviceManager.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

typedef NS_ENUM(NSInteger, VibePlayerState) {
    VibePlayerStateStopped = 0,
    VibePlayerStatePlaying,
    VibePlayerStatePaused,
    // A play was requested and the file open is in flight (can take up to
    // kFileOpenTimeoutSeconds for a cloud placeholder). No node/file yet, but
    // playback is imminent — isPlaying reports YES so the UI holds the pause
    // icon, while position/duration read 0 instead of the previous track's.
    VibePlayerStateLoading,
};

NSString *const kVibeAudioErrorDomain = @"com.commonwealthrecordings.Vibe";

static NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
        if (underlying.localizedDescription.length) {
            description = [NSString stringWithFormat:@"%@ (%@)", description, underlying.localizedDescription];
        }
    }
    info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:kVibeAudioErrorDomain code:code userInfo:info];
}

// How long a file open may block (cloud placeholders download on demand)
// before the play request is abandoned with an error.
static const NSTimeInterval kFileOpenTimeoutSeconds = 20.0;

// A still-pending open after this long is worth a visible loading state.
static const NSTimeInterval kSlowOpenIndicatorDelaySeconds = 0.5;

// How long the engine may sit idle (Stopped) before it is stopped to release
// the output device. Deferred rather than immediate: a natural track end is
// followed within milliseconds by the auto-advance's play, and an immediate
// stop made every consecutive-track transition pay an output-unit stop+start
// (10-50ms, worse on Bluetooth). Long enough to absorb even a slow next-track
// open; short enough that the device is released promptly when playback
// really ends.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 2.0;

// 25ms (10 steps x 2.5ms) multiplicative (perceptually log, like
// BASS_SLIDE_LOG) volume ramps.
// Step delay in microseconds, fed to dispatch_after via NSEC_PER_USEC.
static const int kFadeSteps = 10;
static const uint64_t kFadeStepMicroseconds = 2500;
static const float kFadeFloor = 0.001f; // -60 dB

static float VibeFadeVolume(float from, float to, int step) {
    if (step >= kFadeSteps) {
        return to;
    }
    float f = MAX(from, kFadeFloor);
    float t = MAX(to, kFadeFloor);
    return f * powf(t / f, (float)step / (float)kFadeSteps);
}

// Default pitch fader range in percent (±8%, matching a stock SL-1200).
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so dealloc can tell whether it is
// already running ON the queue (a queued block dropping the last reference)
// — dispatch_sync onto the current queue deadlocks.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

@interface AudioPlayer () <AudioDeviceManagerObserver>
@end

@implementation AudioPlayer {
    dispatch_queue_t        _queue;
    AVAudioEngine           *_engine;
    AVAudioPlayerNode       *_node;
    // Varispeed sits between the current player node and the mixer. A fresh one
    // is created per track (playOnQueue:) so a track change crossfades on two
    // independent chains without rerouting the live node; _varispeed always
    // points at the current/incoming track's, and is nil until the first play
    // mints one (a pre-play setPitch: only records _pitch — the rate is
    // re-applied to every new varispeed in connectNode:throughVarispeed…).
    // Rate changes resample like a turntable motor: tempo and pitch move
    // together. _pitch (percent) is guarded by _stateLock so the UI can read
    // it without touching the queue.
    AVAudioUnitVarispeed    *_varispeed;
    float                   _pitch;
    float                   _maxPitch;
    AVAudioFile             *_file;
    AVAudioFramePosition    _segmentStartFrame;
    NSTimeInterval          _pausedPosition;
    // Last position computed from a valid playerTime (guarded by _stateLock).
    // When the engine stops ITSELF (device unplug/format change), lastRenderTime
    // goes nil before the recovery path can read the position — without this,
    // recovery restores from the segment start and the track restarts at 0:00
    // (or the last seek point). Reset alongside every _pausedPosition write.
    NSTimeInterval          _lastValidPosition;
    // Bumped (under _stateLock) by every queue-side write of the position
    // state above. The position getter runs concurrently on the main thread
    // and writes _lastValidPosition back after computing off-lock; without
    // the epoch check a getter that snapshotted pre-seek state could clobber
    // the freshly seeked position with a stale one.
    uint64_t                _positionEpoch;
    uint64_t                _generation;
    uint64_t                _openRequestId;
    // Bumped by every path that preempts an async volume ramp (pause, resume,
    // seek, skip, device switch); each ramp step aborts once its captured value
    // goes stale, so a resume fade-in can't drive volume back up after a pause.
    uint64_t                _rampGeneration;
    // Path of the track whose open is currently in flight (matching
    // _openRequestId), or nil. Mutated only on _queue. Re-selecting the same
    // still-loading track is a no-op (its open will deliver) rather than
    // stranding a second blocked global-queue worker on initForReading:.
    NSString *_currentOpenPath;
    // The AudioTrack the in-flight open should deliver. Normally the object
    // passed to play:, but a same-path replay REBINDS it: a drag/drop of the
    // same file replaces the playlist with fresh AudioTrack objects, and the
    // open must complete with the object the new playlist actually contains —
    // otherwise row state, artwork, and end-of-track advance all mismatch.
    AudioTrack *_pendingOpenTrack;
    // Pre-opened handle for the playlist's likely-next track (prefetchTrack:).
    // Queue-confined. Consumed (single use) by a play: of the same path,
    // skipping the file open — the dominant transition latency. The request
    // id pairs each prefetch with its async open so a superseded prefetch
    // can't park a stale handle. The handle holds an open fd, so a file
    // rewritten between prefetch and play plays the bytes as prefetched —
    // same behavior as a file rewritten mid-playback.
    NSString                *_prefetchedPath;
    AVAudioFile             *_prefetchedFile;
    uint64_t                _prefetchRequestId;
    // Bumped by startEngineAndPlayNode: (the single funnel for starting
    // playback) to dissolve the deferred idle engine stop
    // (scheduleEngineIdleStopOnQueue). Queue-confined.
    uint64_t                _engineIdleStopGeneration;
    VibePlayerState         _state;
    os_unfair_lock          _stateLock;
    // A pause fade is in flight (queue-confined). A second playPause during
    // the ~25ms fade-out cancels the pending pause and ramps back up instead
    // of pausing twice; cleared unconditionally by the fade's completion
    // (which runs on preemption too), so it can't go stale.
    BOOL                    _pausePending;
    id                      _configChangeObserver;
}

#pragma mark - Init

- (id)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate {
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _maxPitch = kDefaultMaxPitchPercent;
        // Meaningful before the async init block resolves the saved device:
        // -1 (follow system default) instead of a bogus device id 0.
        self.currentlyRequestedAudioDeviceId = -1;
        // Default QoS (not user-initiated): this queue owns the engine graph
        // and calls blocking AVAudioEngine APIs — [node stop], detachNode:,
        // engine start/stop — which wait on the engine's internal
        // graph-reconfiguration thread (Default QoS). A user-initiated queue
        // blocking on that lower-QoS thread is a priority inversion (flagged by
        // the Thread Performance Checker on the skip teardown). Matching Default
        // removes the inversion; the latency-critical file open runs on its own
        // user-initiated global queue (see playOnQueue:), so control-plane
        // scheduling here staying at Default costs nothing perceptible.
        _queue = dispatch_queue_create("com.vibe.audioplayer",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        dispatch_queue_set_specific(_queue, kAudioPlayerQueueKey, kAudioPlayerQueueKey, NULL);
        self.delegate = delegate;
        dispatch_async(_queue, ^{

            LogDebug(@"AudioPlayer init");

            self->_engine = [[AVAudioEngine alloc] init];

            // Resolve the saved device here rather than on the main thread:
            // this is the app's first CoreAudio device enumeration (per-device
            // HAL property reads — tens of ms with Bluetooth/aggregate devices
            // present), and the caller runs before the window's first paint.
            // UID first (robust against duplicate device names); name is the
            // fallback for pre-UID settings.
            AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForUID:deviceUID];
            if (!device) {
                device = [[AudioDeviceManager sharedInstance] outputDeviceForName:deviceName];
            }
            // nil device (empty/unmatched UID and name) means follow the system default.
            NSInteger deviceIndex = device ? device.deviceId : -1;
            self.currentlyRequestedAudioDeviceId = deviceIndex;
            if (deviceIndex >= 0) {
                [self setOutputUnitDevice:(AudioDeviceID)deviceIndex];
            }
            else if (deviceUID.length > 0 || deviceName.length > 0) {
                // A device was saved but is gone: fall back to System Output
                // for good, not just this launch — the delegate persists the
                // -1 choice, so the old device won't reclaim the checkmark if
                // it reappears later.
                run_on_main_thread({
                    [self.delegate audioPlayer:self didChangeOutputDevice:-1];
                });
            }
            // The engine isn't started until the first play.

            [[AudioDeviceManager sharedInstance] addObserver:self];

            __weak AudioPlayer *weakSelf = self;
            self->_configChangeObserver = [[NSNotificationCenter defaultCenter]
                    addObserverForName:AVAudioEngineConfigurationChangeNotification
                                object:self->_engine
                                 queue:nil
                            usingBlock:^(NSNotification *note) {
                                AudioPlayer *strongSelf = weakSelf;
                                if (strongSelf) {
                                    dispatch_async(strongSelf->_queue, ^{
                                        [strongSelf handleEngineConfigurationChange];
                                    });
                                }
                            }];

            run_on_main_thread({
                [self.delegate audioPlayerDidInitialize:self];
            });

        });
    }
    return self;
}

- (void)dealloc {
    if (_configChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configChangeObserver];
    }
    [[AudioDeviceManager sharedInstance] removeObserver:self];
    // Engine mutation belongs on _queue like everywhere else. dispatch_sync
    // from here cannot deadlock against in-flight queue work: a queued block
    // either holds a strongSelf (then the retain count is nonzero and dealloc
    // isn't running) or resolves its weakSelf to nil and returns without
    // dispatching anywhere (run_on_main_thread is async besides). The one
    // remaining hazard is dealloc itself running ON _queue — a queued block
    // releasing the last reference — so that case tears down inline.
    AVAudioPlayerNode *node = _node;
    AVAudioEngine *engine = _engine;
    if (dispatch_get_specific(kAudioPlayerQueueKey) == kAudioPlayerQueueKey) {
        [node stop];
        [engine stop];
    }
    else {
        dispatch_sync(_queue, ^{
            [node stop];
            [engine stop];
        });
    }
}

#pragma mark - Playback

- (void)play:(AudioTrack *)track {
    dispatch_async(_queue, ^{
        [self playOnQueue:track];
    });
}

- (void)playOnQueue:(AudioTrack *)track {
    NSString *path = track.url.path;
    if (_state == VibePlayerStateLoading && [path isEqualToString:_currentOpenPath]) {
        // This exact file is already loading (its open is in flight). Don't
        // start another open — that would strand a second blocked worker and
        // (for a slow file) flash a spurious timeout error before the first
        // completes. But DO rebind the delivery to the new track object: a
        // re-drop replaces the playlist with fresh AudioTrack instances, and
        // completing with the old one would orphan the open's result.
        // Checked before ANY teardown so a re-click of the loading row is a
        // true no-op — not a generation bump plus a varispeed swap whose
        // in-flight open then plays through a needlessly rebuilt chain.
        _pendingOpenTrack = track;
        return;
    }

    _generation++;
    _rampGeneration++; // preempt any in-flight resume fade-in

    // Dual-varispeed crossfade: the incoming track gets a BRAND-NEW varispeed,
    // and the outgoing node is retired together with its OLD one. The outgoing
    // node's live connection is therefore never rerouted — rerouting a running
    // node reconfigures the graph and clicks (the same reason the seek path
    // never reconnects); here we only ramp its volume. The two tracks ride
    // independent player->varispeed->mixer chains, so the incoming's connect
    // can't steal the outgoing's bus, and each varispeed is connected exactly
    // once for one track's format (no cross-format reconnection — see
    // connectNode:throughVarispeedWithFormat:).
    AVAudioPlayerNode *oldNode = _node;
    AVAudioUnitVarispeed *oldVarispeed = _varispeed;
    os_unfair_lock_lock(&_stateLock);
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);

    AVAudioUnitVarispeed *newVarispeed = [[AVAudioUnitVarispeed alloc] init];
    [_engine attachNode:newVarispeed];
    _varispeed = newVarispeed; // the incoming node (finishPlayOnQueue:) connects through this

    AVAudioEngine *engine = _engine;
    if (oldNode && _engine.isRunning && _state == VibePlayerStatePlaying) {
        // Audible: fade the outgoing node out on its own varispeed, then detach
        // both once silent. The incoming node fades in concurrently on the new
        // varispeed (finishPlayOnQueue:) for a true crossfade. The retired-node
        // ramp (not the generation-tagged one): a second skip, pause, or seek
        // inside the fade window must not preempt this fade — its completion
        // would then stop the node at mid-fade volume, which is a click.
        [self rampRetiredNodeAsync:oldNode step:1 from:oldNode.volume completion:^{
            [oldNode stop];
            [engine detachNode:oldNode];
            [engine detachNode:oldVarispeed];
        }];
    } else {
        // Nothing audible (paused/stopped/first play): tear the old node and
        // varispeed down immediately — at silence, so there is nothing to click.
        if (oldNode) {
            [oldNode stop];
            [engine detachNode:oldNode];
        }
        if (oldVarispeed) {
            [engine detachNode:oldVarispeed];
        }
    }

    self.currentTrack = nil;

    LogDebug(@"play file: %@", path);

    // Enter the loading state: no node/file yet, but a play is committed. This
    // clears the previous track's file/position so the UI stops showing stale
    // duration/position for up to the full open timeout.
    [self publishPlaybackState:VibePlayerStateLoading node:nil file:nil segmentStart:0 position:0];

    // A prefetched handle for this exact path skips the open entirely — the
    // transition goes straight to schedule+play. Ownership passes to the
    // normal finish path with a fresh open id, so it consumes the id like any
    // completed open and no timeout/loading-indicator timers ever exist.
    if (_prefetchedFile && [path isEqualToString:_prefetchedPath]) {
        AVAudioFile *prefetchedFile = _prefetchedFile;
        _prefetchedFile = nil;
        _prefetchedPath = nil;
        _currentOpenPath = path;
        _pendingOpenTrack = track;
        [self finishPlayOnQueue:track file:prefetchedFile error:nil openRequestId:++_openRequestId];
        return;
    }

    // Open the file off-queue: a cloud placeholder (iCloud/Dropbox) blocks
    // the open until it materializes, and that must never wedge the player
    // queue. The request id pairs each open with its timeout; whichever
    // fires first consumes the id and the other becomes a no-op.
    _currentOpenPath = path;
    _pendingOpenTrack = track;
    uint64_t openId = ++_openRequestId;
    __weak AudioPlayer *weakSelf = self;
    if (_prefetchedPath && [path isEqualToString:_prefetchedPath]) {
        // The prefetch open for this exact path is still in flight (claimed,
        // not landed — the parked-handle case returned above). Adopt it
        // instead of starting a duplicate open: its completion sees
        // _currentOpenPath == its path and delivers into finishPlayOnQueue:
        // (see prefetchOnQueue:). The timeout and slow-open indicator below
        // arm exactly as for an owned open; only the worker is shared. The
        // claim is consumed so the completion can't also park the handle.
        _prefetchRequestId++;
        _prefetchedPath = nil;
    }
    else {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            AVAudioFile *file = [[AVAudioFile alloc] initForReading:track.url error:&error];
            AudioPlayer *strongSelf = weakSelf;
            if (strongSelf) {
                dispatch_async(strongSelf->_queue, ^{
                    [strongSelf finishPlayOnQueue:track file:file error:error openRequestId:openId];
                });
            }
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFileOpenTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        [weakSelf fileOpenTimedOut:track openRequestId:openId];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSlowOpenIndicatorDelaySeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf && openId == strongSelf->_openRequestId) {
            // Still waiting on the open — let the UI show a loading state.
            run_on_main_thread({
                [strongSelf.delegate audioPlayer:strongSelf didBeginLoading:track];
            });
        }
    });
}

- (void)finishPlayOnQueue:(AudioTrack *)track file:(AVAudioFile *)file error:(NSError *)error openRequestId:(uint64_t)openId {
    if (openId != _openRequestId) {
        return; // Superseded by a newer play, or already timed out.
    }
    _openRequestId++; // Consume: the pending timeout must no-op.
    _currentOpenPath = nil; // This open resolved; the track is no longer loading.
    // Deliver the track object the playlist currently knows — a same-path
    // replay (re-drop) may have rebound it since this open was dispatched.
    if (_pendingOpenTrack) {
        track = _pendingOpenTrack;
    }
    _pendingOpenTrack = nil;

    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error)];
        return;
    }

    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:node];
    if (![self connectNode:node throughVarispeedWithFormat:file.processingFormat]) {
        [self detachNodeAfterFailedConnect:node];
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not play %@ (unsupported format)", track.url.lastPathComponent], nil)];
        return;
    }

    [self scheduleFile:file onNode:node fromFrame:0];
    node.volume = 0; // fade in from silence (see the ramp below)

    NSError *startError = nil;
    if (![self startEngineAndPlayNode:node error:&startError]) {
        _generation++; // drop the scheduled segment's stop-fired completion
        [node stop];
        [_engine detachNode:node];
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                @"Could not start audio engine", startError)];
        return;
    }

    [self publishPlaybackState:VibePlayerStatePlaying node:node file:file segmentStart:0 position:0];

    // Fade the new track in from silence: its first frame is rarely a zero
    // crossing, so starting at full volume clicks (the same reason the seek
    // fades in). Uses the CURRENT ramp generation — not a fresh one — so it
    // rises in step with the outgoing track's fade-out (a real crossfade) and
    // neither ramp cancels the other.
    [self rampNodeAsync:node step:1 from:0 to:1.0 generation:_rampGeneration completion:nil];

    self.currentTrack = track;
    track.duration = self.duration;
    run_on_main_thread({
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

// Wires node -> varispeed -> mixer for a track's format (runs on _queue).
// _varispeed is freshly created for each track (playOnQueue:) and connected
// exactly once here, so — unlike the old shared varispeed — it never has to
// reinitialize across a channel-count change (stereo -> mono), which used to
// throw kAudioUnitErr_FormatNotSupported and force an engine stop on every
// mono<->stereo transition. The catch is the backstop for whatever formats the
// graph still refuses — a failed connect must report, not crash. Position math
// is unaffected by the rate: playerTimeForNodeTime: counts file frames the
// player node rendered, and varispeed just consumes them faster or slower.
- (BOOL)connectNode:(AVAudioPlayerNode *)node throughVarispeedWithFormat:(AVAudioFormat *)format {
    @try {
        [_engine connect:node to:_varispeed format:format];
        [_engine connect:_varispeed to:_engine.mainMixerNode format:format];
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: engine connect failed for format %@: %@", format, exception);
        return NO;
    }
    os_unfair_lock_lock(&_stateLock);
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    _varispeed.rate = 1.0f + pitch / 100.0f;
    return YES;
}

// Detach that cannot throw: after a failed connect the node can be in a state
// AVAudioEngine's RemoveNode refuses (it raises an NSException; leaking the
// node is better than crashing the app on an already-failing path).
- (void)detachNodeAfterFailedConnect:(AVAudioPlayerNode *)node {
    @try {
        [_engine detachNode:node];
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: detach after failed connect: %@", exception);
    }
}

// Schedules the remainder of the file from startFrame with a completion tagged
// by the current generation. AVAudioPlayerNode fires completions on stop and
// reschedule too, not just natural end — every interruption (skip, seek,
// device switch, new play) bumps _generation first so those get dropped.
- (void)scheduleFile:(AVAudioFile *)file onNode:(AVAudioPlayerNode *)node fromFrame:(AVAudioFramePosition)startFrame {
    uint64_t gen = _generation;
    AVAudioFrameCount frames = (AVAudioFrameCount)MAX(file.length - startFrame, 1);
    __weak AudioPlayer *weakSelf = self;
    [node scheduleSegment:file
            startingFrame:startFrame
               frameCount:frames
                   atTime:nil
   completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
        completionHandler:^(AVAudioPlayerNodeCompletionCallbackType callbackType) {
            AudioPlayer *strongSelf = weakSelf;
            if (strongSelf) {
                dispatch_async(strongSelf->_queue, ^{
                    [strongSelf segmentDidCompleteWithGeneration:gen];
                });
            }
        }];
}

- (void)fileOpenTimedOut:(AudioTrack *)track openRequestId:(uint64_t)openId {
    if (openId != _openRequestId) {
        return; // The open landed in time, or a newer play superseded it.
    }
    _openRequestId++; // Invalidate the still-blocked open.
    // Clear so the file is retryable: a later play of it starts a fresh open.
    // The original worker may stay blocked on a truly-hung mount (one leaked
    // worker), but rapid re-clicks were already absorbed by the loading no-op.
    _currentOpenPath = nil;
    if (_pendingOpenTrack) {
        track = _pendingOpenTrack; // report against the rebound (current) object
    }
    _pendingOpenTrack = nil;
    LogError(@"Timed out opening %@", track.url.path);
    [self resetToStoppedStateOnQueue];
    [self sendDelegateError:VibeAudioError(VibeAudioErrorFileOpenTimedOut,
            [NSString stringWithFormat:@"Timed out opening %@ — it may still be downloading from iCloud/Dropbox or the network may be unavailable",
                                       track.url.lastPathComponent], nil)];
}

- (void)prefetchTrack:(AudioTrack *)track {
    dispatch_async(_queue, ^{
        [self prefetchOnQueue:track];
    });
}

// Runs on _queue. Opens the file on a background queue and parks the handle
// for playOnQueue: to consume. Utility QoS: readahead for a track that won't
// be needed for minutes, not user-blocking work. A blocked open (cloud
// placeholder) strands one worker — the same accepted tradeoff as the
// playback open — and usefully starts the download before the track is due.
- (void)prefetchOnQueue:(AudioTrack *)track {
    NSString *path = track.url.path;
    if (path && [path isEqualToString:_prefetchedPath]) {
        return; // already prefetched, or that open is still in flight
    }
    if (path && [path isEqualToString:_currentOpenPath]) {
        return; // being opened for playback right now
    }
    _prefetchRequestId++; // supersede any in-flight prefetch open
    // Claimed at request time (not completion) so repeated prefetches of the
    // same path don't stack opens; _prefetchedFile stays nil until it lands.
    _prefetchedPath = path;
    _prefetchedFile = nil;
    if (!path) {
        return; // nil track: end of playlist — just drop the parked handle
    }
    uint64_t prefetchId = _prefetchRequestId;
    __weak AudioPlayer *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:track.url error:&error];
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        dispatch_async(strongSelf->_queue, ^{
            if (strongSelf->_currentOpenPath && [path isEqualToString:strongSelf->_currentOpenPath]) {
                // A play of this path is waiting on its open — the adoption
                // case (playOnQueue: consumed the claim), or a later replay
                // racing this straggler with its own worker. Deliver here:
                // finishPlayOnQueue: consumes the open id, so whichever
                // worker lands second no-ops. finishPlayOnQueue: rebinds to
                // _pendingOpenTrack, so the play's track object wins.
                [strongSelf finishPlayOnQueue:track file:file error:error
                                openRequestId:strongSelf->_openRequestId];
                return;
            }
            if (prefetchId != strongSelf->_prefetchRequestId) {
                return; // a newer prefetch target (or an adoption) superseded this open
            }
            if (file && file.length > 0) {
                strongSelf->_prefetchedFile = file;
            }
            else {
                // Open failed — release the claim so a play of this track
                // runs its own open and reports the error the normal way.
                strongSelf->_prefetchedPath = nil;
            }
        });
    });
}

// Marks playback fully stopped after a failure so isPlaying/duration report
// reality and the play button can recover.
- (void)resetToStoppedStateOnQueue {
    // Invalidate any in-flight open: after an unrelated failure resets to
    // Stopped (e.g. a device switch failing mid-Loading), a still-pending open
    // must not land later and start playback out of an errored/stopped UI.
    // Harmless when the caller already consumed the id (extra bump).
    _openRequestId++;
    _currentOpenPath = nil;
    _pendingOpenTrack = nil;
    [self publishPlaybackState:VibePlayerStateStopped node:nil file:nil segmentStart:0 position:0];
    // Release the output device once genuinely idle; a quick follow-up play
    // (auto-advance past a bad file) reuses the running engine.
    [self scheduleEngineIdleStopOnQueue];
}

// Runs on _queue. Stops the engine after a grace period if playback is still
// Stopped, releasing the output device. Any (re)start of playback in the
// interim — startEngineAndPlayNode: is the single funnel — bumps the
// generation and the pending stop dissolves.
- (void)scheduleEngineIdleStopOnQueue {
    uint64_t generation = ++_engineIdleStopGeneration;
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEngineIdleStopDelaySeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_engineIdleStopGeneration) {
            return;
        }
        os_unfair_lock_lock(&strongSelf->_stateLock);
        VibePlayerState state = strongSelf->_state;
        os_unfair_lock_unlock(&strongSelf->_stateLock);
        // Only a still-Stopped player stops the engine. Loading counts as
        // busy — the in-flight open's finish path wants the engine warm.
        if (state == VibePlayerStateStopped) {
            [strongSelf->_engine stop];
        }
    });
}

// [AVAudioPlayerNode play] throws NSException if the engine stopped between
// our isRunning check and the call — and the engine stops itself on device
// and format changes. Start the engine if needed and absorb the race.
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    _engineIdleStopGeneration++; // playback is (re)starting — cancel any pending idle stop
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!_engine.isRunning) {
            NSError *startError = nil;
            if (![_engine startAndReturnError:&startError]) {
                if (outError) {
                    *outError = startError;
                }
                return NO;
            }
        }
        @try {
            [node play];
            return YES;
        }
        @catch (NSException *exception) {
            LogError(@"AudioPlayer: node play threw (%@); retrying", exception.reason);
        }
    }
    return NO;
}

- (void)segmentDidCompleteWithGeneration:(uint64_t)generation {
    if (generation != _generation) {
        return; // Stale: a stop/seek/skip/device switch superseded this segment.
    }
    [self finishPlaybackOnQueue];
}

// Shared terminus for "the current track is done" — the natural segment
// completion above and an explicit -finishCurrentTrack both land here (on
// _queue). Marks the player Stopped, tears the finished node down, and notifies
// the delegate, whose handler drives auto-advance / end-of-playlist stop. The
// engine stop is deferred so the auto-advance play (arriving within
// milliseconds via didFinishPlaying → next) reuses the running engine instead
// of paying an output-unit stop+start per consecutive-track transition.
- (void)finishPlaybackOnQueue {
    os_unfair_lock_lock(&_stateLock);
    _state = VibePlayerStateStopped;
    AVAudioPlayerNode *finishedNode = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    if (finishedNode) {
        [finishedNode stop];
        [_engine detachNode:finishedNode];
    }
    [self scheduleEngineIdleStopOnQueue];
    // Snapshot before dispatching; if the track changed by the time the block
    // runs on main, this end event is stale and must be dropped.
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        if (!track || self.currentTrack != track) {
            return;
        }
        [self.delegate audioPlayer:self didFinishPlaying:track];
    });
}

- (void)finishCurrentTrack {
    dispatch_async(_queue, ^{
        os_unfair_lock_lock(&self->_stateLock);
        VibePlayerState state = self->_state;
        os_unfair_lock_unlock(&self->_stateLock);
        // Only a live track can finish. Stopped has nothing to do; Loading has
        // no node yet (and the skip path never gets here while loading — its
        // duration is 0), so treat it as a no-op too.
        if (state != VibePlayerStatePlaying && state != VibePlayerStatePaused) {
            return;
        }
        // [node stop] inside finishPlaybackOnQueue fires the scheduled
        // completion; bump _generation so segmentDidCompleteWithGeneration:
        // drops it, and _rampGeneration to preempt any in-flight fade — the
        // same interruption dance seek/skip/device-switch use.
        self->_generation++;
        self->_rampGeneration++;
        [self finishPlaybackOnQueue];
    });
}

- (void)playPause {
    dispatch_async(_queue, ^{
        if (self->_state == VibePlayerStateLoading) {
            // A play is committed and its file open is in flight; the toggle
            // has nothing coherent to act on yet. Ignore silently.
            return;
        }
        AVAudioPlayerNode *node = self->_node;
        if (!node) {
            [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
            return;
        }
        if (self->_state == VibePlayerStatePlaying) {
            if (self->_pausePending) {
                // Second press during the pause fade-out: cancel the pending
                // pause and ramp back up. No delegate event — didPause never
                // fired, so the UI never left the playing state.
                self->_pausePending = NO;
                uint64_t rampGen = ++self->_rampGeneration;
                [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
                return;
            }
            uint64_t rampGen = ++self->_rampGeneration; // cancel any in-flight resume fade-in
            // Fade out asynchronously (the queue must not block ~25ms — a
            // skip or seek issued right behind a pause used to stall on the
            // old synchronous ramp), then pause in the completion. State stays
            // Playing through the fade: the node really is still rendering.
            self->_pausePending = YES;
            __weak AudioPlayer *weakSelf = self;
            [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
                AudioPlayer *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                // Runs on _queue, and runs in every case (preemption included),
                // so the pending flag can be cleared unconditionally.
                strongSelf->_pausePending = NO;
                // A preempted ramp still reaches this completion (see
                // rampNodeAsync:), so the node/state checks alone aren't
                // enough: the cancel-pause ramp-up and a seek's own fade both
                // bump _rampGeneration but leave node and state untouched, and
                // pausing under them would fight the operation that now owns
                // volume and state.
                if (rampGen != strongSelf->_rampGeneration
                        || strongSelf->_node != node || strongSelf->_state != VibePlayerStatePlaying) {
                    return; // A play/stop/seek/device switch superseded the pause.
                }
                [strongSelf completePauseOfNode:node];
            }];
        }
        else if (self->_state == VibePlayerStatePaused) {
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not resume playback", startError)];
                return;
            }
            os_unfair_lock_lock(&self->_stateLock);
            self->_state = VibePlayerStatePlaying;
            os_unfair_lock_unlock(&self->_stateLock);
            uint64_t rampGen = ++self->_rampGeneration;
            [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
            AudioTrack *track = self.currentTrack;
            run_on_main_thread({
                [self.delegate audioPlayer:self didResumePlaying:track];
            });
        }
        else {
            [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
        }
    });
}

// Runs on _queue. Captures the position (after any fade — the node keeps
// rendering through the ramp — but BEFORE [node pause]; once paused,
// playerTimeForNodeTime: stops reporting), pauses the node, and publishes
// the Paused state.
- (void)completePauseOfNode:(AVAudioPlayerNode *)node {
    NSTimeInterval position = self.position;
    [node pause];
    [self publishPlaybackState:VibePlayerStatePaused node:node file:_file segmentStart:_segmentStartFrame position:position];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

#pragma mark - Fades

// The one fade-stepping loop, non-blocking via dispatch_after on the player
// queue — both ramp flavors below are thin entries into it, so a cadence or
// curve change (kFadeSteps, kFadeStepMicroseconds, VibeFadeVolume) lands
// everywhere at once. A preemptable ramp stops stepping the volume once
// _rampGeneration moves past its generation — but still runs its completion
// so completion-side bookkeeping (the pause fade's _pausePending clear, the
// seek's reschedule/didFinishSeeking settle) isn't lost; those completions
// re-check the generation themselves and yield to the preemptor.
- (void)stepRampAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target preemptable:(BOOL)preemptable generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    if (preemptable && generation != _rampGeneration) {
        if (completion) {
            completion();
        }
        return;
    }
    node.volume = VibeFadeVolume(start, target, step);
    if (step >= kFadeSteps) {
        if (completion) {
            completion();
        }
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFadeStepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepRampAsync:node step:step + 1 from:start to:target preemptable:preemptable generation:generation completion:completion];
    });
}

// Generation-tagged fade for the CURRENT node: preempted when a
// pause/seek/skip/device-switch/new-play bumps _rampGeneration.
- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    [self stepRampAsync:node step:step from:start to:target preemptable:YES generation:generation completion:completion];
}

// Fade-to-silence for a RETIRED node (the crossfade's outgoing side).
// Deliberately NOT preemptable: once playOnQueue: retires a node nothing
// re-targets it — the only remaining reference is this fade's completion — so
// no later operation needs to preempt it, and preemption would hard-stop the
// node at mid-fade volume (an audible click on rapid skips). Always reaches
// silence, then runs the completion (stop+detach) exactly once.
- (void)rampRetiredNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start completion:(dispatch_block_t)completion {
    [self stepRampAsync:node step:step from:start to:0 preemptable:NO generation:0 completion:completion];
}

#pragma mark - Properties

- (BOOL)isPlaying {
    os_unfair_lock_lock(&_stateLock);
    // Loading counts as playing: a play is committed and imminent, so the UI
    // holds the pause icon rather than flashing the play icon during the open.
    BOOL playing = (_state == VibePlayerStatePlaying || _state == VibePlayerStateLoading);
    os_unfair_lock_unlock(&_stateLock);
    return playing;
}

- (BOOL)isPaused {
    os_unfair_lock_lock(&_stateLock);
    BOOL paused = (_state == VibePlayerStatePaused);
    os_unfair_lock_unlock(&_stateLock);
    return paused;
}

- (BOOL)isStopped {
    os_unfair_lock_lock(&_stateLock);
    BOOL stopped = (_state == VibePlayerStateStopped);
    os_unfair_lock_unlock(&_stateLock);
    return stopped;
}

- (NSTimeInterval)duration {
    os_unfair_lock_lock(&_stateLock);
    AVAudioFile *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    double sampleRate = file.processingFormat.sampleRate;
    if (!file || sampleRate <= 0) {
        return 0;
    }
    return (NSTimeInterval)file.length / sampleRate;
}

- (NSUInteger)numChannels {
    os_unfair_lock_lock(&_stateLock);
    AVAudioFile *file = _file;
    os_unfair_lock_unlock(&_stateLock);
    return file.processingFormat.channelCount;
}

- (NSTimeInterval)position {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    AVAudioPlayerNode *node = _node;
    AVAudioFile *file = _file;
    AVAudioFramePosition segmentStartFrame = _segmentStartFrame;
    NSTimeInterval pausedPosition = _pausedPosition;
    NSTimeInterval lastValidPosition = _lastValidPosition;
    uint64_t positionEpoch = _positionEpoch;
    os_unfair_lock_unlock(&_stateLock);

    if (!file || state == VibePlayerStateStopped) {
        return 0;
    }
    double sampleRate = file.processingFormat.sampleRate;
    if (sampleRate <= 0) {
        return 0;
    }
    if (state == VibePlayerStatePaused || !node) {
        return pausedPosition;
    }
    // playerTime restarts at 0 after every stop+reschedule, so the segment's
    // start frame must always be added back.
    AVAudioTime *playerTime = nil;
    @try {
        // The queue can detach this node concurrently (fast skips — this
        // getter is deliberately lock-free), and a detached node's
        // lastRenderTime RAISES (_engine != nil) instead of returning nil.
        // Treat it as "no reading": the fallback below serves the last valid
        // position, and the next tick reads the replacement node.
        AVAudioTime *nodeTime = node.lastRenderTime;
        playerTime = nodeTime ? [node playerTimeForNodeTime:nodeTime] : nil;
    }
    @catch (NSException *exception) {
        playerTime = nil;
    }
    NSTimeInterval position;
    if (!playerTime || !playerTime.sampleTimeValid) {
        // No render yet (right after play), OR the engine stopped itself
        // (device unplug/format change — lastRenderTime is nil while stopped).
        // The last valid reading is never behind the segment start within one
        // segment, so MAX covers both cases.
        position = MAX((NSTimeInterval)segmentStartFrame / sampleRate, lastValidPosition);
    }
    else {
        position = (NSTimeInterval)(segmentStartFrame + playerTime.sampleTime) / sampleRate;
    }
    NSTimeInterval duration = (NSTimeInterval)file.length / sampleRate;
    position = MIN(MAX(position, 0), duration);
    if (playerTime && playerTime.sampleTimeValid) {
        os_unfair_lock_lock(&_stateLock);
        // A seek/pause/track change may have rewritten the position state
        // while this was computed off-lock; storing then would resurrect the
        // pre-seek position. The stale reading is also not returned upward —
        // the epoch writer's value is the truth now.
        if (_positionEpoch == positionEpoch) {
            _lastValidPosition = position;
        }
        else {
            position = _lastValidPosition;
        }
        os_unfair_lock_unlock(&_stateLock);
    }
    return position;
}

- (void)setPosition:(NSTimeInterval)pos {
    dispatch_async(_queue, ^{
        AudioTrack *track = self.currentTrack;
        AVAudioPlayerNode *node = self->_node;
        AVAudioFile *file = self->_file;
        if (!node || !file) {
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }
        double sampleRate = file.processingFormat.sampleRate;
        BOOL wasPlaying = (self->_state == VibePlayerStatePlaying);
        AVAudioFramePosition startFrame = (AVAudioFramePosition)(pos * sampleRate);
        startFrame = MAX(0, MIN(startFrame, file.length - 1));
        NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;
        self->_generation++; // drop the current segment's stop-fired completion

        if (!wasPlaying) {
            // Paused: reschedule the existing (silent) node in place — no audio
            // is rendering, so there is nothing to declick, and the next resume
            // fades in from the seeked frame. The faded volume is kept; resume
            // ramps it back up.
            self->_rampGeneration++; // preempt any in-flight fade
            [node stop];
            [self scheduleFile:file onNode:node fromFrame:startFrame];
            [self publishPlaybackState:self->_state node:node file:file segmentStart:startFrame position:framePosition];
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }

        // Playing: declick without touching the audio graph. Reconnecting a
        // live node (the two-node crossfade's reroute) is itself a click on a
        // running engine, so instead fade THIS node down, reschedule it in
        // place, and fade it back up — both the [node stop] and the new
        // segment's start then land at silence. The reschedule is deferred into
        // the fade-out completion (the node must stay audible through the ramp);
        // the position state is rewritten there so the getter follows the node.
        uint64_t rampGen = ++self->_rampGeneration;
        __weak AudioPlayer *weakSelf = self;
        [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
            AudioPlayer *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (strongSelf->_node != node) {
                // A new play/track-change/stop/device-switch replaced the node
                // while this faded — that operation owns playback and this
                // seek's target is moot. The seek is dropped, but the request
                // still settles the UI: the header promises didFinishSeeking:
                // for every seek request (Control Center resyncs off it).
                run_on_main_thread({
                    [strongSelf.delegate audioPlayer:strongSelf didFinishSeeking:track];
                });
                return;
            }
            // Same node, but a pause (or its cancel, or a newer seek) bumped
            // the ramp generation mid-fade: the reschedule below still lands —
            // the user asked for this position — but the preemptor owns volume
            // and _state, so neither is touched on this path.
            BOOL preempted = (rampGen != strongSelf->_rampGeneration);
            // [node stop] fires the completion of whatever segment is
            // scheduled RIGHT NOW — which, after a preempted seek's own
            // reschedule, can carry the current generation, not the one this
            // seek's entry bump retired. Re-bump immediately before the stop
            // or that completion reads as current and "finishes" the track.
            strongSelf->_generation++;
            [node stop];
            [strongSelf scheduleFile:file onNode:node fromFrame:startFrame];
            if (preempted) {
                [strongSelf publishPlaybackState:strongSelf->_state node:node file:file segmentStart:startFrame position:framePosition];
                BOOL stillPlaying = (strongSelf->_state == VibePlayerStatePlaying);
                if (stillPlaying) {
                    // Mid-pause-fade the state is still Playing (the pause
                    // completion hasn't landed, and won't if it gets
                    // cancelled): restart the node so a cancelled pause isn't
                    // left with a stopped node behind a Playing state. Volume
                    // stays wherever the preemptor's ramp has it — that ramp
                    // keeps stepping, and a completing pause finds the node
                    // where completePauseOfNode: expects it.
                    [strongSelf startEngineAndPlayNode:node error:NULL];
                }
                run_on_main_thread({
                    [strongSelf.delegate audioPlayer:strongSelf didFinishSeeking:track];
                });
                return;
            }
            node.volume = 0; // ramp back up from silence
            NSError *startError = nil;
            if (![strongSelf startEngineAndPlayNode:node error:&startError]) {
                strongSelf->_generation++; // drop the stop-fired completion
                // Keep the seeked frame; report paused so the UI recovers.
                [strongSelf publishPlaybackState:VibePlayerStatePaused node:node file:file segmentStart:startFrame position:framePosition];
                [strongSelf sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not resume playback after seek", startError)];
                run_on_main_thread({
                    [strongSelf.delegate audioPlayer:strongSelf didFinishSeeking:track];
                });
                return;
            }
            [strongSelf publishPlaybackState:strongSelf->_state node:node file:file segmentStart:startFrame position:framePosition];
            uint64_t fadeInGen = ++strongSelf->_rampGeneration;
            [strongSelf rampNodeAsync:node step:1 from:0 to:1.0 generation:fadeInGen completion:nil];
            run_on_main_thread({
                [strongSelf.delegate audioPlayer:strongSelf didFinishSeeking:track];
            });
        }];
    });
}

#pragma mark - Pitch

- (float)pitch {
    os_unfair_lock_lock(&_stateLock);
    float pitch = _pitch;
    os_unfair_lock_unlock(&_stateLock);
    return pitch;
}

- (void)setPitch:(float)pitch {
    os_unfair_lock_lock(&_stateLock);
    pitch = MAX(-_maxPitch, MIN(_maxPitch, pitch));
    _pitch = pitch;
    os_unfair_lock_unlock(&_stateLock);
    // The rate is an AU parameter, but touch the node only on the engine's
    // owning queue like every other graph mutation.
    dispatch_async(_queue, ^{
        self->_varispeed.rate = 1.0f + pitch / 100.0f;
    });
}

- (float)maxPitch {
    os_unfair_lock_lock(&_stateLock);
    float maxPitch = _maxPitch;
    os_unfair_lock_unlock(&_stateLock);
    return maxPitch;
}

- (void)setMaxPitch:(float)maxPitch {
    os_unfair_lock_lock(&_stateLock);
    _maxPitch = maxPitch;
    float pitch = MAX(-maxPitch, MIN(maxPitch, _pitch));
    _pitch = pitch;
    os_unfair_lock_unlock(&_stateLock);
    // Re-apply in case the narrower range clamped the current pitch.
    dispatch_async(_queue, ^{
        self->_varispeed.rate = 1.0f + pitch / 100.0f;
    });
}

#pragma mark - Output devices

- (void)systemDefaultOutputDeviceDidChange {
    if (self.currentlyRequestedAudioDeviceId == -1) {
        [self setOutputDevice:self.currentlyRequestedAudioDeviceId];
    }
}

// Covers the explicitly chosen device disappearing while playback is idle —
// handleEngineConfigurationChange only sees removals that kill the running
// graph. setOutputDevice:-1 rebinds and the delegate persists the fallback,
// so System Output stays the choice even after the device returns.
- (void)audioOutputDevicesDidChange {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (requested >= 0 && ![[AudioDeviceManager sharedInstance] outputDeviceForId:requested]) {
        LogInfo(@"AudioPlayer: requested output device removed; falling back to system default");
        [self setOutputDevice:-1];
    }
}

// The AudioDeviceID the output unit is currently bound to.
- (AudioDeviceID)activeOutputDeviceID {
    AudioUnit outputUnit = _engine.outputNode.audioUnit;
    if (outputUnit) {
        AudioDeviceID deviceID = kAudioObjectUnknown;
        UInt32 size = sizeof(deviceID);
        if (AudioUnitGetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, &size) == noErr && deviceID != kAudioObjectUnknown) {
            return deviceID;
        }
    }
    return [CoreAudioUtil systemDefaultOutputDeviceID];
}

- (NSInteger)currentlyActiveAudioDeviceId {
    return (NSInteger)[self activeOutputDeviceID];
}

- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID {
    AudioUnit outputUnit = _engine.outputNode.audioUnit;
    if (!outputUnit) {
        LogError(@"AudioPlayer: output unit unavailable");
        return NO;
    }
    OSStatus status = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
    if (status != noErr) {
        LogError(@"AudioPlayer: could not set output device %u (OSStatus %d)", deviceID, (int)status);
        return NO;
    }
    return YES;
}

- (void)setOutputDevice:(NSInteger)outputDeviceID {
    dispatch_async(_queue, ^{

        LogDebug(@"setOutputDevice: %@", @(outputDeviceID));

        AudioDeviceID newDeviceID = kAudioObjectUnknown;
        if (outputDeviceID >= 0) {
            newDeviceID = (AudioDeviceID)outputDeviceID;
        }
        else {
            newDeviceID = [CoreAudioUtil systemDefaultOutputDeviceID];
        }

        if (newDeviceID == kAudioObjectUnknown) {
            LogError(@"Unable to resolve output device %@", @(outputDeviceID));
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"Audio output device is unavailable", nil)];
            return;
        }

        AudioDeviceID currentDeviceID = [self activeOutputDeviceID];

        LogDebug(@"current: %@ new: %@", @(currentDeviceID), @(newDeviceID));

        if (newDeviceID != currentDeviceID) {
            if (![self configureOutputDeviceOnQueue:newDeviceID]) {
                // configureOutputDeviceOnQueue already reported the error;
                // don't record or persist a device we failed to switch to.
                return;
            }
        }

        self.currentlyRequestedAudioDeviceId = outputDeviceID;

        run_on_main_thread({
            [self.delegate audioPlayer:self didChangeOutputDevice:self.currentlyRequestedAudioDeviceId];
        });

    });
}

// Rebinds the engine to a new output device, restoring the current track,
// position, and play/pause state — the replacement for the old free/reinit
// device dance. Returns NO (after reporting a delegate error) on failure.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID {
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState priorState = _state;
    os_unfair_lock_unlock(&_stateLock);
    AudioTrack *trackToRestore = self.currentTrack;
    NSTimeInterval positionToRestore = self.position;
    // Only a live track is restored onto the new device. A finished (Stopped)
    // track still carries currentTrack/_file, so rescheduling it from the saved
    // frame would resurrect it as Paused; a Loading track's open is in flight
    // and will start itself on the new device. Both leave state untouched here.
    BOOL shouldRestore = (priorState == VibePlayerStatePlaying || priorState == VibePlayerStatePaused) && trackToRestore != nil;
    BOOL wasPlaying = (priorState == VibePlayerStatePlaying);

    _generation++;
    _rampGeneration++; // preempt any in-flight fade

    // Unpublish the node BEFORE detaching it: the position getter reads _node
    // lock-free on the main thread, and calling into a detached node raises.
    os_unfair_lock_lock(&_stateLock);
    AVAudioPlayerNode *oldNode = _node;
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    [oldNode stop];
    [_engine stop];
    if (oldNode) {
        [_engine detachNode:oldNode];
    }

    if (![self setOutputUnitDevice:deviceID]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                @"Could not switch audio output device", nil)];
        return NO;
    }

    if (shouldRestore) {
        // Reuse the already-open handle rather than reopening the URL. The old
        // reopen was a synchronous, timeout-free initForReading: on the player
        // queue — a track evicted to an iCloud/Dropbox placeholder (or on a hung
        // mount) between play and the device switch would wedge the whole queue.
        // processingFormat is fixed at open, so rescheduling the existing file
        // on the new node is safe (and the reopen was redundant work anyway).
        AVAudioFile *file = _file; // on _queue; _file is mutated only here
        if (!file) {
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorFileOpenFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:node];
        if (![self connectNode:node throughVarispeedWithFormat:file.processingFormat]) {
            [self detachNodeAfterFailedConnect:node];
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                    @"Could not restore track on the new audio device", nil)];
            return NO;
        }
        double sampleRate = file.processingFormat.sampleRate;
        AVAudioFramePosition startFrame = (AVAudioFramePosition)(positionToRestore * sampleRate);
        startFrame = MAX(0, MIN(startFrame, file.length - 1));
        [self scheduleFile:file onNode:node fromFrame:startFrame];
        // Preserve the pause-fade invariant: a Paused track sits at volume 0
        // so the next resume ramps it back up (see setPosition:). Restoring
        // at 1.0 would make that resume start instantly at full volume
        // mid-waveform — the click the 25ms ramp exists to prevent.
        node.volume = wasPlaying ? 1.0 : 0;
        [self publishPlaybackState:(wasPlaying ? VibePlayerStatePlaying : VibePlayerStatePaused)
                              node:node file:file segmentStart:startFrame position:positionToRestore];
        if (wasPlaying) {
            NSError *startError = nil;
            if (![self startEngineAndPlayNode:node error:&startError]) {
                _generation++;
                [node stop];
                [_engine detachNode:node];
                [self resetToStoppedStateOnQueue];
                [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                        @"Could not restart playback on the new audio device", startError)];
                return NO;
            }
        }
    }

    return YES;
}

// AVAudioEngineConfigurationChangeNotification — the output hardware changed
// under the engine (device removed, format/sample-rate change), which makes
// the engine stop itself. Replacement for
// BASS_SYNC_DEV_FAIL / BASS_SYNC_DEV_FORMAT. Idempotent health check: only
// rebuild when the graph actually died, so notifications caused by our own
// completed rebuilds are no-ops instead of redundant rebuilds.
- (void)handleEngineConfigurationChange {
    NSInteger requested = self.currentlyRequestedAudioDeviceId;
    if (requested >= 0) {
        AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForId:requested];
        if (!device) {
            LogError(@"Audio output device failed; falling back to system default");
            [self setOutputDevice:-1];
            return;
        }
    }
    os_unfair_lock_lock(&_stateLock);
    VibePlayerState state = _state;
    BOOL hasNode = (_node != nil);
    os_unfair_lock_unlock(&_stateLock);
    if (state == VibePlayerStateStopped) {
        return;
    }
    if (_engine.isRunning && hasNode) {
        // Graph survived — nothing to recover.
        return;
    }
    // The engine stopped itself in response to the change. Rebuild the graph,
    // preserving track/position/play-pause state.
    AudioDeviceID deviceID = requested >= 0
            ? (AudioDeviceID)requested
            : [CoreAudioUtil systemDefaultOutputDeviceID];
    if (deviceID == kAudioObjectUnknown) {
        // No output device exists at all (the last one vanished). A dead
        // engine must not sit behind a Playing state — the UI would show
        // playing with a frozen position and no explanation — so park as
        // Paused at the last valid position and say why. Paused (not Stopped)
        // keeps the track restorable: when a device appears, the default-
        // device change fires setOutputDevice:-1 and configureOutputDevice…
        // rebuilds the graph with the track parked at this position, ready
        // to resume. Paused/Loading need no parking — their next start
        // attempt (resume, or the open's finish) reports its own failure.
        if (state == VibePlayerStatePlaying) {
            NSTimeInterval position = self.position; // engine dead: serves the last valid reading
            [self publishPlaybackState:VibePlayerStatePaused node:_node file:_file
                          segmentStart:_segmentStartFrame position:position];
            AudioTrack *track = self.currentTrack;
            run_on_main_thread({
                [self.delegate audioPlayer:self didPausePlaying:track];
            });
            [self sendDelegateError:VibeAudioError(VibeAudioErrorDeviceUnavailable,
                    @"No audio output device is available", nil)];
        }
        return;
    }
    [self configureOutputDeviceOnQueue:deviceID];
}

#pragma mark - Helpers

// The single writer for the lock-guarded playback/position state (runs on
// _queue). Everything is published in ONE lock acquisition so the main-thread
// getters never observe a torn combination (a new state with the old track's
// position). The epoch bump is structural: the position getter computes
// off-lock and only writes _lastValidPosition back if the epoch it snapshotted
// is still current, so a write site that skipped the bump would let a stale
// reading clobber this publish (see _positionEpoch). Callers whose operation
// leaves a field untouched pass the current value through.
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(AVAudioPlayerNode *)node
                        file:(AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position {
    os_unfair_lock_lock(&_stateLock);
    _node = node;
    _file = file;
    _segmentStartFrame = segmentStart;
    _pausedPosition = position;
    _lastValidPosition = position;
    _positionEpoch++;
    _state = state;
    os_unfair_lock_unlock(&_stateLock);
}

- (void)sendDelegateError:(NSError *)error {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

@end
