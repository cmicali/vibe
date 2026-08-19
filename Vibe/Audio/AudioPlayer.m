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
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
// The HAL device layer is macOS-only; iOS routing is AVAudioSession's, handled
// in the app layer (Audio/iOS/AudioSessionController).
#if TARGET_OS_OSX
#import "AudioPlayer+Devices.h"
#import "AudioDeviceManager.h"
#import "AudioDevice.h"
#import "CoreAudioUtil.h"
#endif
#import "AudioFileOpenTimeoutMath.h"
#import "PlaybackDeliveryRules.h"
#import "FadeMath.h"
#import "GaplessSpliceMath.h"
#import "PlaybackRequestCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <os/lock.h>

#if DEBUG
@interface AudioLevelPublisher (AudioPlayerDebugPrivate)
- (NSDictionary<NSString *, NSNumber *> *)debugState;
@end
#endif

// Descriptions are NOT localized: every consumer is a log site. The UI status
// comes from VibeStatusForPlayError (AudioErrorRules.h), which maps the error
// code and localizes there, once for both platforms.
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

// How long a file open may block before the play request is abandoned is
// AudioFileOpenTimeoutMath.h's monotonic deadline: a 60s no-progress baseline
// and 60s of silence after positive movement, configurable for diagnostics.

// An open still pending after this long is worth a visible loading state.
static const NSTimeInterval kSlowOpenIndicatorDelaySeconds = 0.5;

#if TARGET_OS_IOS
// Keeps iOS recovery's last-rendered playhead current when the screen's UI
// timer is dormant. This reads render time without mutating the engine.
static const NSTimeInterval kRecoveryPositionSampleIntervalSeconds = 0.5;
#endif

// Default pitch fader range in percent: ±8%, matching a stock SL-1200.
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so synchronous helpers can tell whether
// they already run on this exact player's queue. A process can briefly own two
// players during lifecycle tests or replacement.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

@interface AudioPlayer ()
- (void)cancelPlayOpenOnQueue;
- (void)cancelPlayOpenForRequest:(uint64_t)openId;
- (void)pauseOnQueue;
- (void)resumeOnQueue;
- (void)cancelPendingPauseOnQueue;
#if TARGET_OS_IOS
- (void)scheduleRecoveryPositionSampleForGeneration:(uint64_t)generation;
#endif
@end

// The state a category also touches is in AudioPlayerInternal.h; what follows
// is private to this file.
@implementation AudioPlayer {
    float                   _maxPitch;
    // Forces the declick minimum on this play's crossfade — the convert
    // swap's same-audio replace. Rides with the pending request.
    BOOL                    _pendingDeclick;
    // The fade-in length for the play in flight: the user-set crossfade when
    // it replaced an audibly playing track, the declick minimum otherwise.
    // Written by playOnQueue: alongside the matching retire, read by
    // finishPlayOnQueueWithFile:error:openRequestId:'s fade-in. Queue-confined.
    uint64_t                _incomingFadeMilliseconds;
    AudioLoadingConfiguration *_loadingConfiguration;
    id                      _configChangeObserver;
#if DEBUG
    // --no-audio-hw's stand-in for the HAL IO thread; see
    // VibeManualRenderPump. Non-nil exactly while manual rendering is active,
    // which is what manualRenderingActive answers from.
    VibeManualRenderPump    *_manualPump;
#endif
}

#pragma mark - Init

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate {
    return [self initWithDeviceUID:deviceUID
                              name:deviceName
                          enableFX:enableFX
                          delegate:delegate
              loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID
                              name:(NSString *)deviceName
                          enableFX:(BOOL)enableFX
                          delegate:(id<AudioPlayerDelegate>)delegate
              loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _pendingRequest = [PlaybackRequestCoordinator new];
        _maxPitch = kDefaultMaxPitchPercent;
        _crossfadeMilliseconds = kFadeDurationMilliseconds;
        _loadingConfiguration = [loadingConfiguration copy];
        // Meaningful before the async init block resolves the saved device:
        // -1 means follow the system default, rather than a bogus device id 0.
        self.currentlyRequestedAudioDeviceId = -1;
        // Default QoS, not user-initiated. This queue owns the engine graph
        // and calls blocking AVAudioEngine APIs — [node stop], detachNode:,
        // engine start and stop — which wait on the engine's internal
        // graph-reconfiguration thread, itself at Default QoS. A
        // user-initiated queue blocking on that lower-QoS thread is a priority
        // inversion, which the Thread Performance Checker flagged on the skip
        // teardown. Matching Default removes it. The latency-critical file
        // open runs on the coordinator's bounded user-initiated lane (see
        // playOnQueue:), so leaving control-plane scheduling at Default costs
        // nothing perceptible.
        _queue = dispatch_queue_create("com.vibe.audioplayer",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        dispatch_queue_set_specific(_queue, kAudioPlayerQueueKey,
                                    (__bridge void *)self, NULL);
        // Created before the async engine init so that fx is non-nil from the
        // caller's first moment. Intent set early, by a key press or the BPM
        // feed, is recorded and applied when installInEngine: runs below.
        // Without enableFX it stays nil forever: no FX node is ever minted,
        // and installMasterBusOnQueue wires the mixer straight to the output.
        _fx = enableFX ? [[AudioFX alloc] initWithQueue:_queue] : nil;
        _retiredFades = [NSMutableArray array];
        _prefetchAcknowledgementState = VibeAudioPrefetchAcknowledgementStateMake();
        _levelNormalizationMode = kLevelDefaultNormalizationMode;
        _levelPublisher = [[AudioLevelPublisher alloc] init];
#if TARGET_OS_OSX
        _pendingSavedDeviceUID = [deviceUID copy] ?: @"";
        _pendingSavedDeviceName = [deviceName copy] ?: @"";
#endif
        self.delegate = delegate;
        dispatch_async(_queue, ^{

            LogDebug(@"AudioPlayer init");

            [self createEngineAndMasterBusOnQueue];

#if TARGET_OS_OSX
            AudioDeviceManager *deviceManager = [AudioDeviceManager sharedInstance];
            [deviceManager addObserver:self];

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
            // Do not put first-use HAL discovery on the player's sole queue.
            // The engine begins honestly on System Output; a successful async
            // snapshot later applies the saved preference through the checked
            // device-switch path, and an absent device remains pending.
            [self resolvePendingSavedOutputDeviceOnQueue];
#endif
            // On iOS there is no HAL device layer: routing belongs to
            // AVAudioSession, and engine-config-change handling lives with the
            // session observer in the iOS app layer.

            run_on_main_thread({
                [self.delegate audioPlayerDidInitialize:self];
            });

        });
    }
    return self;
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    dispatch_block_t apply = ^{
        self->_loadingConfiguration = [loadingConfiguration copy];
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        apply();
    }
    else {
        dispatch_sync(_queue, apply);
    }
}

- (AudioLoadingConfiguration *)loadingConfiguration {
    __block AudioLoadingConfiguration *configuration;
    dispatch_block_t read = ^{
        configuration = self->_loadingConfiguration;
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        read();
    }
    else {
        dispatch_sync(_queue, read);
    }
    return configuration;
}

// Runs on _queue. Creates the engine and wires the master bus, applying the
// debug argv flags exactly as first init does. The iOS media-services rebuild
// calls this too, so a rebuilt engine comes back in the same mode — without
// that, --no-audio-hw's pump would render against a non-manual engine, and a
// --silent run would turn audible after a reset.
- (void)createEngineAndMasterBusOnQueue {
    _engine = [[AVAudioEngine alloc] init];

#if DEBUG
    // --no-audio-hw, for testing: put the engine in manual rendering mode so
    // it never opens a CoreAudio output device. Starting the hardware IO —
    // even with the mixer muted — counts as the Mac playing audio, which is
    // enough for macOS to yank auto-switching AirPods over from another device
    // mid-test. In manual mode the graph, scheduling, fades, FX, completions
    // and position all behave normally; the pump below pulls frames at
    // real-time pace and discards them. Must be enabled while the engine is
    // stopped and before the graph is wired.
    BOOL noAudioHW = [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
    BOOL manualRendering = NO;
    if (noAudioHW) {
        NSError *manualError = nil;
        AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100.0
                                                                                     channels:2];
        manualRendering = [_engine
                enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                   format:renderFormat
                        maximumFrameCount:kVibeManualPumpMaxFrames
                                    error:&manualError];
        if (!manualRendering) {
            // The engine will open the output device as it always does; pair
            // --no-audio-hw with --silent, as launch.sh does, and playback at
            // least stays inaudible.
            LogError(@"AudioPlayer: --no-audio-hw manual rendering unavailable (%@)", manualError);
        }
    }
#endif

    [self installMasterBusOnQueue];

#if DEBUG
    if (manualRendering) {
        // TRAP: the pump binds its engine at init, so a rebuild needs a fresh
        // one — the old pump would render against the engine that just died.
        [_manualPump cancel];
        _manualPump = [[VibeManualRenderPump alloc] initWithEngine:_engine queue:_queue];
        LogInfo(@"AudioPlayer: --no-audio-hw, manual rendering, no output device");
    }
    // --silent, for testing: zero the main mixer so that playback runs
    // normally but nothing audible reaches the output device, which still gets
    // opened and driven — use --no-audio-hw to keep hardware untouched. It
    // sits downstream of all fade ramps, which are player-node volumes, and
    // upstream of the FX returns, so wet tails are silenced too. It must run
    // after the master bus is wired, because a mixer volume written before the
    // mixer is attached and wired is silently dropped. See AudioFX.m.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--silent"]) {
        _engine.mainMixerNode.outputVolume = 0;
        LogInfo(@"AudioPlayer: --silent, output muted");
    }
#endif
}

// Wires the master bus — everything from the main mixer to the output — on a
// fresh engine: the FX segment when FX is enabled, otherwise a direct
// mixer -> output connection. The explicit connect stands in for the implicit
// one AVAudioEngine makes on mainMixerNode access, so the wiring is the same
// deterministic step in both configurations. Runs on _queue; the engine init
// and the iOS media-services-reset rebuild are the callers.
- (void)installMasterBusOnQueue {
    if (_fx) {
        [_fx installInEngine:_engine];
    }
    else {
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode
                  format:[_engine.mainMixerNode outputFormatForBus:0]];
    }
    // TRAP: the level tap must be (re)installed HERE and nowhere else. This
    // method is what the iOS media-services rebuild re-runs, so a tap installed
    // anywhere else dies with the old engine and never comes back — no error,
    // no log, the bars simply stop moving. Binding it here also re-reads the
    // sample rate, which a reset is free to change.
    [self applyLevelTapOnQueue];
}

// Runs on _queue. Reconciles the tap with the queue-side intent, which is the
// only thing either caller has to get right.
- (void)applyLevelTapOnQueue {
    if (_levelsWanted && _engine && !_levelTap && _levelPublisher) {
        // Whatever feeds the output, which is the only place the bars can
        // follow what is actually heard: the FX segment's sum when there is
        // one, and the mixer itself when there is not. Tapping the mixer
        // unconditionally would miss every reverb and delay tail, since those
        // returns re-enter downstream of it.
        AVAudioNode *tapNode = _fx.masterBusOutputNode ?: _engine.mainMixerNode;
        _levelTap = [[AudioLevelTap alloc] initWithNode:tapNode
                                              publisher:_levelPublisher
                                       normalizationMode:_levelNormalizationMode];
    }
    else if (!_levelsWanted && _levelTap) {
        [_levelTap remove];
        _levelTap = nil;
    }
}

- (void)setLevelsEnabled:(BOOL)levelsEnabled {
    if (_levelsEnabled == levelsEnabled) {
        return;
    }
    _levelsEnabled = levelsEnabled;
    // The intent crosses to the queue as a captured value rather than as a
    // read of the main-thread property from the block.
    dispatch_async(_queue, ^{
        self->_levelsWanted = levelsEnabled;
        [self applyLevelTapOnQueue];
    });
}

- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence {
    return [_levelPublisher copyLevels:out count:count sequence:sequence];
}

// Runs on _queue. Forgets every reference bound to the current engine without
// messaging it — the caller may hold a defunct engine whose graph must not be
// touched, as after an iOS media-services reset (see AudioPlayer+Recovery.m).
// Emptying the retired-fade registry halts the steppers; the open, prefetch
// and gapless state goes because a parked AVAudioFile — the prefetched handle
// and the splice's private one alike — dies with the media server.
- (void)dropEngineBoundStateOnQueue {
    [_retiredFades removeAllObjects];
    _varispeed = nil;
    // Abandoned rather than removed: removeTapOnBus: would message a node
    // belonging to the engine this method exists to stop touching. The rebuild
    // installs a fresh tap from installMasterBusOnQueue.
    [_levelTap abandon];
    _levelTap = nil;
    // refreshOutputAudioActiveOnQueue begins by asking _engine.isRunning.
    // Drop the invalid engine first so that refresh and the following Stopped
    // publication message nil, never the media server's dead object.
    _engine = nil;
    _retiredOutputGeneration++;
    _activeRetiredOutputCount = 0;
    [self refreshOutputAudioActiveOnQueue];
    // Neither transfer has a consumer any more — the deliveries below are
    // invalidated by identifier, and the file handles they would produce died
    // with the media server. A download is not engine-bound state, so nothing
    // else here reaches it, and left alone it pulls a whole file down for a
    // play that can never land. Same pair stop cancels.
    [self cancelPlayOpenOnQueue];
    [self clearPrefetchOnQueue];
    // Every in-flight open dies with the media server; the coordinator's
    // identifier makes each late delivery a no-op, exactly as on the reset
    // path.
    [_pendingRequest invalidate];
    _pendingDeclick = NO;
    [self clearGaplessOnQueue];
}

- (void)dealloc {
    if (_configChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_configChangeObserver];
    }
#if DEBUG
    [_manualPump cancel];
#endif
#if TARGET_OS_OSX
    [[AudioDeviceManager sharedInstance] removeObserver:self];
#endif
    // Engine mutation belongs on _queue, as everywhere else. dispatch_sync
    // from here cannot deadlock against in-flight queue work: a queued block
    // either holds a strongSelf, in which case the retain count is nonzero and
    // dealloc is not running, or resolves its weakSelf to nil and returns
    // without dispatching anywhere, and run_on_main_thread is async besides.
    // The one remaining hazard is dealloc itself running on _queue, when a
    // queued block releases the last reference, so that case tears down
    // inline.
    AudioLevelTap *levelTap = _levelTap;
    _levelTap = nil;
    AVAudioPlayerNode *node = _node;
    AVAudioEngine *engine = _engine;
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        [levelTap remove];
        [node stop];
        [engine stop];
    }
    else {
        dispatch_sync(_queue, ^{
            [levelTap remove];
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
    // The pre-submit edge: synchronous, outside the state lock, and ahead of
    // the queue dispatch, so the shell's background-download hold is asserted
    // before the open it protects can start. This is the only delegate send
    // not marshalled to main — it rides play:'s own calling thread.
    [self.delegate audioPlayer:self willSubmitPlayForTrack:track];
    // TRAP: identifier minting and queue admission are one ordering edge.
    // Media-reset receipt takes the same lock around its queue admission, so
    // a play cannot be identified on one side of the reset and execute on the
    // other. The queue block may briefly wait for this lock to be released;
    // it never holds the queue while asking another thread to acquire it.
    os_unfair_lock_lock(&_stateLock);
    uint64_t submittedPlayIdentifier = ++_nextSubmittedPlayIdentifier;
    _lastSubmittedPlayIdentifier = submittedPlayIdentifier;
    _lastSubmittedPlayTrack = track;
    dispatch_async(_queue, ^{
        [self playOnQueue:track intent:intent declick:declick
   submittedPlayIdentifier:submittedPlayIdentifier];
    });
    os_unfair_lock_unlock(&_stateLock);
}

- (void)playOnQueue:(AudioTrack *)track
              intent:(VibePendingPlaybackIntent)intent
             declick:(BOOL)declick
submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    NSString *path = track.url.path;
    // Every explicit play submission retires the successor request belonging
    // to the playback context it superseded. This precedes same-path rebind,
    // which returns early below but is still a newer submission.
    [self terminallyRetirePrefetchRequestOnQueue];
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

    _activeSubmittedPlayIdentifier = 0;

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

    // Detach the previous play from its path claim and cancel any still-
    // abortable materialization. If AVAudioFile has already blocked in the OS,
    // the coordinator keeps the claim until it returns instead of losing track
    // of it and multiplying workers on later requests.
    [self cancelPlayOpenOnQueue];

    // A park from the previous playlist neighborhood must not compete with
    // the foreground provider transfer. A same-path park stays to race it.
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySubmission
                              playPath:path];

    // A prefetched handle for this exact path skips the open entirely, and the
    // transition goes straight to schedule and play. Ownership passes to the
    // normal finish path with a fresh open id, so it consumes that id like any
    // completed open, and no timeout or loading-indicator timers ever exist.
    // No materializer is minted: there is nothing left to download.
    if (_prefetchedFile && [path isEqualToString:_prefetchedPath]) {
        AVAudioFile *prefetchedFile = _prefetchedFile;
        [self clearPrefetchOnQueue];
        [self finishPlayOnQueueWithFile:prefetchedFile error:nil openRequestId:openId];
        return;
    }

    // Open through the bounded interactive lane. The request id still pairs
    // the logical open with its deadline, while the coordinator owns the
    // underlying standardized-path claim until an uncancellable OS call really
    // returns.
    NSURL *openURL = track.url;
    _playOpenRequestId = openId;
    _openTimeoutSnapshot = _loadingConfiguration.openTimeouts;
    _openSubmittedUptime = NSProcessInfo.processInfo.systemUptime;
    _openLastPositiveMovementUptime = 0;
    __weak AudioPlayer *weakSelf = self;
    _playOpenToken = [[AudioFileOpenCoordinator sharedCoordinator]
            openURL:openURL
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_queue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval openSeconds) {
        // An open that outran the loading indicator's own threshold was a
        // materialization, near enough. How long the provider took is the one
        // number that explains a slow start, and nothing else records it.
        if (!file) {
            LogInfo(@"Open of %@ abandoned after %.1fs (%@)", openURL.lastPathComponent,
                    openSeconds, error.localizedDescription);
        }
        else if (openSeconds >= kSlowOpenIndicatorDelaySeconds) {
            LogInfo(@"Opened %@ in %.1fs", openURL.lastPathComponent, openSeconds);
        }
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(_openTimeoutSnapshot.noProgressSeconds * NSEC_PER_SEC)), _queue, ^{
        [weakSelf fileOpenDeadlineDueForRequest:openId];
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
    // The prefetch worker can win this request while its dedicated play claim
    // is still open. Whichever completion wins consumes the request and
    // detaches that claim; an identifier guard protects a newer play.
    [self cancelPlayOpenForRequest:openId];
    // If the interactive open won its same-path prefetch race, retire the
    // loser before a late result can make the new current track its successor.
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySettlement
                              playPath:request.path];
    AudioTrack *track = request.track;
    VibePendingPlaybackIntent startIntent = request.intent;
    NSTimeInterval startPosition = startIntent.position;
    BOOL startPaused = startIntent.paused;
    _pendingDeclick = NO;

    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
        return;
    }

    AVAudioPlayerNode *node = [self attachConnectedNodeForFormat:file.processingFormat];
    if (!node) {
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not play %@ (unsupported format)",
                                           track.url.lastPathComponent], nil, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
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
            [self abandonNodeAfterFailedStart:node];
            [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                    @"Could not start audio engine", startError, track.url)
                   forSubmittedPlay:request.submittedPlayIdentifier];
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
    _activeSubmittedPlayIdentifier = request.submittedPlayIdentifier;
    track.duration = self.duration;
    if ([self submittedPlayIsCurrent:request.submittedPlayIdentifier]) {
        [self playbackDidSucceedForPrefetchOnQueue];
    }
    else {
        [self terminallyRetirePrefetchRequestOnQueue];
    }
    // Dropped for a superseded submission, for the same reason its error is:
    // the shell's own guard compares the track, and a replay of the SAME row
    // is the same AudioTrack, so a start that belongs to the previous play
    // reads as current. Acting on it re-runs didStartPlaying:'s whole tail —
    // including the successor prefetch whose acknowledgement releases the
    // metadata materialization hold, stamped with the NEWER play's generation because that
    // play was submitted while this callback was still travelling. The
    // background lane then resumes against an open the user is still waiting
    // on. Measured: a background download beginning 15ms into it.
    uint64_t settledPlay = request.submittedPlayIdentifier;
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:settledPlay]) {
            LogInfo(@"Dropping didStartPlaying for superseded play %llu", settledPlay);
            return;
        }
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

// One logical deadline: the firing checks the effective deadline against the
// progress the open has shown, re-arms itself for the remainder when a sample
// has pushed it out, and abandons only when genuinely due. Progress can only
// extend (AudioFileOpenTimeoutMath.h), so re-arming never shortens anything, and a
// stale firing for a superseded or landed open fails the identifier check
// before it can read another request's stamps.
- (void)fileOpenDeadlineDueForRequest:(uint64_t)openId {
    VibePlaybackRequest *pending = _pendingRequest.currentRequest;
    if (!pending || pending.identifier != openId) {
        return; // The open landed in time, or a newer play superseded it.
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval remaining = VibeAudioOpenDeadlineRemaining(
            now, _openSubmittedUptime, _openLastPositiveMovementUptime,
            _openTimeoutSnapshot);
    if (remaining > 0) {
        __weak AudioPlayer *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), _queue, ^{
            [weakSelf fileOpenDeadlineDueForRequest:openId];
        });
        return;
    }
    VibePlaybackRequest *request = [_pendingRequest consumeRequest:openId];
    if (!request) {
        return;
    }
    [self cancelPlayOpenForRequest:openId];
    // If materialization was still running it is cancelled. If the worker had
    // entered AVAudioFile, its path claim stays registered until that call
    // returns, and a same-path retry rebinds to it.
    AudioTrack *track = request.track;
    // Useful in the log, but not a recovery instruction: a timeout never
    // changes metadata priority or continues playback intent behind the error.
    BOOL madeProgress = _openLastPositiveMovementUptime > _openSubmittedUptime;
    LogError(@"Timed out opening %@ (progress seen: %@)", track.url.path,
             madeProgress ? @"yes" : @"no");
    [self resetToStoppedStateOnQueue];
    NSError *timedOut = VibeAudioErrorForTrack(VibeAudioErrorFileOpenTimedOut,
            [NSString stringWithFormat:@"Timed out opening %@ — it may still be downloading from iCloud/Dropbox or the network may be unavailable",
                                       track.url.lastPathComponent], nil, track.url);
    [self sendDelegateError:timedOut forSubmittedPlay:request.submittedPlayIdentifier];
}

- (void)noteOpenProgressForOpenRequestIdentifier:(uint64_t)openRequestIdentifier {
    if (!openRequestIdentifier) {
        return;
    }
    dispatch_async(_queue, ^{
        VibePlaybackRequest *pending = self->_pendingRequest.currentRequest;
        if (!pending || pending.identifier != openRequestIdentifier
                || self->_playOpenRequestId != openRequestIdentifier) {
            return;
        }
        self->_openLastPositiveMovementUptime = NSProcessInfo.processInfo.systemUptime;
    });
}

- (void)prefetchTrack:(AudioTrack *)track {
    [self prefetchTrack:track whenClaimed:nil];
}

- (void)prefetchTrack:(AudioTrack *)track whenClaimed:(void (^)(void))claimed {
    // The acknowledgement always bounces to main, whichever prefetch branch
    // acks it, so the shell's hold release runs where the hold lives.
    void (^ackOnMain)(void) = claimed ? ^{
        run_on_main_thread({
            claimed();
        });
    } : nil;
    dispatch_async(_queue, ^{
        AudioTrack *target = VibeAudioPrefetchDepthAllowsSuccessor(
                self->_loadingConfiguration.prefetchDepth) ? track : nil;
        [self prefetchOnQueue:target whenClaimed:ackOnMain];
    });
}

// Marks playback fully stopped after a failure, so that isPlaying and duration
// report reality and the play button can recover.
- (void)resetToStoppedStateOnQueue {
    // Invalidate any in-flight open. After an unrelated failure resets to
    // Stopped — a device switch failing mid-Loading, say — a still-pending
    // open must not land later and start playback out of an errored or stopped
    // UI. The request's unique identifier makes every late delivery a no-op.
    [_pendingRequest invalidate];
    _activeSubmittedPlayIdentifier = 0;
    [self cancelPlayOpenOnQueue];
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtAbandonment
                              playPath:nil];
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
#if TARGET_OS_OSX
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
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
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_OSX
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
    [self scheduleEngineIdleStopOnQueue];
    // Snapshot before dispatching. If the track has changed by the time the
    // block runs on main, this end event is stale and must be dropped.
    AudioTrack *track = self.currentTrack;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    _activeSubmittedPlayIdentifier = 0;
    run_on_main_thread({
        if (!track || self.currentTrack != track
                || ![self submittedPlayIsCurrent:owningSubmittedPlayIdentifier]) {
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
    // Supersede every open and park, publish Stopped, then schedule the engine
    // idle stop which releases the output device.
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
        if (self->_state == VibePlayerStatePlaying) {
            if (self->_pausePending) {
                // A second press during the pause fade-out cancels the pending
                // pause and ramps back up. There is no delegate event, because
                // didPause never fired and the UI never left the playing
                // state.
                [self cancelPendingPauseOnQueue];
            }
            else {
                [self pauseOnQueue];
            }
            return;
        }
        else if (self->_state == VibePlayerStatePaused) {
            [self resumeOnQueue];
            return;
        }
        [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
    });
}

- (void)pause {
    dispatch_async(_queue, ^{
        [self pauseOnQueue];
    });
}

- (void)resume {
    dispatch_async(_queue, ^{
        [self resumeOnQueue];
    });
}

// Explicit desired-state transport. Unlike playPause, duplicate calls are
// no-ops, and the decision is made beside the mutable state on _queue rather
// than from a caller's stale snapshot.
- (void)pauseOnQueue {
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequest *request = [_pendingRequest setPausedIfChanged:YES];
        if (request) {
            [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
            [self notifyLoadingPausedForRequest:request];
        }
        return;
    }
    if (_state != VibePlayerStatePlaying || _pausePending) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    if (!node) {
        return;
    }
    uint64_t rampGen = [self preemptRampsOnQueue]; // cancel any in-flight resume fade-in
    // A pause must silence a crossfade's outgoing tail too, not just the
    // current node.
    [self preemptRetiredFadesOnQueue];
    // Fade out asynchronously, then pause in the completion. The queue must
    // not block for the fade, or a skip or seek issued right behind a pause
    // would stall behind it. The state stays Playing through the fade, because
    // the node really is still rendering.
    _pausePending = YES;
    __weak AudioPlayer *weakSelf = self;
    [self rampNodeAsync:node step:1 from:node.volume to:0 generation:rampGen completion:^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // This runs on _queue, and in every case including preemption, so the
        // pending flag can be cleared unconditionally.
        strongSelf->_pausePending = NO;
        // A preempted ramp still reaches this completion (see rampNodeAsync:),
        // so the node and state checks alone are not enough. Resume and seek
        // both bump _rampGeneration while leaving node and state untouched,
        // and pausing under them would fight the operation that now owns
        // volume and state.
        if (rampGen != strongSelf->_rampGeneration
                || strongSelf->_node != node || strongSelf->_state != VibePlayerStatePlaying) {
            return; // A play, stop, seek, resume or device switch superseded the pause.
        }
        [strongSelf completePauseOfNode:node];
    }];
}

- (void)resumeOnQueue {
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequest *request = [_pendingRequest setPausedIfChanged:NO];
        if (request) {
            [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
            [self notifyLoadingPausedForRequest:request];
        }
        return;
    }
    if (_state == VibePlayerStatePlaying) {
        // The state remains Playing during the pause fade. An explicit resume
        // arriving in that window owns the desired state and dissolves it.
        [self cancelPendingPauseOnQueue];
        return;
    }
    if (_state != VibePlayerStatePaused || !_node) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    NSError *startError = nil;
    if (![self startEngineAndPlayNode:node error:&startError]) {
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed,
                @"Could not resume playback", startError)
               forSubmittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    // Re-publish rather than changing _state alone, so iOS's player-owned
    // recovery sampler restarts when rendering resumes.
    [self publishPlaybackState:VibePlayerStatePlaying node:node file:_file
                  segmentStart:_segmentStartFrame position:self.pausedPosition];
    uint64_t rampGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didResumePlaying:track];
    });
}

- (void)cancelPendingPauseOnQueue {
    if (!_pausePending || !_node) {
        return;
    }
    AVAudioPlayerNode *node = _node;
    uint64_t rampGen = [self preemptRampsOnQueue];
    [self rampNodeAsync:node step:1 from:node.volume to:1.0 generation:rampGen completion:nil];
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

#pragma mark - Debug introspection

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
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        return counts();
    }
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        result = counts();
    });
    return result;
}

static NSString *VibeAudioLevelNormalizationModeName(
        VibeAudioLevelNormalizationMode normalizationMode) {
    switch (normalizationMode) {
        case VibeAudioLevelNormalizationModeBalancedSpectrum:
            return @"balanced";
        case VibeAudioLevelNormalizationModeSharedSpectrum:
            return @"spectrum";
        case VibeAudioLevelNormalizationModeRelativeActivity:
        default:
            return @"activity";
    }
}

- (void)debugSetEqualizerNormalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    if (normalizationMode != VibeAudioLevelNormalizationModeRelativeActivity
            && normalizationMode != VibeAudioLevelNormalizationModeSharedSpectrum
            && normalizationMode != VibeAudioLevelNormalizationModeBalancedSpectrum) {
        return;
    }
    void (^applyMode)(void) = ^{
        if (self->_levelNormalizationMode == normalizationMode) {
            return;
        }
        if (self->_levelTap) {
            [self->_levelTap remove];
            self->_levelTap = nil;
        }
        self->_levelNormalizationMode = normalizationMode;
        if (self->_levelsWanted) {
            [self applyLevelTapOnQueue];
        }
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        applyMode();
        return;
    }
    dispatch_sync(_queue, applyMode);
}

- (NSDictionary<NSString *, id> *)debugEqualizerState {
    NSDictionary *(^snapshot)(void) = ^NSDictionary *{
        NSMutableDictionary<NSString *, id> *state =
                [[self->_levelPublisher debugState] mutableCopy];
        state[@"requested"] = @(self->_levelsWanted);
        state[@"tapObject"] = @(self->_levelTap != nil);
        state[@"retiredOutputCount"] = @(self->_activeRetiredOutputCount);
        state[@"outputAudioActive"] = @(self.outputAudioActive);
        state[@"normalizationMode"] =
                VibeAudioLevelNormalizationModeName(self->_levelNormalizationMode);
        return state;
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        return snapshot();
    }
    __block NSDictionary *result = nil;
    dispatch_sync(_queue, ^{
        result = snapshot();
    });
    return result;
}
#endif

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

// The play token slot is queue-confined. The request-specific form is what
// completion and timeout use: a delayed terminus must never detach a newer
// play's waiter.
- (void)cancelPlayOpenOnQueue {
    [_playOpenToken cancel];
    _playOpenToken = nil;
    _playOpenRequestId = 0;
}

- (void)cancelPlayOpenForRequest:(uint64_t)openId {
    if (_playOpenRequestId == openId) {
        [self cancelPlayOpenOnQueue];
    }
}

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
    uint64_t openRequestIdentifier = request.identifier;
    uint64_t submittedPlayIdentifier = request.submittedPlayIdentifier;
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping didBeginLoading for superseded play %llu",
                    submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self
                  didBeginLoading:track
            openRequestIdentifier:openRequestIdentifier];
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
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_IOS
    uint64_t recoveryPositionGeneration = ++_recoveryPositionGeneration;
    if (state == VibePlayerStatePlaying) {
        [self scheduleRecoveryPositionSampleForGeneration:recoveryPositionGeneration];
    }
#endif
}

// Output liveness is deliberately narrower than transport intent. Loading has
// no current node, but remains active while a retired crossfade is audibly
// finishing; a pause stays active through its fade because the state remains
// Playing until [node pause] lands. AudioFX does not expose wet-tail lifetime,
// so claiming one here would be a timer-shaped guess rather than actual state.
- (void)refreshOutputAudioActiveOnQueue {
    BOOL active = _engine.isRunning
            && ((_state == VibePlayerStatePlaying && _node != nil)
                || _activeRetiredOutputCount > 0);
    os_unfair_lock_lock(&_stateLock);
    BOOL changed = _outputAudioActive != active;
    _outputAudioActive = active;
    os_unfair_lock_unlock(&_stateLock);
    if (!changed) {
        return;
    }
    run_on_main_thread({
        id<AudioPlayerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(audioPlayer:didChangeOutputAudioActive:)]) {
            [delegate audioPlayer:self didChangeOutputAudioActive:active];
        }
    });
}

#if TARGET_OS_IOS
- (void)scheduleRecoveryPositionSampleForGeneration:(uint64_t)generation {
    __weak AudioPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(kRecoveryPositionSampleIntervalSeconds * NSEC_PER_SEC)), _queue, ^{
        AudioPlayer *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_recoveryPositionGeneration
                || strongSelf->_state != VibePlayerStatePlaying) {
            return;
        }
        // position stores only a valid playerTime result. If the engine has
        // already stopped, the cache remains the last frame sampled before it.
        (void)strongSelf.position;
        [strongSelf scheduleRecoveryPositionSampleForGeneration:generation];
    });
}
#endif

- (void)sendDelegateError:(NSError *)error {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

// Whether a submission is still the newest one. Delivery sites call it on main
// from inside their delivery block, because what matters there is whether a
// newer play had been submitted by the time the callback actually ran. The
// gapless park also reads it on _queue before starting successor work.
//
// TRAP: the counter is _nextSubmittedPlayIdentifier, which only ever
// increments, and NOT _lastSubmittedPlayIdentifier, which looks like the same
// thing and is not — that one is the pre-Loading handoff, cleared to 0 the
// moment its play reaches Loading, so comparing against it reports EVERY
// settlement as superseded.
- (BOOL)submittedPlayIsCurrent:(uint64_t)submittedPlayIdentifier {
    os_unfair_lock_lock(&_stateLock);
    uint64_t newest = _nextSubmittedPlayIdentifier;
    os_unfair_lock_unlock(&_stateLock);
    return VibePlaybackDeliveryIsCurrent(submittedPlayIdentifier, newest);
}

// The play-path variant: an error belonging to a submission a newer play has
// already replaced is dropped rather than delivered.
//
// TRAP: the delegate cannot make this judgement itself, and its existing
// guards look like they can. A play failure is published as Stopped and its
// error hops to main; if the user re-plays the SAME row in the window before
// that hop lands, the shell sees a matching URL and a player that has not yet
// published Loading for the replacement — because that happens on the player
// queue, one hop later — so every guard it has says the error is current. It
// then tears down state the newer play had just set up. Measured: the shell's
// metadata materialization hold released 11ms after the replay's own open began, and the
// background lane started downloading against it.
//
// The identifier is what settles it, and it is exact rather than heuristic: a
// re-drop of a file already loading REBINDS its request and adopts the new
// submission's identifier, so a rebound request still matches and its error is
// still delivered.
- (void)sendDelegateError:(NSError *)error forSubmittedPlay:(uint64_t)submittedPlayIdentifier {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping error for superseded play %llu", submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self error:error];
    });
}

@end
