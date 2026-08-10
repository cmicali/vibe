//
//  AudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "AudioPlayerInternal.h"
#import "AudioPlayer+Devices.h"
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioDeviceManager.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import "VibeFadeCurve.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

// VibePlayerState lives in AudioPlayerInternal.h, shared with
// AudioPlayer+Devices.m alongside the class extension and this function's
// declaration.

NSString *const kVibeAudioErrorDomain = @"com.commonwealthrecordings.Vibe";
NSString *const kVibeAudioErrorTrackURLKey = @"VibeAudioErrorTrackURL";

// Not static, because AudioPlayer+Devices.m uses it too; AudioPlayerInternal.h
// declares it. Descriptions are NOT localized: every consumer is a log site —
// the UI status comes from +[MainPlayerController statusForPlayError:], which
// maps the error code and localizes there.
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying) {
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

// Play-path variant: stamps the failing track's URL so the delegate can drop
// a delivery a track change has outrun (see kVibeAudioErrorTrackURLKey).
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError *underlying, NSURL *trackURL) {
    NSError *error = VibeAudioError(code, description, underlying);
    if (!trackURL) {
        return error;
    }
    NSMutableDictionary *info = [error.userInfo mutableCopy];
    info[kVibeAudioErrorTrackURLKey] = trackURL;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

// How long a file open may block, since cloud placeholders download on
// demand, before the play request is abandoned with an error.
static const NSTimeInterval kFileOpenTimeoutSeconds = 20.0;

// An open still pending after this long is worth a visible loading state.
static const NSTimeInterval kSlowOpenIndicatorDelaySeconds = 0.5;

// How long the engine may sit idle, in the Stopped state, before it is
// stopped to release the output device. It is deferred rather than immediate
// because a natural track end is followed within milliseconds by the
// auto-advance's play, and an immediate stop made every consecutive-track
// transition pay an output-unit stop and start of 10-50ms, worse on
// Bluetooth. The delay is long enough to absorb even a slow next-track open,
// and short enough to release the device promptly when playback really ends.
static const NSTimeInterval kEngineIdleStopDelaySeconds = 2.0;

// Default pitch fader range in percent: ±8%, matching a stock SL-1200.
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so dealloc can tell whether it is
// already running on the queue, as it is when a queued block drops the last
// reference. dispatch_sync onto the current queue deadlocks.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

// AudioPlayer+Devices.h declares the AudioDeviceManagerObserver conformance on
// the (Devices) category, which implements the observer callbacks.

// A retired node/varispeed pair whose crossfade-length fade-out is in flight.
// Queue-confined through _retiredFades: membership is the ramp's liveness, so
// removing the entry cancels the ramp, and the remover then owns the pair's
// teardown.
@interface VibeRetiredFade : NSObject
@property (nonatomic, strong) AVAudioPlayerNode *node;
@property (nonatomic, strong) AVAudioUnitVarispeed *varispeed;
@end

@implementation VibeRetiredFade
@end

@implementation AudioPlayer {
    // AudioPlayerInternal.h's class extension declares the ivars the
    // output-device category also touches: _queue, _engine, _node, _file,
    // _segmentStartFrame, _generation, _rampGeneration, _state and _stateLock.
    //
    // Varispeed sits between the current player node and the mixer.
    // playOnQueue: creates a fresh one per track, so a track change crossfades
    // on two independent chains without rerouting the live node. _varispeed
    // always points at the current or incoming track's, and stays nil until
    // the first play mints one; a pre-play setPitch: only records _pitch,
    // since connectNode:throughVarispeed… re-applies the rate to every new
    // varispeed. Rate changes resample like a turntable motor, so tempo and
    // pitch move together. _stateLock guards _pitch, in percent, so the UI can
    // read it without touching the queue.
    AVAudioUnitVarispeed    *_varispeed;
    float                   _pitch;
    float                   _maxPitch;
    NSTimeInterval          _pausedPosition;
    // Last position computed from a valid playerTime, guarded by _stateLock.
    // When the engine stops itself, on a device unplug or format change,
    // lastRenderTime goes nil before the recovery path can read the position.
    // Without this cache, recovery restores from the segment start and the
    // track restarts at 0:00, or at the last seek point. Reset it alongside
    // every _pausedPosition write.
    NSTimeInterval          _lastValidPosition;
    // Bumped under _stateLock by every queue-side write of the position state
    // above. The position getter runs concurrently on the main thread and
    // writes _lastValidPosition back after computing off-lock. Without the
    // epoch check, a getter that snapshotted pre-seek state could clobber the
    // freshly seeked position with a stale one.
    uint64_t                _positionEpoch;
    uint64_t                _openRequestId;
    // Path of the track whose open is currently in flight, matching
    // _openRequestId, or nil. Mutated only on _queue. Re-selecting the same
    // still-loading track is a no-op, since its open will deliver, rather
    // than stranding a second blocked global-queue worker on initForReading:.
    NSString *_currentOpenPath;
    // The AudioTrack the in-flight open should deliver. Normally it is the
    // object passed to play:, but a same-path replay rebinds it: dropping the
    // same file again replaces the playlist with fresh AudioTrack objects, and
    // the open must complete with the object the new playlist actually
    // contains. Otherwise row state, artwork and end-of-track advance all
    // mismatch.
    AudioTrack *_pendingOpenTrack;
    // Where the in-flight open should start, and whether it parks there. Ride
    // with _pendingOpenTrack: written by play:atPosition:startPaused:,
    // consumed once by finishPlayOnQueue:, cleared with the track when an
    // open is abandoned. Queue-confined.
    NSTimeInterval          _pendingStartPosition;
    BOOL                    _pendingStartPaused;
    // Forces the declick minimum on this play's crossfade — the convert
    // swap's same-audio replace. Rides with _pendingStartPosition.
    BOOL                    _pendingDeclick;
    // The fade-in length for the play in flight: the user-set crossfade when
    // it replaced an audibly playing track, the declick minimum otherwise.
    // Written by playOnQueue: alongside the matching retire, read by
    // finishPlayOnQueue:'s fade-in. Queue-confined.
    uint64_t                _incomingFadeMilliseconds;
    // Pre-opened handle for the playlist's likely-next track, from
    // prefetchTrack:. Queue-confined, and consumed once by a play: of the same
    // path, which skips the file open and so the dominant transition latency.
    // The request id pairs each prefetch with its async open, so a superseded
    // prefetch cannot park a stale handle. A parked handle holds an open fd,
    // so a file rewritten between prefetch and play plays the bytes as
    // prefetched, which matches the behavior of a file rewritten mid-playback.
    // A prefetch open still in flight at play: time is not adopted, because
    // its utility-QoS worker cannot be boosted (see playOnQueue:); the play
    // races it with its own open.
    NSString                *_prefetchedPath;
    AVAudioFile             *_prefetchedFile;
    uint64_t                _prefetchRequestId;
    // Bumped by startEngineAndPlayNode:, the single funnel for starting
    // playback, to dissolve the deferred idle engine stop scheduled by
    // scheduleEngineIdleStopOnQueue. Queue-confined.
    uint64_t                _engineIdleStopGeneration;
    // A pause fade is in flight. Queue-confined. A second playPause during the
    // fade-out cancels the pending pause and ramps back up rather than pausing
    // twice. The fade's completion clears it, and runs on preemption too, as
    // does preemptRampsOnQueue eagerly.
    BOOL                    _pausePending;
    // Crossfade-length retired fades in flight, registered by retireNode:.
    // Queue-confined. Stop, pause and the failure reset preempt them through
    // preemptRetiredFadesOnQueue, so an outgoing track cannot stay audible
    // for up to the full crossfade; declick-length retires never register.
    NSMutableArray<VibeRetiredFade *> *_retiredFades;
    id                      _configChangeObserver;
}

#pragma mark - Init

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate {
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _maxPitch = kDefaultMaxPitchPercent;
        _crossfadeMilliseconds = kFadeDurationMilliseconds;
        // Meaningful before the async init block resolves the saved device:
        // -1 means follow the system default, rather than a bogus device id 0.
        self.currentlyRequestedAudioDeviceId = -1;
        // Default QoS, not user-initiated. This queue owns the engine graph
        // and calls blocking AVAudioEngine APIs — [node stop], detachNode:,
        // engine start and stop — which wait on the engine's internal
        // graph-reconfiguration thread, itself at Default QoS. A
        // user-initiated queue blocking on that lower-QoS thread is a priority
        // inversion, which the Thread Performance Checker flagged on the skip
        // teardown. Matching Default removes it. The latency-critical file open
        // runs on its own user-initiated global queue (see playOnQueue:), so
        // leaving control-plane scheduling at Default costs nothing
        // perceptible.
        _queue = dispatch_queue_create("com.vibe.audioplayer",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        dispatch_queue_set_specific(_queue, kAudioPlayerQueueKey, kAudioPlayerQueueKey, NULL);
        // Created before the async engine init so that fx is non-nil from the
        // caller's first moment. Intent set early, by a key press or the BPM
        // feed, is recorded and applied when installInEngine: runs below.
        _fx = [[AudioFX alloc] initWithQueue:_queue];
        _retiredFades = [NSMutableArray array];
        self.delegate = delegate;
        dispatch_async(_queue, ^{

            LogDebug(@"AudioPlayer init");

            self->_engine = [[AVAudioEngine alloc] init];

            // The FX segment — low kill, and the reverb and delay returns —
            // owns everything between the main mixer and the output node.
            // See AudioFX.
            [self->_fx installInEngine:self->_engine];

#if DEBUG
            // --silent, for testing: zero the main mixer so that playback runs
            // normally but nothing reaches the output device. It sits
            // downstream of all fade ramps, which are player-node volumes, and
            // upstream of the FX returns, so wet tails are silenced too. It
            // must run after installInEngine:, because a mixer volume written
            // before the node is attached and wired is silently dropped. See
            // AudioFX.m.
            if ([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]) {
                self->_engine.mainMixerNode.outputVolume = 0;
                LogInfo(@"AudioPlayer: --silent, output muted");
            }
#endif

            // Resolve the saved device here rather than on the main thread.
            // This is the app's first CoreAudio device enumeration, a set of
            // per-device HAL property reads that take tens of ms when
            // Bluetooth or aggregate devices are present, and the caller runs
            // before the window's first paint. Match by UID first, which is
            // robust against duplicate device names, and fall back to the name
            // for settings saved before UIDs.
            AudioDevice *device = [[AudioDeviceManager sharedInstance] outputDeviceForUID:deviceUID];
            if (!device) {
                device = [[AudioDeviceManager sharedInstance] outputDeviceForName:deviceName];
            }
            // A nil device — an empty or unmatched UID and name — means follow
            // the system default.
            NSInteger deviceIndex = device ? device.deviceId : -1;
            self.currentlyRequestedAudioDeviceId = deviceIndex;
            if (deviceIndex >= 0) {
                [self setOutputUnitDevice:(AudioDeviceID)deviceIndex];
            }
            else if (deviceUID.length > 0 || deviceName.length > 0) {
                // A device was saved but has gone. Fall back to System Output
                // for good, not just for this launch: the delegate persists
                // the -1 choice, so the old device cannot reclaim the
                // checkmark if it reappears later.
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
    // Engine mutation belongs on _queue, as everywhere else. dispatch_sync
    // from here cannot deadlock against in-flight queue work: a queued block
    // either holds a strongSelf, in which case the retain count is nonzero and
    // dealloc is not running, or resolves its weakSelf to nil and returns
    // without dispatching anywhere, and run_on_main_thread is async besides.
    // The one remaining hazard is dealloc itself running on _queue, when a
    // queued block releases the last reference, so that case tears down
    // inline.
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
    [self playTrack:track atPosition:0 startPaused:NO declick:NO];
}

// The convert swap's entry: the same audio resumes at the same position, so
// the replace declicks rather than crossfades — a crossfade of a signal with
// itself only dips the volume for the fade length.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused {
    [self playTrack:track atPosition:position startPaused:startPaused declick:YES];
}

- (void)playTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused declick:(BOOL)declick {
    dispatch_async(_queue, ^{
        self->_pendingStartPosition = MAX(0, position);
        self->_pendingStartPaused = startPaused;
        self->_pendingDeclick = declick;
        [self playOnQueue:track];
    });
}

- (void)playOnQueue:(AudioTrack *)track {
    NSString *path = track.url.path;
    if (_state == VibePlayerStateLoading && [path isEqualToString:_currentOpenPath]) {
        // This exact file is already loading, with its open in flight. Do not
        // start another open: that would strand a second blocked worker and,
        // on a slow file, flash a spurious timeout error before the first one
        // completes. Do rebind the delivery to the new track object, though.
        // A re-drop replaces the playlist with fresh AudioTrack instances, and
        // completing with the old one would orphan the open's result.
        // This runs before any teardown, so re-clicking the loading row is a
        // true no-op rather than a generation bump plus a varispeed swap whose
        // in-flight open then plays through a needlessly rebuilt chain.
        _pendingOpenTrack = track;
        return;
    }

    _generation++;
    [self preemptRampsOnQueue]; // preempt any in-flight resume fade-in

    // Dual-varispeed crossfade: the incoming track gets a brand-new varispeed,
    // and the outgoing node retires together with its old one. The outgoing
    // node's live connection is therefore never rerouted. Rerouting a running
    // node reconfigures the graph and clicks, which is why the seek path never
    // reconnects either; here we only ramp its volume. The two tracks ride
    // independent player->varispeed->mixer chains, so the incoming connect
    // cannot steal the outgoing bus, and each varispeed is connected exactly
    // once, for one track's format. There is no cross-format reconnection; see
    // connectNode:throughVarispeedWithFormat:.
    AVAudioPlayerNode *oldNode = _node;
    AVAudioUnitVarispeed *oldVarispeed = _varispeed;
    // Whether this play replaces an audibly playing track — the only case the
    // user-set crossfade length applies to. Decided before the state flips to
    // Loading below; retireNode re-makes the same check. Everything else — a
    // first play, a play from pause or stop — fades at the declick minimum,
    // so transport stays instant. Both sides of the crossfade ride
    // _incomingFadeMilliseconds: the retire here, the fade-in when the open
    // lands in finishPlayOnQueue:.
    BOOL crossfading = (oldNode && _engine.isRunning && _state == VibePlayerStatePlaying
                        && !_pendingDeclick);
    _incomingFadeMilliseconds = crossfading
            ? (uint64_t)MAX(self.crossfadeMilliseconds, (NSInteger)kFadeDurationMilliseconds)
            : kFadeDurationMilliseconds;
    os_unfair_lock_lock(&_stateLock);
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);

    AVAudioUnitVarispeed *newVarispeed = [[AVAudioUnitVarispeed alloc] init];
    [_engine attachNode:newVarispeed];
    _varispeed = newVarispeed; // finishPlayOnQueue:'s incoming node connects through this

    // The retire fades the outgoing side out while the incoming node fades in
    // concurrently on the new varispeed, in finishPlayOnQueue: — an audible,
    // true crossfade.
    [self retireNode:oldNode varispeed:oldVarispeed milliseconds:_incomingFadeMilliseconds];

    self.currentTrack = nil;

    LogDebug(@"play file: %@", path);

    // Enter the loading state: no node or file yet, but a play is committed.
    // This clears the previous track's file and position, so the UI stops
    // showing a stale duration and position for up to the full open timeout.
    [self publishPlaybackState:VibePlayerStateLoading node:nil file:nil segmentStart:0 position:0];

    // A prefetched handle for this exact path skips the open entirely, and the
    // transition goes straight to schedule and play. Ownership passes to the
    // normal finish path with a fresh open id, so it consumes that id like any
    // completed open, and no timeout or loading-indicator timers ever exist.
    if (_prefetchedFile && [path isEqualToString:_prefetchedPath]) {
        AVAudioFile *prefetchedFile = _prefetchedFile;
        _prefetchedFile = nil;
        _prefetchedPath = nil;
        _currentOpenPath = path;
        _pendingOpenTrack = track;
        [self finishPlayOnQueue:track file:prefetchedFile error:nil openRequestId:++_openRequestId];
        return;
    }

    // Open the file off-queue. An iCloud or Dropbox placeholder blocks the
    // open until it materializes, and that must never wedge the player queue.
    // The request id pairs each open with its timeout: whichever fires first
    // consumes the id, and the other becomes a no-op.
    _currentOpenPath = path;
    _pendingOpenTrack = track;
    uint64_t openId = ++_openRequestId;
    __weak AudioPlayer *weakSelf = self;
    // Always open on our own user-initiated worker, even when a prefetch open
    // for this exact path is still in flight: that worker runs at utility QoS,
    // and a block already executing cannot be boosted. Both workers deliver
    // into finishPlayOnQueue:, which consumes the open id, so the loser no-ops
    // (see prefetchOnQueue:). The prefetch claim stays unconsumed, so its
    // completion can still deliver first, or park the handle if it loses.
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFileOpenTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        [weakSelf fileOpenTimedOut:track openRequestId:openId];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSlowOpenIndicatorDelaySeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf && openId == strongSelf->_openRequestId) {
            // Still waiting on the open, so let the UI show a loading state.
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
    _currentOpenPath = nil; // This open resolved, so the track is no longer loading.
    // Deliver the track object the playlist currently knows. A same-path
    // replay, from a re-drop, may have rebound it since this open was
    // dispatched.
    if (_pendingOpenTrack) {
        track = _pendingOpenTrack;
    }
    _pendingOpenTrack = nil;
    NSTimeInterval startPosition = _pendingStartPosition;
    BOOL startPaused = _pendingStartPaused;
    _pendingStartPosition = 0;
    _pendingStartPaused = NO;
    _pendingDeclick = NO;

    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error, track.url)];
        return;
    }

    AVAudioPlayerNode *node = [[AVAudioPlayerNode alloc] init];
    [_engine attachNode:node];
    if (![self connectNode:node throughVarispeedWithFormat:file.processingFormat]) {
        [self detachNodeAfterFailedConnect:node];
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not play %@ (unsupported format)", track.url.lastPathComponent], nil, track.url)];
        return;
    }

    // Clamp as seekToPosition: does: a start past the end lands on the last
    // frame rather than scheduling an empty segment.
    double sampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition startFrame = (AVAudioFramePosition)(startPosition * sampleRate);
    startFrame = MAX(0, MIN(startFrame, file.length - 1));
    NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;

    [self scheduleFile:file onNode:node fromFrame:startFrame];
    node.volume = 0; // fade in from silence (see the ramp below)

    if (startPaused) {
        // A scheduled, silent, never-played node is exactly what a pause
        // leaves behind, so playPause's resume branch takes it from here.
        [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                      segmentStart:startFrame position:framePosition];
    }
    else {
        NSError *startError = nil;
        if (![self startEngineAndPlayNode:node error:&startError]) {
            _generation++; // drop the scheduled segment's stop-fired completion
            [node stop];
            [_engine detachNode:node];
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                    @"Could not start audio engine", startError, track.url)];
            return;
        }

        [self publishPlaybackState:VibePlayerStatePlaying node:node file:file
                      segmentStart:startFrame position:framePosition];

        // Fade the new track in from silence. Its first frame is rarely a zero
        // crossing, so starting at full volume clicks, which is why the seek fades
        // in too. This uses the current ramp generation rather than a fresh one,
        // so it rises in step with the outgoing track's fade-out — a real
        // crossfade — and neither ramp cancels the other. The length matches
        // that fade-out: the crossfade setting when one is running, the
        // declick minimum otherwise (see playOnQueue:).
        uint64_t fadeMs = _incomingFadeMilliseconds ?: kFadeDurationMilliseconds;
        [self stepRampAsync:node step:1 from:0 to:1.0
                     totalSteps:VibeFadeStepsForMilliseconds(fadeMs)
               stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(fadeMs)
                    preemptable:YES generation:_rampGeneration completion:nil];
    }

    self.currentTrack = track;
    track.duration = self.duration;
    run_on_main_thread({
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

// Wires node -> varispeed -> mixer for a track's format. Runs on _queue.
// playOnQueue: creates _varispeed freshly for each track, and it is normally
// connected exactly once here, so it never has to reinitialize across a
// channel-count change. A varispeed reconnected between stereo and mono throws
// kAudioUnitErr_FormatNotSupported and forces an engine stop. The one
// re-connect, in device-switch recovery, rewires the same varispeed for the
// same format with the engine stopped, which is safe. The catch clause is the
// backstop for whatever formats the graph still refuses: a failed connect must
// report, not crash. The rate does not affect position math, because
// playerTimeForNodeTime: counts the file frames the player node rendered and
// the varispeed merely consumes them faster or slower.
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

// A detach that cannot throw. After a failed connect, a node can be in a state
// that AVAudioEngine's RemoveNode refuses, raising an NSException, and leaking
// the node beats crashing on an already-failing path.
- (void)detachNodeAfterFailedConnect:(AVAudioNode *)node {
    @try {
        [_engine detachNode:node];
    }
    @catch (NSException *exception) {
        LogError(@"AudioPlayer: detach after failed connect: %@", exception);
    }
}

// Schedules the remainder of the file from startFrame, with a completion
// tagged by the current generation. AVAudioPlayerNode fires completions on
// stop and reschedule too, not only at a natural end, so every interruption —
// skip, seek, device switch or a new play — bumps _generation first and those
// completions are dropped.
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
    // Clear this so the file stays retryable: a later play of it starts a
    // fresh open. The original worker may stay blocked on a truly hung mount,
    // leaking one worker, but the loading no-op has already absorbed any rapid
    // re-clicks.
    _currentOpenPath = nil;
    if (_pendingOpenTrack) {
        track = _pendingOpenTrack; // report against the rebound, current object
    }
    _pendingOpenTrack = nil;
    LogError(@"Timed out opening %@", track.url.path);
    [self resetToStoppedStateOnQueue];
    [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenTimedOut,
            [NSString stringWithFormat:@"Timed out opening %@ — it may still be downloading from iCloud/Dropbox or the network may be unavailable",
                                       track.url.lastPathComponent], nil, track.url)];
}

- (void)prefetchTrack:(AudioTrack *)track {
    dispatch_async(_queue, ^{
        [self prefetchOnQueue:track];
    });
}

// Runs on _queue. Opens the file on a background queue and parks the handle
// for playOnQueue: to consume. Utility QoS is right because this is readahead
// for a track that will not be needed for minutes, not user-blocking work; a
// play: arriving mid-open runs its own user-initiated open (see playOnQueue:).
// A blocked open, on a cloud placeholder, strands one worker — the same
// tradeoff the playback open accepts — and usefully starts the download before
// the track is due.
- (void)prefetchOnQueue:(AudioTrack *)track {
    NSString *path = track.url.path;
    if (path && [path isEqualToString:_prefetchedPath]) {
        return; // already prefetched, or that open is still in flight
    }
    if (path && [path isEqualToString:_currentOpenPath]) {
        return; // being opened for playback right now
    }
    _prefetchRequestId++; // supersede any in-flight prefetch open
    // Claimed at request time rather than at completion, so that repeated
    // prefetches of the same path do not stack opens. _prefetchedFile stays
    // nil until the open lands.
    _prefetchedPath = path;
    _prefetchedFile = nil;
    if (!path) {
        return; // nil track means end of playlist: just drop the parked handle
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
                // A play of this path is waiting on its own open, since plays
                // never adopt this worker (see playOnQueue:). Deliver on
                // success only. finishPlayOnQueue: consumes the open id, so
                // whichever worker lands second no-ops, and rebinds to
                // _pendingOpenTrack. A failed prefetch open must not consume
                // the id: the play's own open may yet succeed, and consuming
                // here would turn that recoverable race into a "Could not
                // open". Either way this open is spent and nothing gets
                // parked, so release the claim if it is still ours. Left set,
                // a later prefetch of the same path would no-op against an
                // empty park.
                if (prefetchId == strongSelf->_prefetchRequestId) {
                    strongSelf->_prefetchedPath = nil;
                }
                if (file && file.length > 0) {
                    [strongSelf finishPlayOnQueue:track file:file error:error
                                    openRequestId:strongSelf->_openRequestId];
                }
                return;
            }
            if (prefetchId != strongSelf->_prefetchRequestId) {
                return; // a newer prefetch target, or an adoption, superseded this open
            }
            if (file && file.length > 0) {
                strongSelf->_prefetchedFile = file;
            }
            else {
                // The open failed. Release the claim so that a play of this
                // track runs its own open and reports the error the usual way.
                strongSelf->_prefetchedPath = nil;
            }
        });
    });
}

// Marks playback fully stopped after a failure, so that isPlaying and duration
// report reality and the play button can recover.
- (void)resetToStoppedStateOnQueue {
    // Invalidate any in-flight open. After an unrelated failure resets to
    // Stopped — a device switch failing mid-Loading, say — a still-pending
    // open must not land later and start playback out of an errored or stopped
    // UI. The extra bump is harmless when the caller already consumed the id.
    _openRequestId++;
    _currentOpenPath = nil;
    _pendingOpenTrack = nil;
    // The abandoned open's start request goes with its track.
    _pendingStartPosition = 0;
    _pendingStartPaused = NO;
    _pendingDeclick = NO;
    // Detach the varispeed that playOnQueue: attached for the failed track.
    // Otherwise it stays attached across Stopped until the next play or stop;
    // stopOnQueue arrives here with it already nil. The detach must not throw,
    // because this can run right after a failed connect left it
    // half-connected.
    if (_varispeed) {
        [self detachNodeAfterFailedConnect:_varispeed];
        _varispeed = nil;
    }
    // Stop and every failure path land here — a crossfade whose incoming open
    // failed included — so the outgoing fade must not ring on for up to the
    // full crossfade length.
    [self preemptRetiredFadesOnQueue];
    [self publishPlaybackState:VibePlayerStateStopped node:nil file:nil segmentStart:0 position:0];
    // Release the output device once genuinely idle. A quick follow-up play,
    // such as auto-advance past a bad file, reuses the running engine.
    [self scheduleEngineIdleStopOnQueue];
}

// Runs on _queue. Stops the engine after a grace period if playback is still
// Stopped, which releases the output device. Any start or restart of playback
// in the interim bumps the generation and the pending stop dissolves;
// startEngineAndPlayNode: is the single funnel for that.
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
        // busy, because the in-flight open's finish path wants a warm engine.
        if (state == VibePlayerStateStopped) {
            [strongSelf->_engine stop];
        }
    });
}

// [AVAudioPlayerNode play] throws an NSException if the engine stopped between
// our isRunning check and the call, and the engine stops itself on device and
// format changes. Start the engine if needed, and absorb the race.
- (BOOL)startEngineAndPlayNode:(AVAudioPlayerNode *)node error:(NSError **)outError {
    if (outError) {
        *outError = nil;
    }
    _engineIdleStopGeneration++; // playback is starting: cancel any pending idle stop
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
        return; // Stale: a stop, seek, skip or device switch superseded this segment.
    }
    [self finishPlaybackOnQueue];
}

// The shared terminus for "the current track is done": the natural segment
// completion above and an explicit -finishCurrentTrack both land here, on
// _queue. It marks the player Stopped, tears the finished node down and
// notifies the delegate, whose handler drives auto-advance or the
// end-of-playlist stop. The engine stop is deferred so that the auto-advance
// play, which arrives within milliseconds through didFinishPlaying → next,
// reuses the running engine rather than paying an output-unit stop and start
// on every consecutive-track transition.
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
    // Snapshot before dispatching. If the track has changed by the time the
    // block runs on main, this end event is stale and must be dropped.
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
        AVAudioPlayerNode *node = self->_node;
        os_unfair_lock_unlock(&self->_stateLock);
        // Only a live track can finish. Stopped has nothing to do, and Loading
        // has no node yet, so both are no-ops. The skip path never reaches
        // here while loading anyway, since the duration is 0.
        if (state != VibePlayerStatePlaying && state != VibePlayerStatePaused) {
            return;
        }
        // [node stop] inside finishPlaybackOnQueue fires the scheduled
        // completion, so bump _generation to make
        // segmentDidCompleteWithGeneration: drop it, and preempt any in-flight
        // fade. Seek, skip and device-switch perform the same dance.
        self->_generation++;
        [self preemptRampsOnQueue];
        if (state == VibePlayerStatePlaying && node && self->_engine.isRunning) {
            // A natural end is already silent, but this path can arrive at
            // full volume, on a forward skip past the end, so fade first or
            // the bare [node stop] clicks. It uses the retired-node ramp: a
            // pause or seek mid-fade must not preempt it and strand the node
            // audible.
            __weak AudioPlayer *weakSelf = self;
            [self rampRetiredNodeAsync:node step:1 from:node.volume milliseconds:kFadeDurationMilliseconds completion:^{
                AudioPlayer *strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_node != node) {
                    return; // A play/stop during the fade owns playback now.
                }
                [strongSelf finishPlaybackOnQueue];
            }];
            return;
        }
        [self finishPlaybackOnQueue];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        [self stopOnQueue];
    });
}

- (void)stopOnQueue {
    _generation++; // drop the scheduled segment's stop-fired completion
    [self preemptRampsOnQueue];

    // Pull the node/varispeed pair out of the live state, fade it to silence
    // if audible, and detach both.
    AVAudioPlayerNode *oldNode = _node;
    AVAudioUnitVarispeed *oldVarispeed = _varispeed;
    os_unfair_lock_lock(&_stateLock);
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);
    _varispeed = nil;

    // The declick minimum, never the crossfade length: a stop should land
    // immediately.
    [self retireNode:oldNode varispeed:oldVarispeed milliseconds:kFadeDurationMilliseconds];

    self.currentTrack = nil;
    // This supersedes any in-flight open, publishes Stopped and schedules the
    // engine idle stop that releases the output device.
    [self resetToStoppedStateOnQueue];
}

- (void)playPause {
    dispatch_async(_queue, ^{
        if (self->_state == VibePlayerStateLoading) {
            // A play is committed and its file open is in flight, so the
            // toggle has nothing coherent to act on yet. Ignore it silently.
            return;
        }
        AVAudioPlayerNode *node = self->_node;
        if (!node) {
            [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
            return;
        }
        if (self->_state == VibePlayerStatePlaying) {
            if (self->_pausePending) {
                // A second press during the pause fade-out cancels the pending
                // pause and ramps back up. There is no delegate event, because
                // didPause never fired and the UI never left the playing
                // state.
                uint64_t rampGen = [self preemptRampsOnQueue];
                [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
                return;
            }
            uint64_t rampGen = [self preemptRampsOnQueue]; // cancel any in-flight resume fade-in
            // A pause must silence a crossfade's outgoing tail too, not just
            // the current node.
            [self preemptRetiredFadesOnQueue];
            // Fade out asynchronously, then pause in the completion. The queue
            // must not block for the fade, or a skip or seek issued right
            // behind a pause would stall behind it. The state stays Playing
            // through the fade, because the node really is still rendering.
            self->_pausePending = YES;
            __weak AudioPlayer *weakSelf = self;
            [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
                AudioPlayer *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                // This runs on _queue, and in every case including preemption,
                // so the pending flag can be cleared unconditionally.
                strongSelf->_pausePending = NO;
                // A preempted ramp still reaches this completion (see
                // rampNodeAsync:), so the node and state checks alone are not
                // enough. The cancel-pause ramp-up and a seek's own fade both
                // bump _rampGeneration while leaving node and state untouched,
                // and pausing under them would fight the operation that now
                // owns volume and state.
                if (rampGen != strongSelf->_rampGeneration
                        || strongSelf->_node != node || strongSelf->_state != VibePlayerStatePlaying) {
                    return; // A play, stop, seek or device switch superseded the pause.
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
            uint64_t rampGen = [self preemptRampsOnQueue];
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

// Runs on _queue. It captures the position, pauses the node and publishes the
// Paused state. The capture happens after any fade, since the node keeps
// rendering through the ramp, but before [node pause], because once paused
// playerTimeForNodeTime: stops reporting.
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

// The single way to preempt the generation-tagged ramps. Runs on _queue.
// Clearing _pausePending belongs with the bump. The preempted pause fade's
// completion also clears it, but up to one fade step, roughly 2.5ms, later,
// and a playPause inside that window would take the "cancel pending pause"
// path and ramp the preemptor's node to full instead of pausing it.
- (uint64_t)preemptRampsOnQueue {
    _pausePending = NO;
    return ++_rampGeneration;
}

// The player's one fade-stepping loop, kept non-blocking by dispatch_after on
// the player queue. Both ramp flavors below are thin entries into it. The
// curve and cadence live in VibeFadeCurve.h, shared with AudioFX's send-gate
// stepper. A preemptable ramp stops stepping the volume once _rampGeneration
// moves past its generation, but still runs its completion, so that
// completion-side bookkeeping is not lost: the pause fade's _pausePending
// clear, and the seek's reschedule and didFinishSeeking settle. Those
// completions re-check the generation themselves and yield to the preemptor.
- (void)stepRampAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target totalSteps:(int)totalSteps stepMicroseconds:(uint64_t)stepMicroseconds preemptable:(BOOL)preemptable generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    if (preemptable && generation != _rampGeneration) {
        if (completion) {
            completion();
        }
        return;
    }
    node.volume = VibeFadeVolumeOverSteps(start, target, step, totalSteps);
    if (step >= totalSteps) {
        if (completion) {
            completion();
        }
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepRampAsync:node step:step + 1 from:start to:target totalSteps:totalSteps stepMicroseconds:stepMicroseconds preemptable:preemptable generation:generation completion:completion];
    });
}

// Generation-tagged declick fade for the current node, at the default
// cadence. A pause, seek, skip, device switch or new play bumps
// _rampGeneration and preempts it.
- (void)rampNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start to:(float)target generation:(uint64_t)generation completion:(dispatch_block_t)completion {
    [self stepRampAsync:node step:step from:start to:target totalSteps:kFadeSteps stepMicroseconds:kFadeStepMicroseconds preemptable:YES generation:generation completion:completion];
}

// Declick-length fade to silence for a retired node — the short retires, the
// skip-past-end fade in finishCurrentTrack, and the replacement fades
// preemptRetiredFadesOnQueue starts. It is deliberately not preemptable:
// preemption would hard-stop the node at mid-fade volume, an audible click,
// and at this length nothing needs to cut it short. It always reaches
// silence, then runs the completion exactly once. Crossfade-length retires go
// through the registered stepper below instead, so stop and pause can preempt
// them.
- (void)rampRetiredNodeAsync:(AVAudioPlayerNode *)node step:(int)step from:(float)start milliseconds:(uint64_t)milliseconds completion:(dispatch_block_t)completion {
    [self stepRampAsync:node step:step from:start to:0
             totalSteps:VibeFadeStepsForMilliseconds(milliseconds)
       stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(milliseconds)
            preemptable:NO generation:0 completion:completion];
}

// The crossfade-length retired fade's stepping loop. Deliberately not tagged
// with _rampGeneration — a rapid skip must never cut the outgoing track's
// crossfade short — but cancellable by removing its entry from _retiredFades,
// after which the remover owns the pair's teardown and this loop halts
// without touching the node.
- (void)stepRetiredFadeAsync:(VibeRetiredFade *)fade step:(int)step from:(float)start totalSteps:(int)totalSteps stepMicroseconds:(uint64_t)stepMicroseconds {
    if (![_retiredFades containsObject:fade]) {
        return; // Preempted: stop, pause or reset tears the pair down.
    }
    fade.node.volume = VibeFadeVolumeOverSteps(start, 0, step, totalSteps);
    if (step >= totalSteps) {
        [_retiredFades removeObject:fade];
        [self detachRetiredFadePair:fade];
        return;
    }
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stepMicroseconds * NSEC_PER_USEC)), _queue, ^{
        [weakSelf stepRetiredFadeAsync:fade step:step + 1 from:start totalSteps:totalSteps stepMicroseconds:stepMicroseconds];
    });
}

// Runs on _queue. Stops and detaches a retired pair, exactly once per pair:
// the caller owns it either through the natural ramp completion, which
// removes the entry itself, or by having removed the entry to cancel the
// ramp.
- (void)detachRetiredFadePair:(VibeRetiredFade *)fade {
    [fade.node stop];
    [_engine detachNode:fade.node];
    if (fade.varispeed) {
        [_engine detachNode:fade.varispeed];
    }
}

// Runs on _queue. Cuts every in-flight crossfade-length retired fade down to
// the declick minimum: stop, pause and the failure reset must not leave an
// outgoing track audible for up to the full crossfade. Removing the entries
// cancels their long ramps; each replacement fade is unregistered, always
// reaches silence, and detaches its pair exactly once. Skips never call
// this, so rapid skips keep the full crossfade fade-out.
- (void)preemptRetiredFadesOnQueue {
    if (_retiredFades.count == 0) {
        return;
    }
    NSArray<VibeRetiredFade *> *fades = [_retiredFades copy];
    [_retiredFades removeAllObjects];
    for (VibeRetiredFade *fade in fades) {
        [self rampRetiredNodeAsync:fade.node step:1 from:fade.node.volume milliseconds:kFadeDurationMilliseconds completion:^{
            [self detachRetiredFadePair:fade];
        }];
    }
}

// Tears down a node and varispeed pair the caller has already pulled out of
// the live state. Runs on _queue, and either may be nil. When the pair is
// audible — the engine running and the state still Playing — the node fades
// out on its own varispeed and both are detached once silent. It is not the
// generation-tagged ramp, because a second skip inside the fade window must
// not preempt it: its completion would then stop the node at mid-fade volume,
// which clicks. A crossfade-length fade registers in _retiredFades so stop,
// pause and reset can still silence it early. Otherwise, when paused or
// stopped or on a first play, both are torn down immediately, at silence, so
// there is nothing to click.
- (void)retireNode:(AVAudioPlayerNode *)node varispeed:(AVAudioUnitVarispeed *)varispeed milliseconds:(uint64_t)milliseconds {
    AVAudioEngine *engine = _engine;
    if (node && engine.isRunning && _state == VibePlayerStatePlaying) {
        VibeRetiredFade *fade = [[VibeRetiredFade alloc] init];
        fade.node = node;
        fade.varispeed = varispeed;
        if (milliseconds <= kFadeDurationMilliseconds) {
            [self rampRetiredNodeAsync:node step:1 from:node.volume milliseconds:milliseconds completion:^{
                [self detachRetiredFadePair:fade];
            }];
            return;
        }
        [_retiredFades addObject:fade];
        [self stepRetiredFadeAsync:fade step:1 from:node.volume
                        totalSteps:VibeFadeStepsForMilliseconds(milliseconds)
                  stepMicroseconds:VibeFadeStepMicrosecondsForMilliseconds(milliseconds)];
    }
    else {
        if (node) {
            [node stop];
            [engine detachNode:node];
        }
        if (varispeed) {
            [engine detachNode:varispeed];
        }
    }
}

#pragma mark - Properties

- (BOOL)isPlaying {
    os_unfair_lock_lock(&_stateLock);
    // Loading counts as playing, because a play is committed and imminent, so
    // the UI holds the pause icon rather than flashing the play icon during
    // the open.
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

- (BOOL)isLoading {
    os_unfair_lock_lock(&_stateLock);
    BOOL loading = (_state == VibePlayerStateLoading);
    os_unfair_lock_unlock(&_stateLock);
    return loading;
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
        // The queue can detach this node concurrently, on fast skips, because
        // this getter is deliberately lock-free, and a detached node's
        // lastRenderTime raises when _engine is non-nil rather than returning
        // nil. Treat that as no reading: the fallback below serves the last
        // valid position, and the next tick reads the replacement node.
        AVAudioTime *nodeTime = node.lastRenderTime;
        playerTime = nodeTime ? [node playerTimeForNodeTime:nodeTime] : nil;
    }
    @catch (NSException *exception) {
        playerTime = nil;
    }
    NSTimeInterval position;
    if (!playerTime || !playerTime.sampleTimeValid) {
        // Either nothing has rendered yet, right after a play, or the engine
        // stopped itself on a device unplug or format change, since
        // lastRenderTime is nil while stopped. Within one segment the last
        // valid reading is never behind the segment start, so MAX covers both.
        position = MAX((NSTimeInterval)segmentStartFrame / sampleRate, lastValidPosition);
    }
    else {
        position = (NSTimeInterval)(segmentStartFrame + playerTime.sampleTime) / sampleRate;
    }
    NSTimeInterval duration = (NSTimeInterval)file.length / sampleRate;
    position = MIN(MAX(position, 0), duration);
    if (playerTime && playerTime.sampleTimeValid) {
        os_unfair_lock_lock(&_stateLock);
        // A seek, pause or track change may have rewritten the position state
        // while this was computed off-lock, and storing it then would
        // resurrect the pre-seek position. The stale reading is not returned
        // upward either: the epoch writer's value is the truth now.
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

- (void)seekToPosition:(NSTimeInterval)pos {
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
            // Paused: reschedule the existing, silent node in place. No audio
            // is rendering, so there is nothing to declick, and the next
            // resume fades in from the seeked frame. The faded volume is kept,
            // and the resume ramps it back up.
            [self preemptRampsOnQueue];
            [node stop];
            [self scheduleFile:file onNode:node fromFrame:startFrame];
            [self publishPlaybackState:self->_state node:node file:file segmentStart:startFrame position:framePosition];
            run_on_main_thread({
                [self.delegate audioPlayer:self didFinishSeeking:track];
            });
            return;
        }

        // Playing: declick without touching the audio graph. Reconnecting a
        // live node, as the two-node crossfade's reroute does, is itself a
        // click on a running engine. So instead fade this node down,
        // reschedule it in place and fade it back up: both the [node stop] and
        // the new segment's start then land at silence. The reschedule is
        // deferred into the fade-out completion, because the node must stay
        // audible through the ramp, and the position state is rewritten there
        // so that the getter follows the node.
        uint64_t rampGen = [self preemptRampsOnQueue];
        __weak AudioPlayer *weakSelf = self;
        [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
            [weakSelf finishSeekOnQueue:node file:file startFrame:startFrame
                          framePosition:framePosition rampGeneration:rampGen track:track];
        }];
    });
}

// The playing seek's fade-out completion. It runs on _queue, and the
// parameters are the values seekToPosition: captured when the seek was
// requested. It settles one of four outcomes, each with an early return: the
// node was replaced, the fade was preempted, the engine failed to start, or
// the happy path reschedules and fades back in. Every path delivers
// didFinishSeeking:.
- (void)finishSeekOnQueue:(AVAudioPlayerNode *)node
                     file:(AVAudioFile *)file
               startFrame:(AVAudioFramePosition)startFrame
            framePosition:(NSTimeInterval)framePosition
           rampGeneration:(uint64_t)rampGen
                    track:(AudioTrack *)track {
    if (_node != node) {
        // A new play, track change, stop or device switch replaced the
        // node while this faded. That operation owns playback and this
        // seek's target is moot. The seek is dropped, but the request
        // still settles the UI: the header promises didFinishSeeking:
        // for every seek request, and Control Center resyncs off it.
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    // Same node, but a pause, its cancel or a newer seek bumped the ramp
    // generation mid-fade. The reschedule below still lands, since the
    // user asked for this position, but the preemptor owns volume and
    // _state, so this path touches neither.
    BOOL preempted = (rampGen != _rampGeneration);
    // [node stop] fires the completion of whatever segment is scheduled
    // right now, which after a preempted seek's own reschedule can carry
    // the current generation rather than the one this seek's entry bump
    // retired. Re-bump immediately before the stop, or that completion
    // reads as current and "finishes" the track.
    _generation++;
    [node stop];
    [self scheduleFile:file onNode:node fromFrame:startFrame];
    if (preempted) {
        [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
        BOOL stillPlaying = (_state == VibePlayerStatePlaying);
        if (stillPlaying) {
            // Mid-pause-fade the state is still Playing, because the
            // pause completion has not landed and will not if it is
            // cancelled. Restart the node, so that a cancelled pause is
            // not left with a stopped node behind a Playing state. The
            // volume stays wherever the preemptor's ramp has it: that
            // ramp keeps stepping, and a completing pause finds the node
            // where completePauseOfNode: expects it.
            [self startEngineAndPlayNode:node error:NULL];
        }
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    node.volume = 0; // ramp back up from silence
    NSError *startError = nil;
    if (![self startEngineAndPlayNode:node error:&startError]) {
        _generation++; // drop the stop-fired completion
        // Keep the seeked frame, and report paused so the UI recovers.
        [self publishPlaybackState:VibePlayerStatePaused node:node file:file segmentStart:startFrame position:framePosition];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                @"Could not resume playback after seek", startError)];
        run_on_main_thread({
            [self.delegate audioPlayer:self didFinishSeeking:track];
        });
        return;
    }
    [self publishPlaybackState:_state node:node file:file segmentStart:startFrame position:framePosition];
    uint64_t fadeInGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:0 to:1.0 generation:fadeInGen completion:nil];
    run_on_main_thread({
        [self.delegate audioPlayer:self didFinishSeeking:track];
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
    // owning queue, as with every other graph mutation.
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

#pragma mark - Helpers

// The single writer for the full five-field playback and position state. Runs
// on _queue. Everything is published in one lock acquisition, so the
// main-thread getters never observe a torn combination such as a new state
// carrying the old track's position. The epoch bump is structural: the
// position getter computes off-lock and writes _lastValidPosition back only if
// the epoch it snapshotted is still current (see _positionEpoch). A caller
// whose operation leaves a field untouched passes the current value through.
//
// A few sites write _state or _node alone under the lock without coming
// through here. That is safe only because they never move the position fields;
// any write that does must use this publisher.
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
