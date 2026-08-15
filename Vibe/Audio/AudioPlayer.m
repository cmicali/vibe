//
//  AudioPlayer.m
//  Vibe
//
//  Created by Christopher Micali on 12/18/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#import "AudioPlayer.h"
#import "AudioPlayerInternal.h"
#if DEBUG
#import "VibeManualRenderPump.h"
#endif
#import "AudioFX.h"
#import "AudioTrack.h"
#import "AudioDeviceManager.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#import "NSURL+AudioOpen.h"
#import "FadeMath.h"
#import "GaplessSpliceMath.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

NSString *const kVibeAudioErrorDomain = @"com.commonwealthrecordings.Vibe";
NSString *const kVibeAudioErrorTrackURLKey = @"VibeAudioErrorTrackURL";

// Descriptions are NOT localized: every consumer is a log site. The UI status
// comes from +[MainPlayerController statusForPlayError:], which maps the error
// code and localizes there.
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

// Default pitch fader range in percent: ±8%, matching a stock SL-1200.
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so dealloc can tell whether it is
// already running on the queue, as it is when a queued block drops the last
// reference. dispatch_sync onto the current queue deadlocks.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

// The state a category also touches is in AudioPlayerInternal.h; what follows
// is private to this file.
@implementation AudioPlayer {
    float                   _maxPitch;
    NSTimeInterval          _pausedPosition;
    BOOL                    _loadingStartPaused;
    uint64_t                _nextSubmittedPlayIdentifier;
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
    // Forces the declick minimum on this play's crossfade — the convert
    // swap's same-audio replace. Rides with the pending request.
    BOOL                    _pendingDeclick;
    // The fade-in length for the play in flight: the user-set crossfade when
    // it replaced an audibly playing track, the declick minimum otherwise.
    // Written by playOnQueue: alongside the matching retire, read by
    // finishPlayOnQueueWithFile:error:openRequestId:'s fade-in. Queue-confined.
    uint64_t                _incomingFadeMilliseconds;
    id                      _configChangeObserver;
#if DEBUG
    // --no-audio-hw's stand-in for the HAL IO thread; see
    // VibeManualRenderPump. Non-nil exactly while manual rendering is active,
    // which is what manualRenderingActive answers from.
    VibeManualRenderPump    *_manualPump;
#endif
}

#pragma mark - Init

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName delegate:(id <AudioPlayerDelegate>)delegate {
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _pendingRequest = [PlaybackRequestCoordinator new];
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

#if DEBUG
            // --no-audio-hw, for testing: put the engine in manual rendering
            // mode so it never opens a CoreAudio output device. Starting the
            // hardware IO — even with the mixer muted — counts as the Mac
            // playing audio, which is enough for macOS to yank auto-switching
            // AirPods over from another device mid-test. In manual mode the
            // graph, scheduling, fades, FX, completions and position all
            // behave normally; startManualRenderPumpOnQueue below pulls
            // frames at real-time pace and discards them. Must be enabled
            // while the engine is stopped and before the graph is wired.
            BOOL noAudioHW = [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
            BOOL manualRendering = NO;
            if (noAudioHW) {
                NSError *manualError = nil;
                AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                                             channels:2];
                manualRendering = [self->_engine
                        enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                           format:renderFormat
                                maximumFrameCount:kVibeManualPumpMaxFrames
                                            error:&manualError];
                if (!manualRendering) {
                    // The engine will open the output device as it always
                    // does; pair --no-audio-hw with --silent, as launch.sh
                    // does, and playback at least stays inaudible.
                    LogError(@"AudioPlayer: --no-audio-hw manual rendering unavailable (%@)", manualError);
                }
            }
#endif

            // The FX segment — low kill, and the reverb and delay returns —
            // owns everything between the main mixer and the output node.
            // See AudioFX.
            [self->_fx installInEngine:self->_engine];

#if DEBUG
            if (manualRendering) {
                self->_manualPump = [[VibeManualRenderPump alloc]
                        initWithEngine:self->_engine queue:self->_queue];
                LogInfo(@"AudioPlayer: --no-audio-hw, manual rendering, no output device");
            }
            // --silent, for testing: zero the main mixer so that playback
            // runs normally but nothing audible reaches the output device,
            // which still gets opened and driven — use --no-audio-hw to keep
            // hardware untouched. It sits downstream of all fade ramps, which
            // are player-node volumes, and upstream of the FX returns, so wet
            // tails are silenced too. It must run after installInEngine:,
            // because a mixer volume written before the node is attached and
            // wired is silently dropped. See AudioFX.m.
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
#if DEBUG
    [_manualPump cancel];
#endif
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
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(position, startPaused);
    uint64_t submittedPlayIdentifier;
    os_unfair_lock_lock(&_stateLock);
    submittedPlayIdentifier = ++_nextSubmittedPlayIdentifier;
    _lastSubmittedPlayIdentifier = submittedPlayIdentifier;
    _lastSubmittedPlayTrack = track;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self playOnQueue:track intent:intent declick:declick
   submittedPlayIdentifier:submittedPlayIdentifier];
    });
}

- (void)playOnQueue:(AudioTrack *)track
              intent:(VibePendingPlaybackIntent)intent
             declick:(BOOL)declick
submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    NSString *path = track.url.path;
    // Attempted only inside Loading, because rebindTrack: MUTATES the request
    // it matches: outside this branch the mutation would be made and then
    // thrown away by the beginWithTrack: below.
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequestRebind rebind = [_pendingRequest rebindTrack:track
                                                                   path:path
                                                                 intent:intent
                                                submittedPlayIdentifier:submittedPlayIdentifier];
        if (rebind.matched) {
            // This exact file is already loading, with its open in flight. Do
            // not start another open: that would strand a second blocked
            // worker and, on a slow file, flash a spurious timeout error
            // before the first one completes. Do rebind the delivery to the
            // new track object, though. A re-drop replaces the playlist with
            // fresh AudioTrack instances, and completing with the old one
            // would orphan the open's result. This runs before any teardown,
            // so re-clicking the loading row is a true no-op rather than a
            // generation bump plus a varispeed swap whose in-flight open then
            // plays through a needlessly rebuilt chain.
            VibePlaybackRequest *request = _pendingRequest.currentRequest;
            [self mirrorLoadingRequest:request
              clearingSubmittedPlayIdentifier:submittedPlayIdentifier];
            if (rebind.shouldNotifySlowLoad) {
                [self notifyDidBeginLoadingForRequest:request];
            }
            if (rebind.shouldNotifyLoadingPaused) {
                [self notifyLoadingPausedForRequest:request];
            }
            return;
        }
    }

    _pendingDeclick = declick;
    _segmentGeneration++;
    [self preemptRampsOnQueue]; // preempt any in-flight resume fade-in
    // Any armed splice dies with the node this play retires; the retiring
    // node's fading tail may graze the queued segment's first frames for the
    // declick length, which is inaudible at that volume. Remembered before the
    // clear: the graze reasoning holds only at declick length, so a queued
    // segment forces the retire below down to it (see the crossfade decision).
    BOOL segmentWasQueued = _gaplessQueued;
    [self clearGaplessOnQueue];

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
    // lands in finishPlayOnQueueWithFile:error:openRequestId:.
    // A queued splice segment forces the declick minimum even when the
    // crossfade setting was raised after it was armed: a crossfade-length
    // retire would let the queued file start sounding on the retiring node
    // mid-crossfade, doubled under the incoming track. (Raising the setting
    // normally unqueues via setCrossfadeMilliseconds:, but a play can land in
    // that hook's async window.)
    BOOL replacingAudibleTrack = (oldNode != nil && _engine.isRunning
                                  && _state == VibePlayerStatePlaying);
    _incomingFadeMilliseconds = VibeIncomingFadeMilliseconds(self.crossfadeMilliseconds,
                                                             replacingAudibleTrack,
                                                             _pendingDeclick,
                                                             segmentWasQueued);
    os_unfair_lock_lock(&_stateLock);
    _node = nil;
    os_unfair_lock_unlock(&_stateLock);

    AVAudioUnitVarispeed *newVarispeed = [[AVAudioUnitVarispeed alloc] init];
    [_engine attachNode:newVarispeed];
    _varispeed = newVarispeed; // finishPlayOnQueueWithFile: connects its incoming node through this

    // The retire fades the outgoing side out while the incoming node fades in
    // concurrently on the new varispeed, in finishPlayOnQueueWithFile: — an audible,
    // true crossfade.
    [self retireNode:oldNode varispeed:oldVarispeed milliseconds:_incomingFadeMilliseconds];

    self.currentTrack = nil;

    LogDebug(@"play file: %@", path);

    uint64_t openId = [_pendingRequest beginWithTrack:track
                                                   path:path
                                                 intent:intent
                                  submittedPlayIdentifier:submittedPlayIdentifier];

    // Enter the loading state: no node or file yet, but a play is committed.
    // This clears the previous track's file and position, so the UI stops
    // showing a stale duration and position for up to the full open timeout.
    // publishPlaybackState: has already mirrored the request, so this only has
    // to retire the pre-Loading handoff a seek would otherwise still aim at.
    [self publishPlaybackState:VibePlayerStateLoading node:nil file:nil segmentStart:0 position:0];
    [self clearSubmittedPlayIdentifier:submittedPlayIdentifier];

    // A prefetched handle for this exact path skips the open entirely, and the
    // transition goes straight to schedule and play. Ownership passes to the
    // normal finish path with a fresh open id, so it consumes that id like any
    // completed open, and no timeout or loading-indicator timers ever exist.
    if (_prefetchedFile && [path isEqualToString:_prefetchedPath]) {
        AVAudioFile *prefetchedFile = _prefetchedFile;
        _prefetchedFile = nil;
        _prefetchedPath = nil;
        _prefetchedTrack = nil;
        [self finishPlayOnQueueWithFile:prefetchedFile error:nil openRequestId:openId];
        return;
    }

    // Open the file off-queue. An iCloud or Dropbox placeholder blocks the
    // open until it materializes, and that must never wedge the player queue.
    // The request id pairs each open with its timeout: whichever fires first
    // consumes the id, and the other becomes a no-op.
    NSURL *openURL = track.url;
    __weak AudioPlayer *weakSelf = self;
    // Always open on our own user-initiated worker, even when a prefetch open
    // for this exact path is still in flight: that worker runs at utility QoS,
    // and a block already executing cannot be boosted. Both workers deliver
    // into finishPlayOnQueueWithFile:, which consumes the open id, so the loser no-ops
    // (see prefetchOnQueue:). The prefetch claim stays unconsumed, so its
    // completion can still deliver first, or park the handle if it loses.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        // Empty paths never reach the open: it would leak a descriptor
        // (NSURL+AudioOpen). A nil file lands on the same failure path.
        AVAudioFile *file = openURL.isEmptyOrDirectory
                ? nil
                : [[AVAudioFile alloc] initForReading:openURL error:&error];
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            dispatch_async(strongSelf->_queue, ^{
                [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
            });
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFileOpenTimeoutSeconds * NSEC_PER_SEC)), _queue, ^{
        [weakSelf fileOpenTimedOutForRequest:openId];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSlowOpenIndicatorDelaySeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            VibePlaybackRequest *request = [strongSelf->_pendingRequest markSlowForRequest:openId];
            if (request) {
                [strongSelf notifyDidBeginLoadingForRequest:request];
            }
        }
    });
}

- (void)finishPlayOnQueueWithFile:(AVAudioFile *)file error:(NSError *)error openRequestId:(uint64_t)openId {
    VibePlaybackRequest *request = [_pendingRequest consumeRequest:openId];
    if (!request) {
        return; // Superseded by a newer play, or already timed out.
    }
    AudioTrack *track = request.track;
    VibePendingPlaybackIntent startIntent = request.intent;
    NSTimeInterval startPosition = startIntent.position;
    BOOL startPaused = startIntent.paused;
    _pendingDeclick = NO;

    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error, track.url)];
        return;
    }

    AVAudioPlayerNode *node = [self attachConnectedNodeForFormat:file.processingFormat
            failureDescription:[NSString stringWithFormat:@"Could not play %@ (unsupported format)",
                                track.url.lastPathComponent]
                           url:track.url];
    if (!node) {
        return;
    }

    double sampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition startFrame = VibeClampedStartFrame(startPosition, sampleRate, file.length);
    NSTimeInterval framePosition = (NSTimeInterval)startFrame / sampleRate;

    [self scheduleFile:file onNode:node fromFrame:startFrame];
    node.volume = 0; // fade in from silence (see the ramp below)

    if (startPaused) {
        // A scheduled, silent, never-played node is exactly what a pause
        // leaves behind, so playPause's resume branch takes it from here.
        [self publishPlaybackState:VibePlayerStatePaused node:node file:file
                      segmentStart:startFrame position:framePosition];
        // Paused is idle; see completePauseOfNode:. The engine may be running
        // from the track this one replaced, and nothing else will stop it.
        [self scheduleEngineIdleStopOnQueue];
    }
    else {
        NSError *startError = nil;
        if (![self startEngineAndPlayNode:node error:&startError]) {
            [self abandonNodeAfterFailedStart:node
                           failureDescription:@"Could not start audio engine"
                                        error:startError
                                          url:track.url];
            return;
        }

        [self publishPlaybackState:VibePlayerStatePlaying node:node file:file
                      segmentStart:startFrame position:framePosition];

        // Fade the new track in from silence: its first frame is rarely a zero
        // crossing, so starting at full volume clicks. It reuses the current
        // ramp generation rather than a fresh one, so it rises in step with the
        // outgoing track's fade-out — a real crossfade — and neither ramp
        // cancels the other. The length matches that fade-out (playOnQueue:),
        // and the curve follows the length, so both sides ride equal power.
        [self rampNodeAsync:node step:1 from:0 to:1.0
               milliseconds:(_incomingFadeMilliseconds ?: kFadeDurationMilliseconds)
                 generation:_rampGeneration completion:nil];
    }

    self.currentTrack = track;
    track.duration = self.duration;
    run_on_main_thread({
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

- (void)fileOpenTimedOutForRequest:(uint64_t)openId {
    VibePlaybackRequest *request = [_pendingRequest consumeRequest:openId];
    if (!request) {
        return; // The open landed in time, or a newer play superseded it.
    }
    // Clear this so the file stays retryable: a later play of it starts a
    // fresh open. The original worker may stay blocked on a truly hung mount,
    // leaking one worker, but the loading no-op has already absorbed any rapid
    // re-clicks.
    AudioTrack *track = request.track;
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

- (BOOL)isGaplessArmed {
    os_unfair_lock_lock(&_stateLock);
    BOOL armed = _gaplessArmedForUI;
    os_unfair_lock_unlock(&_stateLock);
    return armed;
}

// Marks playback fully stopped after a failure, so that isPlaying and duration
// report reality and the play button can recover.
- (void)resetToStoppedStateOnQueue {
    // Invalidate any in-flight open. After an unrelated failure resets to
    // Stopped — a device switch failing mid-Loading, say — a still-pending
    // open must not land later and start playback out of an errored or stopped
    // UI. The request's unique identifier makes every late delivery a no-op.
    [_pendingRequest invalidate];
    _pendingDeclick = NO;
    [self clearGaplessOnQueue]; // any queued segment died with the node
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

- (void)segmentDidCompleteWithGeneration:(uint64_t)generation {
    if (generation != _segmentGeneration) {
        return; // Stale: a stop, seek, skip or device switch superseded this segment.
    }
    if (_gaplessQueued) {
        // Not an end: the next track's segment is queued behind this one and
        // already sounding. Splice, don't tear down.
        [self promoteGaplessOnQueue];
        return;
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
    // Un-armed material (format mismatch, crossfade on) dies with the node;
    // the next track's play re-acquires through its own prefetch.
    [self clearGaplessOnQueue];
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
    // Snapshot the caller's intent: a gapless boundary can promote the next
    // track before the block runs, and finishing then would end the track the
    // skip meant to *reach* — one skip landing two tracks ahead. (The
    // mid-fade flavor of the same race is caught by the _file check below.)
    AudioTrack *intendedTrack = self.currentTrack;
    dispatch_async(_queue, ^{
        if (self.currentTrack != intendedTrack) {
            return; // the boundary already advanced playback; the skip's goal is met
        }
        os_unfair_lock_lock(&self->_stateLock);
        VibePlayerState state = self->_state;
        AVAudioPlayerNode *node = self->_node;
        AVAudioFile *file = self->_file;
        os_unfair_lock_unlock(&self->_stateLock);
        // Only a live track can finish. Stopped has nothing to do, and Loading
        // has no node yet, so both are no-ops. The skip path never reaches
        // here while loading anyway, since the duration is 0.
        if (state != VibePlayerStatePlaying && state != VibePlayerStatePaused) {
            return;
        }
        uint64_t rampGen = [self preemptRampsOnQueue];
        if (state == VibePlayerStatePlaying && node && self->_engine.isRunning) {
            // A natural end is already silent, but this path can arrive at
            // full volume, on a forward skip past the end, so fade first or
            // the bare [node stop] clicks. The fade is the generation-tagged
            // ramp, so transport during the window preempts the pending
            // finish cleanly: a pause pauses in place instead of advancing,
            // and a new play retires the node with a single volume driver.
            // The node is still _node here, so every preemptor takes it over
            // and preemption cannot strand it audible. _segmentGeneration is
            // deliberately not bumped until the finish lands: a cancelled
            // finish leaves the scheduled segment's completion live, so the
            // natural track end still fires after a resume.
            __weak AudioPlayer *weakSelf = self;
            [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
                AudioPlayer *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                // Preempted — a play, pause, seek, stop or device switch owns
                // playback now — or the track ended naturally mid-fade and
                // finishPlaybackOnQueue already ran and cleared _node. Either
                // way this finish must not fire: didFinishPlaying: is
                // exactly-once, and the node's teardown belongs to whoever
                // superseded it.
                if (rampGen != strongSelf->_rampGeneration || strongSelf->_node != node) {
                    return;
                }
                if (strongSelf->_file != file) {
                    // The boundary promoted mid-fade: the splice already
                    // advanced playback into the next track, which is what
                    // this skip wanted. Finishing now would kill the promoted
                    // track and advance a second time; instead restore the
                    // volume the fade took.
                    [strongSelf rampNodeAsync:node step:1 from:node.volume to:1.0
                                   generation:rampGen completion:nil];
                    return;
                }
                // [node stop] inside finishPlaybackOnQueue fires the scheduled
                // segment's completion; bump so it reads as stale.
                strongSelf->_segmentGeneration++;
                [strongSelf finishPlaybackOnQueue];
            }];
            return;
        }
        self->_segmentGeneration++; // the [node stop] below fires the segment's completion
        [self finishPlaybackOnQueue];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        [self stopOnQueue];
    });
}

- (void)stopOnQueue {
    _segmentGeneration++; // drop the scheduled segment's stop-fired completion
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
            VibePlaybackRequest *request = [self->_pendingRequest togglePause];
            if (request) {
                [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
                [self notifyLoadingPausedForRequest:request];
            }
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
    // The unclamped rendered position, read before [node pause] stops
    // playerTime reporting; see _pausedRawPosition.
    NSTimeInterval rawPosition = position;
    @try {
        AVAudioTime *nodeTime = node.lastRenderTime;
        AVAudioTime *playerTime = nodeTime ? [node playerTimeForNodeTime:nodeTime] : nil;
        double sampleRate = _file.processingFormat.sampleRate;
        if (playerTime && playerTime.sampleTimeValid && sampleRate > 0) {
            rawPosition = (NSTimeInterval)(_segmentStartFrame + playerTime.sampleTime) / sampleRate;
        }
    }
    @catch (NSException *exception) {
    }
    [node pause];
    [self publishPlaybackState:VibePlayerStatePaused node:node file:_file segmentStart:_segmentStartFrame position:position];
    _pausedRawPosition = rawPosition; // after the publish, which resets it to the clamped value
    // Paused is idle: without this the engine renders silence and holds the
    // output device for as long as the user stays paused. Resume restarts it
    // through startEngineAndPlayNode:, which also dissolves this pending stop.
    [self scheduleEngineIdleStopOnQueue];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

#pragma mark - Properties

#if DEBUG
- (BOOL)manualRenderingActive {
    return _manualPump != nil;
}

- (NSDictionary<NSString *, NSNumber *> *)debugEngineCounts {
    // Reading these off the queue would race every attach, detach and fade
    // retirement, which is exactly the code these numbers are meant to audit.
    // The same-queue guard mirrors dealloc's: a caller already on _queue would
    // deadlock.
    NSDictionary *(^counts)(void) = ^NSDictionary *{
        return @{@"attachedNodes": @(self->_engine.attachedNodes.count),
                 @"retiredFades": @(self->_retiredFades.count)};
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == kAudioPlayerQueueKey) {
        return counts();
    }
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        result = counts();
    });
    return result;
}
#endif

- (BOOL)isPlaying {
    os_unfair_lock_lock(&_stateLock);
    BOOL playing = (_state == VibePlayerStatePlaying
            || (_state == VibePlayerStateLoading && !_loadingStartPaused));
    os_unfair_lock_unlock(&_stateLock);
    return playing;
}

- (BOOL)isPaused {
    os_unfair_lock_lock(&_stateLock);
    BOOL paused = (_state == VibePlayerStatePaused
            || (_state == VibePlayerStateLoading && _loadingStartPaused));
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

#pragma mark - Crossfade

// Manual accessors so the write can keep the armed splice honest: raising the
// setting past the declick minimum unqueues an armed segment (the user now
// wants overlapped transitions, and playOnQueue:'s graze reasoning only holds
// at declick length), and lowering it back re-arms parked material that a
// closed gate left dormant.
@synthesize crossfadeMilliseconds = _crossfadeMilliseconds;

- (NSInteger)crossfadeMilliseconds {
    os_unfair_lock_lock(&_stateLock);
    NSInteger milliseconds = _crossfadeMilliseconds;
    os_unfair_lock_unlock(&_stateLock);
    return milliseconds;
}

- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds {
    os_unfair_lock_lock(&_stateLock);
    _crossfadeMilliseconds = milliseconds;
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        if (VibeGaplessArmAllowed(milliseconds)) {
            if (!self->_gaplessFile && self->_prefetchedFile && self->_prefetchedTrack) {
                // A raise dropped the splice material outright, so lowering
                // must reacquire the second handle off the parked prefetch;
                // maybeArmGaplessOnQueue alone only re-arms dormant material.
                [self maybeOpenGaplessFileForTrack:self->_prefetchedTrack
                                    prefetchedFile:self->_prefetchedFile];
            }
            [self maybeArmGaplessOnQueue];
        }
        else if (self->_gaplessQueued) {
            [self unscheduleGaplessOnQueue];
        }
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

// Both halves in one critical section: the loading mirror a main-thread getter
// reads, and the retirement of the pre-Loading handoff, which only the play
// that set it may clear — a newer play submitted since owns it now.
- (void)mirrorLoadingRequest:(VibePlaybackRequest *)request
    clearingSubmittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    _loadingTrack = request.track;
    _loadingStartPaused = request.intent.paused;
    _loadingSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    if (_lastSubmittedPlayIdentifier == submittedPlayIdentifier) {
        _lastSubmittedPlayIdentifier = 0;
        _lastSubmittedPlayTrack = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (void)clearSubmittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    if (_lastSubmittedPlayIdentifier == submittedPlayIdentifier) {
        _lastSubmittedPlayIdentifier = 0;
        _lastSubmittedPlayTrack = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (void)notifyDidBeginLoadingForRequest:(VibePlaybackRequest *)request {
    AudioTrack *track = request.track;
    run_on_main_thread({
        [self.delegate audioPlayer:self didBeginLoading:track];
    });
}

- (void)notifyLoadingPausedForRequest:(VibePlaybackRequest *)request {
    AudioTrack *track = request.track;
    BOOL paused = request.intent.paused;
    run_on_main_thread({
        [self.delegate audioPlayer:self didChangeLoadingPaused:paused forTrack:track];
    });
}

// The single writer for the whole playback and position state, in one lock
// acquisition, so the main-thread getters never observe a torn combination
// such as a new state carrying the old track's position. A caller whose
// operation leaves a field untouched passes the current value through. The
// epoch bump is structural: the position getter computes off-lock and writes
// _lastValidPosition back only if its snapshotted epoch is still current.
//
// A few sites write _state or _node alone under the lock without coming
// through here. That is safe only because they never move the position fields;
// any write that does must use this publisher.
- (void)publishPlaybackState:(VibePlayerState)state
                        node:(AVAudioPlayerNode *)node
                        file:(AVAudioFile *)file
                segmentStart:(AVAudioFramePosition)segmentStart
                    position:(NSTimeInterval)position {
    VibePlaybackRequest *request = state == VibePlayerStateLoading
            ? _pendingRequest.currentRequest : nil;
    os_unfair_lock_lock(&_stateLock);
    _node = node;
    _file = file;
    _segmentStartFrame = segmentStart;
    _pausedPosition = position;
    _pausedRawPosition = position; // completePauseOfNode: overrides with the unclamped value
    _lastValidPosition = position;
    _positionEpoch++;
    _state = state;
    if (state == VibePlayerStateLoading) {
        _loadingTrack = request.track;
        _loadingStartPaused = request.intent.paused;
        _loadingSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    }
    else {
        _loadingTrack = nil;
        _loadingStartPaused = NO;
        _loadingSubmittedPlayIdentifier = 0;
    }
    os_unfair_lock_unlock(&_stateLock);
}

- (void)sendDelegateError:(NSError *)error {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

@end
