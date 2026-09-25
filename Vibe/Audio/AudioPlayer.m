//
//  AudioPlayer.m
//  Vibe
//
//  The transport: the state machine {Stopped, Loading, Playing, Paused}, the
//  file open it waits on, and the delegate it reports to. Every verb below
//  publishes its new state and delivers its event at once; the audio follows
//  within the declick length, on the bus. Nothing here waits for a fade.
//

#import "AudioPlayer.h"
#import "AudioPlayerInternal.h"
#if DEBUG
#import "VibeManualRenderPump.h"
#import "AudioPlayer+Debug.h"
#endif
#import "AudioFX.h"
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
#if TARGET_OS_OSX
#import "AudioDeviceManager.h"
#import "CoreAudioUtil.h"
#endif
#import "AudioFileOpenTimeoutMath.h"
#import "PlaybackDeliveryRules.h"
#import "FadeMath.h"
#import <AVFAudio/AVFAudio.h>
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

// An open still pending after this long is worth a visible loading state.
static const NSTimeInterval kSlowOpenIndicatorDelaySeconds = 0.5;
// An open taking this long is worth recording, separately from the indicator
// delay above, which is a UI choice.
static const NSTimeInterval kSlowOpenLogThresholdSeconds = 0.25;
// Default pitch fader range in percent: ±8%, matching a stock SL-1200.
static const float kDefaultMaxPitchPercent = 8.0f;

// Queue-specific key marking _queue, so synchronous helpers can tell whether
// they already run on this exact player's queue.
static void *const kAudioPlayerQueueKey = (void *)&kAudioPlayerQueueKey;

@implementation AudioPlayer {
    float                   _maxPitch;
    AudioLoadingConfiguration *_loadingConfiguration;
}

#pragma mark - Init

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id <AudioPlayerDelegate>)delegate {
    return [self initWithDeviceUID:deviceUID name:deviceName enableFX:enableFX delegate:delegate
              loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID
                             name:(NSString *)deviceName enableFX:(BOOL)enableFX
                         delegate:(id <AudioPlayerDelegate>)delegate {
    return [self initWithDeviceUID:deviceUID modelUID:modelUID name:deviceName enableFX:enableFX delegate:delegate
              loadingConfiguration:[AudioLoadingConfiguration productionConfiguration] manualPump:nil];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID name:(NSString *)deviceName enableFX:(BOOL)enableFX
                         delegate:(id<AudioPlayerDelegate>)delegate
             loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    return [self initWithDeviceUID:deviceUID modelUID:@"" name:deviceName enableFX:enableFX delegate:delegate
             loadingConfiguration:loadingConfiguration manualPump:nil];
}

- (instancetype)initWithDeviceUID:(NSString *)deviceUID modelUID:(NSString *)modelUID name:(NSString *)deviceName
                         enableFX:(BOOL)enableFX delegate:(id<AudioPlayerDelegate>)delegate
             loadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration manualPump:(id)pump {
    NSParameterAssert(loadingConfiguration);
    self = [super init];
    if (self) {
        _stateLock = OS_UNFAIR_LOCK_INIT;
        _state = VibePlayerStateStopped;
        _pendingRequest = [PlaybackRequestCoordinator new];
        _maxPitch = kDefaultMaxPitchPercent;
        _crossfadeMilliseconds = kFadeDurationMilliseconds;
        _declick = YES;
        _loadingConfiguration = [loadingConfiguration copy];
        _retiringVoices = [NSMutableArray array];
        _renderLeaveWork = [NSMutableArray array];
        _retiredDecoderFiles = [NSCountedSet set];
        _prefetchRequestState = VibeAudioPrefetchRequestStateMake();
        _levelNormalizationMode = kLevelDefaultNormalizationMode;
        _levelPublisher = [[AudioLevelPublisher alloc] init];
        // Meaningful before the async init block resolves the saved device:
        // -1 means follow the system default, rather than a bogus device id 0.
        self.currentlyRequestedAudioDeviceId = -1;
        // Default QoS, not user-initiated: on iOS this queue calls blocking
        // AVAudioEngine APIs that wait on the engine's own
        // Default-QoS reconfiguration thread; a higher class would invert. The
        // latency-critical work — the file open and the decode — runs on its
        // own lanes.
        _queue = dispatch_queue_create("com.vibe.audioplayer",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0));
        dispatch_queue_set_specific(_queue, kAudioPlayerQueueKey, (__bridge void *)self, NULL);
        _manualPump = pump;
        // The bus exists for the player's life; every queue-side reader
        // dereferences it. TRAP: allocated in the async init below instead,
        // the render stall watcher's first tick, due at once on the queue,
        // ran first on a loaded machine and read the gate through NULL.
        _masterBus = VibeMasterBusCreate();
        // Keep the macOS controls and BPM feed stable across live toggles;
        // the FX nodes themselves are created only when first connected.
        _fxEnabled = enableFX;
        __weak AudioPlayer *weakPlayer = self;
        _fx = (enableFX || TARGET_OS_OSX) ? [[AudioFX alloc] initWithQueue:_queue scheduler:^(NSTimeInterval seconds, dispatch_block_t block) {
            [weakPlayer scheduleAfterSeconds:seconds block:block];
        } afterRenderLeaves:^(dispatch_block_t work) {
            AudioPlayer *player = weakPlayer;
            if (player) {
                [player afterRenderLeavesOnQueue:work];
            }
            else {
                work(); // no player, no pipeline, no render
            }
        }] : nil;
#if TARGET_OS_OSX
        _pendingSavedDeviceUID = [deviceUID copy] ?: @"";
        _pendingSavedDeviceModelUID = [modelUID copy] ?: @"";
        _pendingSavedDeviceName = [deviceName copy] ?: @"";
#endif
        self.delegate = delegate;
        if (!pump) {
            // The production player only: the render suites drive their own
            // clock and hold the queue on purpose.
            [self startStallWatchers];
        }
        dispatch_async(_queue, ^{
            LogDebug(@"AudioPlayer init");
            [self createOutputOnQueue];
            run_on_main_thread({
                [self.delegate audioPlayerDidInitialize:self];
            });
        });
    }
    return self;
}

- (NSArray<NSDictionary<NSString *, id> *> *)audioPathSnapshot {
    __block NSArray *path;
    [self runSyncOnQueue:^{ path = [self audioPathOnQueue]; }];
    return path;
}

- (BOOL)bitPerfectOnQueue {
#if TARGET_OS_OSX
    return _bitPerfectWanted;
#else
    return NO;
#endif
}

- (BOOL)drivesOutputDeviceOnQueue {
    return _manualPump == nil; // under the pump there is no carrier on either platform
}

// The one home for the same-queue guard every synchronous accessor needs.
- (void)runSyncOnQueue:(NS_NOESCAPE dispatch_block_t)block {
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        block();
        return;
    }
    dispatch_sync(_queue, block);
}

- (void)scheduleAfterSeconds:(NSTimeInterval)seconds block:(dispatch_block_t)block {
#if DEBUG
    if (_manualPump) {
        [(VibeManualRenderPump *)_manualPump scheduleAfter:seconds block:block];
        return;
    }
#endif
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), _queue, block);
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    [self runSyncOnQueue:^{
        self->_loadingConfiguration = [loadingConfiguration copy];
    }];
}

- (void)dealloc {
#if DEBUG
    [(VibeManualRenderPump *)_manualPump cancel];
#endif
#if TARGET_OS_OSX
    if (_outputLevelListener) {
        [CoreAudioUtil removeOutputLevelListener:_outputLevelListener queue:_queue forDeviceID:_preparedDeviceID];
    }
    if (_boundRateListener) {
        [CoreAudioUtil removeNominalRateListener:_boundRateListener queue:_queue forDeviceID:_boundRateDeviceID];
    }
    [[AudioDeviceManager sharedInstance] removeObserver:self];
#endif
    // Pipeline mutation belongs on _queue, as everywhere else. dispatch_sync
    // from here cannot deadlock against in-flight queue work: a queued block
    // either holds a strongSelf, in which case dealloc is not running, or
    // resolves its weakSelf to nil and returns. The one remaining hazard is
    // dealloc itself running on _queue, when a queued block releases the last
    // reference, so that case tears down inline. The carrier stops before the
    // pipeline is freed and the bus released with the rest of the ivars, so
    // no render is in flight — and one still inside leaks all of it, since
    // nothing a render is inside may be freed. Locals, not self: the open
    // tokens outlive the player otherwise, pulling a whole file down for a
    // play that can never land.
    AudioLevelMeter *levelMeter = _levelMeter;
    _levelMeter = nil;
    AudioVoiceBus *voiceBus = _voiceBus;
    AudioFX *fx = _fx;
    NSArray<dispatch_block_t> *renderLeaveWork = [_renderLeaveWork copy];
    _renderLeaveWork = nil;
#if TARGET_OS_OSX
    AudioOutputUnit *outputUnit = _outputUnit;
#else
    AVAudioEngine *engine = _engine;
#endif
    VibeMasterBus *masterBus = _masterBus;
    _masterBus = NULL;
    dispatch_source_t drainTimer = _drainTimer;
    _drainTimer = nil;
    AudioFileOpenToken *playOpenToken = _playOpenToken;
    _playOpenToken = nil;
    AudioFileOpenToken *prefetchOpenToken = _prefetchOpenToken;
    _prefetchOpenToken = nil;
    PlaybackRequestCoordinator *pendingRequest = _pendingRequest;
    dispatch_block_t teardown = ^{
        [playOpenToken cancel];
        [prefetchOpenToken cancel];
        [pendingRequest invalidate];
        [levelMeter remove];
        if (drainTimer) dispatch_source_cancel(drainTimer);
#if TARGET_OS_OSX
        [outputUnit stop]; // no cycle in flight before the pipeline it pulls is freed
#else
        [engine stop];
#endif
        if (VibeMasterBusRenderInside(masterBus)) {
            // Kept for the process's life: nothing a render is inside may be freed.
            LogError(@"AudioPlayer: a render is still inside the pipeline at teardown; the pipeline is leaked");
            static NSMutableArray *leaked;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ leaked = [NSMutableArray array]; });
            @synchronized (leaked) {
                [leaked addObject:@[renderLeaveWork, fx ?: NSNull.null, voiceBus ?: NSNull.null, levelMeter ?: NSNull.null]];
            }
            return;
        }
        for (dispatch_block_t work in renderLeaveWork) {
            work();
        }
        VibeMasterBusFree(masterBus);
    };
    if (dispatch_get_specific(kAudioPlayerQueueKey) == (__bridge void *)self) {
        teardown();
    }
    else {
        dispatch_sync(_queue, teardown);
    }
}

#pragma mark - Play

- (void)play:(AudioTrack *)track {
    [self playTrack:track atPosition:0 startPaused:NO declick:NO];
}

// Convert resumes the same audio in place; playlist removal uses this to land
// a replacement parked. Both declick rather than crossfade: the first would
// only dip identical audio, and the second should render nothing until resume.
- (void)play:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused {
    [self playTrack:track atPosition:position startPaused:startPaused declick:YES];
}

- (void)playTrack:(AudioTrack *)track atPosition:(NSTimeInterval)position startPaused:(BOOL)startPaused declick:(BOOL)declick {
    VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(position, startPaused);
    // TRAP: identifier minting and queue admission are one ordering edge.
    // Media-reset receipt takes the same lock around its queue admission, so
    // a play cannot be identified on one side of the reset and execute on the
    // other. The queue block may briefly wait for this lock to be released;
    // it never holds the queue while asking another thread to acquire it.
    os_unfair_lock_lock(&_stateLock);
    uint64_t submittedPlayIdentifier = ++_nextSubmittedPlayIdentifier;
    _lastSubmittedPlayIdentifier = submittedPlayIdentifier;
    _lastSubmittedPlayTrack = track;
    uint64_t submittedAt = [self noteSubmittedPlay:submittedPlayIdentifier track:track position:position paused:startPaused];
    dispatch_async(_queue, ^{
        [self noteAdmittedPlay:submittedPlayIdentifier submittedAt:submittedAt];
        [self playOnQueue:track intent:intent declick:declick submittedPlayIdentifier:submittedPlayIdentifier];
    });
    os_unfair_lock_unlock(&_stateLock);
}

// One play submission, as the ordered phases it is: retire the superseded
// successor request, try to rebind an identical in-flight play, retire the
// current voice, commit to Loading, supersede the previous open, then either
// consume a prefetched handle or admit a new one. The order is the
// correctness, so the constraints BETWEEN the phases are commented here,
// where the call sites are next to each other.
- (void)playOnQueue:(AudioTrack *)track intent:(VibePendingPlaybackIntent)intent declick:(BOOL)declick
submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_terminating) return;
    NSString *path = track.url.path;
    // Every explicit play submission retires the successor request belonging
    // to the playback context it superseded. This precedes the rebind, which
    // returns early but is still a newer submission.
    [self terminallyRetirePrefetchRequestOnQueue];
    // A parked play is a pause outcome: cut any older crossfade tail before
    // the same-path Loading rebind can return without touching the bus.
    if (intent.paused) {
        [self cutRetiringVoicesToDeclickOnQueue];
    }
    if ([self rebindLoadingPlayOnQueueForTrack:track path:path intent:intent
                       submittedPlayIdentifier:submittedPlayIdentifier]) {
        return;
    }
    _activeSubmittedPlayIdentifier = 0;
    // Before the state flips to Loading below: the retire's crossfade decision
    // asks whether it is replacing an AUDIBLY playing track, which Loading
    // would answer NO to.
    [self retireCurrentVoiceOnQueueWithDeclick:declick];
    self.currentTrack = nil;
    LogDebug(@"play file: %@", path);
    uint64_t openId = [_pendingRequest beginWithTrack:track path:path intent:intent
                                 submittedPlayIdentifier:submittedPlayIdentifier];
    // Enter the loading state: no voice or file yet, but a play is committed,
    // so the UI stops showing a stale duration and position for up to the
    // full open timeout. publishState: mirrors the request; this only has to
    // retire the pre-Loading handoff a seek would otherwise still aim at.
    [self publishState:VibePlayerStateLoading voice:0 file:nil startSeconds:0 baseFrames:0];
    [self clearSubmittedPlayIdentifier:submittedPlayIdentifier];
    // Detach the previous play from its path claim and cancel any still-
    // abortable materialization. A park from the previous playlist
    // neighborhood must not compete with the foreground provider transfer; a
    // same-path park stays.
    [self cancelPlayOpenOnQueue];
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySubmission playPath:path];
    // A parked handle for this exact path skips the open entirely: ownership
    // passes to the normal settlement with a fresh open id, and no timeout or
    // loading-indicator timers ever exist. Loading is published above either
    // way, so the fast path lands in the same state the slow one does.
    if (_prefetchedFile && [path isEqualToString:_prefetchedPath]) {
        AudioFileHandle *prefetchedFile = _prefetchedFile;
        [self clearPrefetchOnQueue];
        [self finishPlayOnQueueWithFile:prefetchedFile error:nil openRequestId:openId];
        return;
    }
    [self submitOpenOnQueueForTrack:track openRequestId:openId];
}

// Attempted only inside Loading, because rebindTrack: MUTATES the request it
// matches. YES means this play is fully handled: this exact file is already
// loading, with its open in flight, and starting another would strand a
// second blocked worker and, on a slow file, flash a spurious timeout error
// before the first completes. The delivery is rebound to the new track
// object, since a re-drop replaces the playlist with fresh instances.
- (BOOL)rebindLoadingPlayOnQueueForTrack:(AudioTrack *)track path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    if (_state != VibePlayerStateLoading) {
        return NO;
    }
    VibePlaybackRequestRebind rebind = [_pendingRequest rebindTrack:track path:path intent:intent
                                            submittedPlayIdentifier:submittedPlayIdentifier];
    if (!rebind.matched) {
        return NO;
    }
    VibePlaybackRequest *request = _pendingRequest.currentRequest;
    [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:submittedPlayIdentifier];
    if (rebind.shouldNotifySlowLoad) {
        [self notifyDidBeginLoadingForRequest:request];
    }
    if (rebind.shouldNotifyLoadingPaused) {
        [self notifyLoadingPausedForRequest:request];
    }
    return YES;
}

// The outgoing voice fades on its own while the incoming one fades in beside
// it — a true crossfade on one bus, with nothing rewired. Whether this play
// replaces an audibly playing track is the only case the user's crossfade
// length applies to; everything else fades at the declick minimum.
- (void)retireCurrentVoiceOnQueueWithDeclick:(BOOL)declick {
    BOOL replacingAudibleTrack = _voice != 0 && [self renderingOnQueue] && _state == VibePlayerStatePlaying;
    // A device's mode lands before main applies its dependent settings.
    declick |= [self bitPerfectOnQueue];
    _incomingFadeMilliseconds = VibeIncomingFadeMilliseconds(self.crossfadeMilliseconds, replacingAudibleTrack, declick);
    VibeVoiceID voice = [self unpublishVoiceOnQueue];
    [self retireVoiceOnQueue:voice milliseconds:_incomingFadeMilliseconds];
}

// Open through the bounded interactive lane, and arm the two timers that bound
// it. The request id pairs the logical open with its deadline; the coordinator
// owns the underlying standardized-path claim until an uncancellable OS call
// really returns.
- (void)submitOpenOnQueueForTrack:(AudioTrack *)track openRequestId:(uint64_t)openId {
    NSURL *openURL = track.url;
    _playOpenRequestId = openId;
    _openTimeoutSnapshot = _loadingConfiguration.openTimeouts;
    _openSubmittedUptime = NSProcessInfo.processInfo.systemUptime;
    _openLastPositiveMovementUptime = 0;
    __weak AudioPlayer *weakSelf = self;
    _playOpenToken = [[AudioFileMaterializationCoordinator sharedCoordinator]
            openURL:openURL purpose:VibeAudioFileOpenPurposePlayback completionQueue:_queue
            completion:^(AudioFileHandle *file, NSError *error, NSTimeInterval openSeconds) {
        // How long the provider took is the one number that explains a slow
        // start. Warn level so it persists for `log show`; always logged, so
        // "nothing appeared" can only mean the open did not happen.
        if (!file) {
            LogWarn(@"AudioPlayer: open of %@ abandoned after %.3fs (%@)",
                    openURL.lastPathComponent, openSeconds, error.localizedDescription);
        }
        else {
            BOOL slowOpen = openSeconds >= kSlowOpenLogThresholdSeconds;
            LogTiming(slowOpen, @"AudioPlayer: %@opened %@ in %.3fs",
                    slowOpen ? @"slowly " : @"", openURL.lastPathComponent, openSeconds);
        }
        AudioPlayer *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf finishPlayOnQueueWithFile:file error:error openRequestId:openId];
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_openTimeoutSnapshot.noProgressSeconds * NSEC_PER_SEC)), _queue, ^{
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

// The settlement: the file is open, the play still current. The source
// segment is made to fit the file, a voice starts fading in from silence,
// and the output runs unless the play was parked.
- (void)finishPlayOnQueueWithFile:(AudioFileHandle *)file error:(NSError *)error openRequestId:(uint64_t)openId {
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
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtPlaySettlement playPath:request.path];
    AudioTrack *track = request.track;
    VibePendingPlaybackIntent startIntent = request.intent;
    [self noteOpenSettledForPlay:request.submittedPlayIdentifier track:track file:file error:error];
    if (!file || file.length <= 0) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorFileOpenFailed,
                [NSString stringWithFormat:@"Could not open %@", track.url.lastPathComponent], error, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
        return;
    }
#if TARGET_OS_OSX
    [self ensureOutputUnitOnQueue]; // a unit made late brings its device's rate, before the segment is built at it
    // Gates itself on the mode. A format switch stops the output, which cuts
    // any declick still fading — a declick is what a cut in this mode costs.
    [self prepareOutputOnQueueForFile:file];
#endif
    // The iOS route's rate may have moved while nothing played; the
    // segment below is built at the route's rate, not a stale one.
    [self followOutputRouteOnQueue];
    if (![self ensureSourceSegmentOnQueueRebuilt:NULL]) {
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not play %@ (unsupported format)", track.url.lastPathComponent], nil, track.url)
               forSubmittedPlay:request.submittedPlayIdentifier];
        return;
    }
    double sampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition startFrame = VibeClampedStartFrame(startIntent.position, sampleRate, file.length);
    VibeVoiceID voice = [self startVoiceOnQueueForFile:file atFrame:startFrame
                                      fadeMilliseconds:(_incomingFadeMilliseconds ?: kFadeDurationMilliseconds)
                                                paused:startIntent.paused];
    if (startIntent.paused) {
        // A parked voice renders nothing until resumed. Paused is idle: the
        // output may be running from the track this one replaced, and nothing
        // else will stop it.
        [self publishState:VibePlayerStatePaused voice:voice file:file
              startSeconds:(NSTimeInterval)startFrame / sampleRate baseFrames:0];
        [self scheduleOutputIdleStopOnQueue];
    }
    else {
        NSError *startError = nil;
        if (![self startOutputOnQueue:&startError]) {
            [_voiceBus killVoice:voice];
            [self resetToStoppedStateOnQueue];
            [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                    @"Could not start audio engine", startError, track.url)
                   forSubmittedPlay:request.submittedPlayIdentifier];
            return;
        }
        [self publishState:VibePlayerStatePlaying voice:voice file:file
              startSeconds:(NSTimeInterval)startFrame / sampleRate baseFrames:0];
        [self armSignalProbeOnQueue:@"voice started"];
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
    // reads as current and re-runs didStartPlaying:'s whole tail, including
    // the successor prefetch that releases the metadata materialization hold.
    uint64_t settledPlay = request.submittedPlayIdentifier;
    uint64_t deliveredAt = [self deliveryStamp];
    run_on_main_thread({
        BOOL accepted = [self submittedPlayIsCurrent:settledPlay];
        [self noteDelivery:@"didStartPlaying" forPlay:settledPlay accepted:accepted deliveredAt:deliveredAt];
        if (!accepted) {
            LogInfo(@"Dropping didStartPlaying for superseded play %llu", settledPlay);
            return;
        }
        [self.delegate audioPlayer:self didStartPlaying:track];
    });
}

// One logical deadline: the firing checks the effective deadline against the
// progress the open has shown, re-arms itself for the remainder when a sample
// has pushed it out, and abandons only when genuinely due. Progress can only
// extend (AudioFileOpenTimeoutMath.h), and a stale firing for a superseded or
// landed open fails the identifier check before it can read another
// request's stamps.
- (void)fileOpenDeadlineDueForRequest:(uint64_t)openId {
    VibePlaybackRequest *pending = _pendingRequest.currentRequest;
    if (!pending || pending.identifier != openId) {
        return; // The open landed in time, or a newer play superseded it.
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval remaining = VibeAudioOpenDeadlineRemaining(now, _openSubmittedUptime,
                                                              _openLastPositiveMovementUptime, _openTimeoutSnapshot);
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
    // entered AudioFileHandle, its path claim stays registered until that call
    // returns, and a same-path retry rebinds to it.
    AudioTrack *track = request.track;
    BOOL madeProgress = _openLastPositiveMovementUptime > _openSubmittedUptime;
    LogError(@"Timed out opening %@ (progress seen: %@)", track.url.path, madeProgress ? @"yes" : @"no");
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

- (void)noteDisplayedPosition:(NSTimeInterval)position forTrack:(AudioTrack *)track {
    [self recordDisplayedPosition:position forTrack:track];
}

- (void)prefetchTrack:(AudioTrack *)track {
    dispatch_async(_queue, ^{
        AudioTrack *target = VibeAudioPrefetchDepthAllowsSuccessor(self->_loadingConfiguration.prefetchDepth) ? track : nil;
        [self prefetchOnQueue:target];
    });
}

#pragma mark - Pause and resume

- (void)playPause {
    uint64_t submittedAt = [self noteSubmittedAction:@"playPause" position:-1];
    dispatch_async(_queue, ^{
        [self noteAdmittedAction:@"playPause" submittedAt:submittedAt position:-1];
        switch (self->_state) {
            case VibePlayerStateLoading:
                [self applyEditedLoadingRequest:[self->_pendingRequest togglePause]];
                return;
            case VibePlayerStatePlaying:
                [self pauseOnQueue];
                return;
            case VibePlayerStatePaused:
                [self resumeOnQueue];
                return;
            case VibePlayerStateStopped:
                [self sendDelegateError:VibeAudioError(VibeAudioErrorNotPlaying, @"Nothing is playing", nil)];
                return;
        }
    });
}

- (void)pause {
    dispatch_async(_queue, ^{
        [self pauseOnQueue];
    });
}

- (void)resume {
    uint64_t submittedAt = [self noteSubmittedAction:@"resume" position:-1];
    dispatch_async(_queue, ^{
        [self noteAdmittedAction:@"resume" submittedAt:submittedAt position:-1];
        [self resumeOnQueue];
    });
}

// Explicit desired-state transport: duplicate calls are no-ops, and the
// decision is made beside the mutable state rather than from a caller's stale
// snapshot.
- (void)pauseOnQueue {
    if (_state == VibePlayerStateLoading) {
        [self applyEditedLoadingRequest:[_pendingRequest setPausedIfChanged:YES]];
        return;
    }
    if (_state != VibePlayerStatePlaying || !_voice) {
        return;
    }
    [self pauseCurrentVoiceOnQueue];
#if TARGET_OS_OSX
    // The first moment a pause is silent, and so the first moment a wanted
    // device that came back while audio was playing may be adopted.
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
}

// The voice fades to silence and stops consuming on the exact landing frame;
// the state is Paused now. Under a stopped output nothing renders, so the
// pause is a cut, which lands at the first render after any restart, before
// audio. A pause silences a crossfade's outgoing tail too.
- (void)pauseCurrentVoiceOnQueue {
    uint64_t milliseconds = [self renderingOnQueue] ? kFadeDurationMilliseconds : 0;
    [_voiceBus setRamp:[self rampOnQueueToGain:0 milliseconds:milliseconds action:VibeVoiceActionPause] forVoice:_voice];
    [self cutRetiringVoicesToDeclickOnQueue];
    [self publishState:VibePlayerStatePaused voice:_voice file:_file startSeconds:_voiceStartSeconds baseFrames:_promotedBaseFrames];
    // Paused is idle: without this the output renders silence and holds the
    // output device for as long as the user stays paused.
    [self scheduleOutputIdleStopOnQueue];
    AudioTrack *track = self.currentTrack;
    run_on_main_thread({
        [self.delegate audioPlayer:self didPausePlaying:track];
    });
}

- (void)resumeOnQueue {
    if (_state == VibePlayerStateLoading) {
        [self applyEditedLoadingRequest:[_pendingRequest setPausedIfChanged:NO]];
        return;
    }
    if (_state != VibePlayerStatePaused || !_voice) {
        return;
    }
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    // The carrier's rate may have moved while it was stopped (the iOS
    // route); the pipeline follows it first, re-voicing paused in place, so
    // the start below runs at the route's rate and the output converts nothing.
    if (![self followOutputRouteOnQueue]) {
        return; // the follow reset the player and said why
    }
#if TARGET_OS_OSX
    [self ensureOutputUnitOnQueue]; // a unit made late re-voices the parked voice at its device's rate first
#endif
    NSError *startError = nil;
    if (![self startOutputOnQueue:&startError]) {
        // startOutputOnQueue cancelled the pending idle stop at entry; the
        // state stays Paused, so re-arm it or a running output holds the
        // output device forever.
        [self scheduleOutputIdleStopOnQueue];
        [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed, @"Could not resume playback", startError)
               forSubmittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    [_voiceBus setRamp:[self rampOnQueueToGain:1 milliseconds:kFadeDurationMilliseconds action:VibeVoiceActionNone]
              forVoice:_voice];
    [self publishState:VibePlayerStatePlaying voice:_voice file:_file startSeconds:_voiceStartSeconds baseFrames:_promotedBaseFrames];
    [self armSignalProbeOnQueue:@"resume"];
    AudioTrack *track = self.currentTrack;
    uint64_t deliveredAt = [self deliveryStamp];
    run_on_main_thread({
        [self noteDelivery:@"didResumePlaying" forPlay:owningSubmittedPlayIdentifier
                  accepted:[self submittedPlayIsCurrent:owningSubmittedPlayIdentifier] deliveredAt:deliveredAt];
        [self.delegate audioPlayer:self didResumePlaying:track];
    });
}

- (BOOL)getPlaybackIntent:(VibePendingPlaybackIntent *)intent forTrack:(AudioTrack *)track {
    __block BOOL loaded = NO;
    [self runSyncOnQueue:^{
        if (self->_state == VibePlayerStateLoading) {
            VibePlaybackRequest *request = self->_pendingRequest.currentRequest;
            if (request && (!track || request.track == track)) {
                *intent = request.intent;
                loaded = YES;
            }
            return;
        }
        if ((!track || self.currentTrack == track)
                && (self->_state == VibePlayerStatePlaying || self->_state == VibePlayerStatePaused)) {
            *intent = VibePendingPlaybackIntentMake(self.position, self->_state == VibePlayerStatePaused);
            loaded = YES;
        }
    }];
    return loaded;
}

#pragma mark - Seek

// A seek is a new voice at the target and the old one fading out beside it:
// the one shape for playing and paused, with no reschedule and nothing to
// wait for. The caller computed the position against the track that is
// current NOW; a gapless boundary can promote the next track before the block
// below runs, so the intent is snapshotted and the seek dropped if the track
// moved on.
- (void)seekToPosition:(NSTimeInterval)position {
    uint64_t submittedAt = [self noteSubmittedAction:@"seek" position:position];
    AudioTrack *intendedTrack = self.currentTrack;
    uint64_t intendedSubmittedPlayIdentifier = 0;
    os_unfair_lock_lock(&_stateLock);
    if (self.lastSubmittedPlayTrack) {
        // A play is queued but has not reached the player queue yet, so
        // currentTrack still names the outgoing track. Aim at the play the
        // user just started — the row they are looking at.
        intendedTrack = self.lastSubmittedPlayTrack;
        intendedSubmittedPlayIdentifier = self.lastSubmittedPlayIdentifier;
    }
    else if (_state == VibePlayerStateLoading) {
        intendedTrack = self.loadingTrack;
        intendedSubmittedPlayIdentifier = self.loadingSubmittedPlayIdentifier;
    }
    os_unfair_lock_unlock(&_stateLock);
    dispatch_async(_queue, ^{
        [self seekOnQueueToPosition:position intendedTrack:intendedTrack
   intendedSubmittedPlayIdentifier:intendedSubmittedPlayIdentifier submittedAt:submittedAt];
    });
}

- (void)seekOnQueueToPosition:(NSTimeInterval)position intendedTrack:(AudioTrack *)intendedTrack
intendedSubmittedPlayIdentifier:(uint64_t)intendedSubmittedPlayIdentifier submittedAt:(uint64_t)submittedAt {
    [self noteAdmittedAction:@"seek" submittedAt:submittedAt position:position];
    AudioTrack *track = self.currentTrack;
    if (_state == VibePlayerStateLoading) {
        VibePlaybackRequest *request = _pendingRequest.currentRequest;
        [_pendingRequest seekToPosition:position ifCurrentTrackIs:intendedTrack
                submittedPlayIdentifier:intendedSubmittedPlayIdentifier];
        [self notifySeekFinishedOnQueue:request.track reason:@"loading intent" submittedPlay:self.loadingSubmittedPlayIdentifier];
        return;
    }
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    if (track != intendedTrack) {
        [self notifySeekFinishedOnQueue:track reason:@"ignored: track changed" submittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    if (!_voice || !_file) {
        [self notifySeekFinishedOnQueue:track reason:@"no playable voice" submittedPlay:owningSubmittedPlayIdentifier];
        return;
    }
    BOOL paused = _state == VibePlayerStatePaused;
    [self revoiceOnQueueAtPosition:position];
    if (!paused) {
        // Playing can carry a stopped output for the moment between a
        // configuration change and its recovery.
        NSError *startError = nil;
        if (![self startOutputOnQueue:&startError]) {
            [self pauseCurrentVoiceOnQueue];
            [self sendDelegateError:VibeAudioError(VibeAudioErrorEngineStartFailed, @"Could not resume playback after seek", startError)
                   forSubmittedPlay:owningSubmittedPlayIdentifier];
            [self notifySeekFinishedOnQueue:track reason:@"start failed, paused" submittedPlay:owningSubmittedPlayIdentifier];
            return;
        }
        [self armSignalProbeOnQueue:@"seek"];
    }
    [self maybeArmSuccessorOnQueue];
    [self notifySeekFinishedOnQueue:track reason:@"intent updated" submittedPlay:owningSubmittedPlayIdentifier];
}

// Every seek settles didFinishSeeking:, including a dropped one: the header
// promises it, and Control Center resyncs off it.
- (void)notifySeekFinishedOnQueue:(AudioTrack *)track reason:(NSString *)reason submittedPlay:(uint64_t)play {
    [self noteSettled:@"seek" reason:reason];
    uint64_t deliveredAt = [self deliveryStamp];
    run_on_main_thread({
        [self noteDelivery:@"didFinishSeeking" forPlay:play accepted:[self submittedPlayIsCurrent:play] deliveredAt:deliveredAt];
        [self.delegate audioPlayer:self didFinishSeeking:track];
    });
}

#pragma mark - Stop and finish

- (void)stop {
    dispatch_async(_queue, ^{
        [self stopOnQueue];
    });
}

- (void)stopOnQueue {
    self.currentTrack = nil;
    [self resetToStoppedStateOnQueue];
}

// Marks playback fully stopped after a failure or a stop, so that isPlaying
// and duration report reality and the play button can recover. The current
// voice goes with it, at the declick minimum, never the crossfade length: a
// stop lands immediately.
- (void)resetToStoppedStateOnQueue {
    VibeVoiceID voice = [self unpublishVoiceOnQueue];
    [self retireVoiceOnQueue:voice milliseconds:kFadeDurationMilliseconds];
    // Invalidate any in-flight open: after an unrelated failure resets to
    // Stopped, a still-pending open must not land later and start playback
    // out of an errored or stopped UI. The identifier makes every late
    // delivery a no-op.
    [_pendingRequest invalidate];
    _activeSubmittedPlayIdentifier = 0;
    [self cancelPlayOpenOnQueue];
    [self retirePrefetchOnQueueAtPoint:VibeAudioPrefetchAtAbandonment playPath:nil];
    [self clearSuccessorOnQueue];
    // Stop and every failure path land here — a crossfade whose incoming open
    // failed included — so the outgoing fade must not ring on for up to the
    // full crossfade length.
    [self cutRetiringVoicesToDeclickOnQueue];
    [self publishState:VibePlayerStateStopped voice:0 file:nil startSeconds:0 baseFrames:0];
#if TARGET_OS_OSX
    // A reset may be inside a device mutation whose rollback is still owed.
    // Do not retry a failed saved-device bind, even on a later queue turn.
    if (!_pendingSavedDeviceLookupInFlight && !_terminating) {
        dispatch_async(_queue, ^{ [self resolvePendingSavedOutputDeviceOnQueue]; });
    }
#endif
    // Release the output device once genuinely idle. A quick follow-up play,
    // such as auto-advance past a bad file, reuses the running output.
    [self scheduleOutputIdleStopOnQueue];
}

// Ends the current track as if it had played to its end. A gapless boundary
// can promote the next track before the block runs, and finishing then would
// end the track the skip meant to REACH — one skip landing two tracks ahead —
// so the intent is snapshotted on main.
- (void)finishCurrentTrack {
    AudioTrack *intendedTrack = self.currentTrack;
    dispatch_async(_queue, ^{
        if (self.currentTrack != intendedTrack) {
            return; // the boundary already advanced playback; the skip's goal is met
        }
        if (self->_state != VibePlayerStatePlaying && self->_state != VibePlayerStatePaused) {
            return; // Stopped has nothing to do; Loading has no voice yet.
        }
        [self finishPlaybackOnQueue];
    });
}

// The shared terminus for "the current track is done": the natural end, whose
// voice has already died and so retires as a no-op, and finishCurrentTrack,
// whose voice may be at full volume and fades. It marks the player Stopped and
// notifies the delegate, whose handler drives auto-advance or the
// end-of-playlist stop. The output stop is deferred so that the auto-advance
// play, which arrives within milliseconds, reuses the running output.
- (void)handleVoiceEventOnQueue:(VibeVoiceEvent)event voice:(VibeVoiceID)voice {
    BOOL current = voice == self->_voice;
    [self noteBusEvent:event voice:voice current:current];
    switch (event) {
        case VibeVoiceEventLive:
            break;
        case VibeVoiceEventBoundary:
            if (current) {
                [self promoteSuccessorOnQueue];
            }
            break;
        case VibeVoiceEventEnded:
            if (current) {
                [self currentVoiceEndedOnQueue:voice];
            }
            else if ([self->_retiringVoices containsObject:@(voice)]) {
                [self->_retiringVoices removeObject:@(voice)];
                if (self->_retiringVoices.count == 0) {
                    [self noteRetiringAudioSilentOnQueue];
                }
                [self refreshOutputAudioActiveOnQueue];
            }
            break;
    }
}

- (void)currentVoiceEndedOnQueue:(VibeVoiceID)voice {
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:voice];
    if (snapshot.ended == VibeVoiceEndFailed) {
        AudioFileHandle *failedFile = nil;
        NSError *failure = [_voiceBus errorOfVoice:voice failedFile:&failedFile];
        NSURL *failedURL = failure.userInfo[NSURLErrorKey];
        if (failedFile && failedFile != _file) {
            // The predecessor finished; a successor that never became current
            // cannot reset its submission or report an error against its row.
            [self clearSuccessorOnQueue];
            [self finishPlaybackOnQueue];
            return;
        }
        AudioTrack *track = self.currentTrack;
        uint64_t submittedPlay = _activeSubmittedPlayIdentifier;
        [self resetToStoppedStateOnQueue];
        [self sendDelegateError:VibeAudioErrorForTrack(VibeAudioErrorEngineStartFailed,
                [NSString stringWithFormat:@"Could not decode %@", track.url.lastPathComponent], failure, failedURL ?: track.url)
               forSubmittedPlay:submittedPlay];
        return;
    }
    [self finishPlaybackOnQueue];
}

- (void)finishPlaybackOnQueue {
    AudioTrack *track = self.currentTrack;
    uint64_t owningSubmittedPlayIdentifier = _activeSubmittedPlayIdentifier;
    VibeVoiceID voice = [self unpublishVoiceOnQueueEnteringTerminalState:VibePlayerStateStopped];
    [self retireVoiceOnQueue:voice milliseconds:kFadeDurationMilliseconds];
    [self refreshOutputAudioActiveOnQueue];
#if TARGET_OS_OSX
    [self resolvePendingSavedOutputDeviceOnQueue];
#endif
    [self scheduleOutputIdleStopOnQueue];
    // Snapshot before dispatching: if the track has changed by the time the
    // block runs on main, this end event is stale and must be dropped.
    _activeSubmittedPlayIdentifier = 0;
    uint64_t deliveredAt = [self deliveryStamp];
    run_on_main_thread({
        BOOL accepted = track && self.currentTrack == track && [self submittedPlayIsCurrent:owningSubmittedPlayIdentifier];
        [self noteDelivery:@"didFinishPlaying" forPlay:owningSubmittedPlayIdentifier accepted:accepted deliveredAt:deliveredAt];
        if (!accepted) {
            return;
        }
        [self.delegate audioPlayer:self didFinishPlaying:track];
    });
}

#pragma mark - Voices

// The one gain rule. Bit-perfect output ramps at most the declick: the
// crossfade setting is already held at the minimum under the mode, but a play
// submitted before the mode landed carries the length it was retired with,
// so the clamp lives here, at the funnel. With Declick off a declick-length
// ramp — every transport edge — is a cut, in either mode; a longer one is
// the user's crossfade, and fades.
- (VibeVoiceRamp)rampOnQueueToGain:(float)gain milliseconds:(uint64_t)milliseconds action:(VibeVoiceAction)action {
    if ([self bitPerfectOnQueue]) {
        milliseconds = MIN(milliseconds, kFadeDurationMilliseconds);
    }
    if (!self.declick && milliseconds <= kFadeDurationMilliseconds) {
        milliseconds = 0;
    }
    uint32_t frames = (uint32_t)VibeFadeFramesForMilliseconds(milliseconds, _voiceBus.format.sampleRate);
    return VibeVoiceRampMake(gain, frames, VibeFadeCurveForMilliseconds(milliseconds), action);
}

- (VibeVoiceID)startVoiceOnQueueForFile:(AudioFileHandle *)file atFrame:(AVAudioFramePosition)frame
                       fadeMilliseconds:(uint64_t)milliseconds paused:(BOOL)paused {
    VibeVoiceRamp ramp = [self rampOnQueueToGain:1 milliseconds:milliseconds action:VibeVoiceActionNone];
    VibeVoiceID voice = [_voiceBus startVoiceWithFile:file atFrame:frame
                                                 gain:ramp.frames ? 0 : 1
                                                 ramp:ramp
                                               paused:paused];
    [self noteVoiceStarted:voice file:file fromFrame:frame reason:paused ? @"parked" : @"started"];
    [self updateDrainTimerOnQueue];
    return voice;
}

// A new voice for the current file at `position`, the old one retiring at
// the declick beside it: the seek's shape, shared with an unqueue the decoder
// won, where only a new voice discards the successor frames already in the
// ring. Playing or paused alike; the published tuple moves with the voice.
// TRAP: the old voice retires before the new one starts. Both read the same
// AudioFileHandle, whose cursor the new voice's first decode turn positions; a
// turn of the old voice queued between the two calls reads after that and
// the new voice's next chunk starts 4096 frames late.
- (void)revoiceOnQueueAtPosition:(NSTimeInterval)position {
    AudioFileHandle *file = _file;
    double sampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition startFrame = VibeClampedStartFrame(position, sampleRate, file.length);
    VibeVoiceID oldVoice = [self unpublishVoiceOnQueue];
    [self retireVoiceOnQueue:oldVoice milliseconds:kFadeDurationMilliseconds];
    VibeVoiceID voice = [self startVoiceOnQueueForFile:file atFrame:startFrame
                                      fadeMilliseconds:kFadeDurationMilliseconds
                                                paused:_state == VibePlayerStatePaused];
    [self publishState:_state voice:voice file:file startSeconds:(NSTimeInterval)startFrame / sampleRate baseFrames:0];
}

// An audible voice fades out for `milliseconds` and dies; one that cannot be
// heard — not yet live, paused, cut with Declick off, or under a stopped
// output — is killed outright, since silence cannot click, and is silent at
// once, so only fading voices join _retiringVoices. The voice's own state
// decides, never the player's: finishPlaybackOnQueue has published Stopped
// by the time it retires the voice a skip past the end found at full volume,
// and a pause still fading is audible too. A declick-length retire, fading
// or cut, reads no more of its file, so the file may be handed to the next
// voice; a crossfade-length one keeps reading its own, never its successor.
- (void)retireVoiceOnQueue:(VibeVoiceID)voice milliseconds:(uint64_t)milliseconds {
    if (!voice) {
        return;
    }
    [_voiceBus unqueueSuccessorForVoice:voice];
    VibeVoiceSnapshot snapshot = [_voiceBus snapshotOfVoice:voice];
    if (snapshot.state != VibeVoiceStateArmed && snapshot.state != VibeVoiceStateLive) {
        return; // already dead: its end is the drain's to report, or has been
    }
    if (milliseconds <= kFadeDurationMilliseconds) {
        [_voiceBus stopReadingForVoice:voice];
    }
    VibeVoiceRamp ramp = [self rampOnQueueToGain:0 milliseconds:milliseconds action:VibeVoiceActionRetire];
    BOOL audible = snapshot.state == VibeVoiceStateLive && !snapshot.paused && [self renderingOnQueue] && ramp.frames > 0;
    if (!audible) {
        [_voiceBus killVoice:voice];
        return;
    }
    [_voiceBus setRamp:ramp forVoice:voice];
    [_retiringVoices addObject:@(voice)];
    [self refreshOutputAudioActiveOnQueue];
}

// Stop, pause, a parked play and the failure reset must not leave an outgoing
// track audible for up to the full crossfade. Skips never call this, so rapid
// skips keep the full fade-out.
- (void)cutRetiringVoicesToDeclickOnQueue {
    for (NSNumber *voice in _retiringVoices) {
        [_voiceBus setRamp:[self rampOnQueueToGain:0 milliseconds:kFadeDurationMilliseconds action:VibeVoiceActionRetire]
                  forVoice:voice.unsignedLongLongValue];
    }
}

#pragma mark - Crossfade and pitch

// Manual accessors so the write can keep the queued successor honest: raising
// the setting past the declick minimum unqueues it (the user now wants
// overlapped transitions), and lowering it back re-arms the park.
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
            [self maybeArmSuccessorOnQueue];
        }
        else if (self->_successorTrack) {
            [self unqueueSuccessorOnQueue];
        }
    });
}

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
    // The rate is an AU parameter, but touch the unit only on the player's
    // owning queue, as with every other graph mutation.
    dispatch_async(_queue, ^{
        [self applyPitchOnQueue:pitch];
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
    dispatch_async(_queue, ^{
        [self applyPitchOnQueue:pitch];
    });
}

#pragma mark - Levels

- (void)setLevelsEnabled:(BOOL)levelsEnabled {
    if (_levelsEnabled == levelsEnabled) {
        return;
    }
    _levelsEnabled = levelsEnabled;
    // The intent crosses to the queue as a captured value rather than as a
    // read of the main-thread property from the block.
    dispatch_async(_queue, ^{
        self->_levelsWanted = levelsEnabled;
        [self applyLevelMeterOnQueue];
    });
}

- (BOOL)copyBandLevels:(float *)out count:(NSUInteger)count sequence:(uint64_t *)sequence {
    return [_levelPublisher copyLevels:out count:count sequence:sequence];
}

#pragma mark - The open slot and the loading mirror

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
- (void)mirrorLoadingRequest:(VibePlaybackRequest *)request clearingSubmittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
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

// A pause or resume during Loading edits the request's landing intent; nil
// means the edit changed nothing and nothing is told.
- (void)applyEditedLoadingRequest:(VibePlaybackRequest *)request {
    if (!request) {
        return;
    }
    [self mirrorLoadingRequest:request clearingSubmittedPlayIdentifier:0];
    [self notifyLoadingPausedForRequest:request];
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
            LogInfo(@"Dropping didBeginLoading for superseded play %llu", submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self didBeginLoading:track openRequestIdentifier:openRequestIdentifier];
    });
}

- (void)notifyLoadingPausedForRequest:(VibePlaybackRequest *)request {
    AudioTrack *track = request.track;
    BOOL paused = request.intent.paused;
    uint64_t submittedPlayIdentifier = request.submittedPlayIdentifier;
    run_on_main_thread({
        if (![self submittedPlayIsCurrent:submittedPlayIdentifier]) {
            LogInfo(@"Dropping didChangeLoadingPaused for superseded play %llu", submittedPlayIdentifier);
            return;
        }
        [self.delegate audioPlayer:self didChangeLoadingPaused:paused forTrack:track];
    });
}

#pragma mark - The published tuple

// The writer model, in one place. The player queue owns every transition;
// _stateLock protects only the snapshot the main-thread getters read. This is
// the FULL-TUPLE publisher: state, voice, file, and the position's origin in
// one acquisition, so a getter never observes a torn combination. The two
// unpublish variants below are the only partial writers, and they are safe
// because they never move the position's origin.
- (void)publishState:(VibePlayerState)state voice:(VibeVoiceID)voice file:(AudioFileHandle *)file
        startSeconds:(NSTimeInterval)startSeconds baseFrames:(uint64_t)baseFrames {
    VibePlaybackRequest *request = state == VibePlayerStateLoading ? _pendingRequest.currentRequest : nil;
    double fileSampleRate = file.processingFormat.sampleRate;
    AVAudioFramePosition fileLength = file.length;
    os_unfair_lock_lock(&_stateLock);
    _state = state;
    _voice = voice;
    _file = file;
    _fileSampleRate = fileSampleRate;
    _fileLength = fileLength;
    _voiceStartSeconds = startSeconds;
    _promotedBaseFrames = baseFrames;
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
    if (state == VibePlayerStatePlaying) {
        [self notePublishedPlayingPosition:startSeconds track:self.currentTrack ?: self.loadingTrack voice:voice];
    }
    [self refreshOutputAudioActiveOnQueue];
}

// Partial writer 1 of 2: clears the voice alone, and with it the successor
// that belonged to it. Hands the voice back for the caller to retire.
- (VibeVoiceID)unpublishVoiceOnQueue {
    os_unfair_lock_lock(&_stateLock);
    VibeVoiceID voice = _voice;
    _voice = 0;
    os_unfair_lock_unlock(&_stateLock);
    [self clearSuccessorOnQueue];
    return voice;
}

// Partial writer 2 of 2: state and voice together, one acquisition, because a
// state that disagrees with the published voice is exactly what the
// full-tuple publisher exists to prevent.
- (VibeVoiceID)unpublishVoiceOnQueueEnteringTerminalState:(VibePlayerState)state {
    os_unfair_lock_lock(&_stateLock);
    _state = state;
    VibeVoiceID voice = _voice;
    _voice = 0;
    os_unfair_lock_unlock(&_stateLock);
    [self clearSuccessorOnQueue];
    return voice;
}

// Output liveness is deliberately narrower than transport intent: Loading is
// inactive unless a retiring voice is still fading; a paused voice is
// inactive the moment the pause is published. AudioFX does not expose wet-tail
// lifetime, so claiming one here would be a timer-shaped guess.
- (void)refreshOutputAudioActiveOnQueue {
    BOOL active = [self renderingOnQueue]
            && ((_state == VibePlayerStatePlaying && _voice != 0) || _retiringVoices.count > 0);
    os_unfair_lock_lock(&_stateLock);
    BOOL changed = _outputAudioActive != active;
    _outputAudioActive = active;
    os_unfair_lock_unlock(&_stateLock);
#if TARGET_OS_OSX
    // Every state publication and voice end funnels here, which makes it the
    // edge that keeps the bit-perfect report's "a track is playing" input
    // honest without a hook in each publisher. Off, it returns at once.
    [self publishBitPerfectReportOnQueue];
#endif
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

#pragma mark - Delegate delivery

- (void)sendDelegateError:(NSError *)error {
    LogError(@"AudioPlayer Error: %@", error.localizedDescription);
    run_on_main_thread({
        [self.delegate audioPlayer:self error:error];
    });
}

// Whether a submission is still the newest one. Delivery sites call it on main
// from inside their delivery block, because what matters there is whether a
// newer play had been submitted by the time the callback actually ran.
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

// TRAP: the delegate cannot make this judgement itself, and its existing
// guards look like they can. A play failure is published as Stopped and its
// error hops to main; if the user re-plays the SAME row in the window before
// that hop lands, the shell sees a matching URL and a player that has not yet
// published Loading for the replacement, so every guard it has says the error
// is current — and it tears down state the newer play had just set up. The
// identifier is exact: a re-drop of a file already loading REBINDS its
// request and adopts the new submission's identifier, so a rebound request
// still matches and its error is still delivered.
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

#pragma mark - Debug introspection
#if DEBUG
- (instancetype)initForManualRendering:(AVAudioFormat *)format enableFX:(BOOL)enableFX automatic:(BOOL)automatic delegate:(id<AudioPlayerDelegate>)delegate {
    NSParameterAssert(format.commonFormat == AVAudioPCMFormatFloat32 && !format.interleaved);
    return [self initWithDeviceUID:@"" modelUID:@"" name:@"" enableFX:enableFX delegate:delegate
             loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]
                       manualPump:[[VibeManualRenderPump alloc] initWithFormat:format automatic:automatic]];
}

- (AVAudioPCMBuffer *)debugRenderFrames:(AVAudioFrameCount)frames error:(NSError **)error {
    __block AVAudioPCMBuffer *buffer;
    __block NSError *failure;
    [self runSyncOnQueue:^{ buffer = [(VibeManualRenderPump *)self->_manualPump renderFrames:frames error:&failure]; }];
    if (error) *error = failure;
    return buffer;
}

- (void)debugSetCapture:(void (^)(AVAudioPCMBuffer *))capture {
    [self runSyncOnQueue:^{ [(VibeManualRenderPump *)self->_manualPump setCapture:capture]; }];
}

- (void)debugBlockQueueForSeconds:(NSTimeInterval)seconds {
    dispatch_async(_queue, ^{ usleep((useconds_t)(MIN(10, MAX(0, seconds)) * 1e6)); });
}

- (void)debugStarveDecoder:(BOOL)starve {
    [self runSyncOnQueue:^{ [(VibeManualRenderPump *)self->_manualPump setStarveDecoder:starve]; }];
}

- (void)debugShutdown {
    self.delegate = nil;
    [self runSyncOnQueue:^{
        self->_terminating = YES;
        [self stopOnQueue];
        [(VibeManualRenderPump *)self->_manualPump cancel];
        [self stopOutputOnQueue];
    }];
}

// dump_audio_loading compares the three consumers' snapshots — the
// materialization coordinator's, the metadata cache's and this one.
- (AudioLoadingConfiguration *)loadingConfiguration {
    __block AudioLoadingConfiguration *configuration;
    [self runSyncOnQueue:^{ configuration = self->_loadingConfiguration; }];
    return configuration;
}

- (BOOL)manualRenderingActive {
    return _manualPump != nil;
}

- (AudioLevelMeter *)debugLevelMeter {
    __block AudioLevelMeter *meter;
    [self runSyncOnQueue:^{ meter = self->_levelMeter; }];
    return meter;
}

- (NSDictionary<NSString *, NSNumber *> *)debugRenderCounts {
    // Reading these off the queue would race every voice start and retire,
    // which is exactly the code these numbers are meant to audit.
    __block NSDictionary *counts = nil;
    [self runSyncOnQueue:^{
        VibeVoiceSnapshot snapshot = [self->_voiceBus snapshotOfVoice:self->_voice];
        NSDictionary *carrier = [self carrierCountersOnQueue];
        counts = @{@"hostedUnits": @([self hostedUnitCountOnQueue]),
                   @"unitRenders": @(self.fx.unitRenders),
                   @"outputDropouts": carrier[@"dropouts"],
                   @"renderCycles": carrier[@"renderCycles"],
                   @"renderMeanMicros": carrier[@"renderMeanMicros"],
                   @"renderMaxMicros": carrier[@"renderMaxMicros"],
                   @"retiredFades": @(self->_retiringVoices.count),
                   @"renderLeaveWork": @(self->_renderLeaveWork.count),
                   @"renderRefusals": @([self renderRefusalsOnQueue]),
                   @"rendersHeld": @([self debugRendersHeld]),
                   @"liveVoices": @(self->_voiceBus.liveVoiceCount),
                   @"decodeTurns": @(self->_voiceBus.decodeTurns),
                   @"pollActive": @(self->_drainTimer != nil),
                   @"running": @([self renderingOnQueue]),
                   @"frames": @([(VibeManualRenderPump *)self->_manualPump renderedFrames]),
                   @"varispeed": @([self varispeedPresentOnQueue]),
                   @"fxConnected": @(self.fx.connected),
                   @"gain": @(snapshot.gain),
                   @"underrunFrames": @(snapshot.underrunFrames),
                   @"varispeedLatency": @([self varispeedLatencyOnQueue]),
                   @"varispeedEngaged": @([self varispeedEngagedOnQueue]),
                   @"varispeedRenders": @([self varispeedRendersOnQueue]),
                   @"varispeedHistoryWrites": @([self varispeedHistoryWritesOnQueue]),
                   @"outputRate": @([self masterBusFormatOnQueue].sampleRate)};
    }];
    return counts;
}

- (BOOL)debugSetOutputRate:(double)rate {
    __block BOOL followed = NO;
    [self runSyncOnQueue:^{
        AVAudioFormat *current = [self masterBusFormatOnQueue];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate
                                                                             channels:current ? current.channelCount : 2];
        followed = [self followOutputFormatOnQueue:format];
    }];
    return followed;
}

- (NSDictionary<NSString *, id> *)debugCurrentConversion {
    __block NSDictionary *conversion;
    [self runSyncOnQueue:^{ conversion = [self->_voiceBus conversionOfVoice:self->_voice]; }];
    return conversion;
}

static NSString *VibeAudioLevelNormalizationModeName(VibeAudioLevelNormalizationMode normalizationMode) {
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
    [self runSyncOnQueue:^{
        if (self->_levelNormalizationMode == normalizationMode) {
            return;
        }
        [self dropLevelMeterOnQueue];
        self->_levelNormalizationMode = normalizationMode;
        [self applyLevelMeterOnQueue];
    }];
}

- (NSDictionary<NSString *, id> *)debugEqualizerState {
    __block NSDictionary *state = nil;
    [self runSyncOnQueue:^{
        NSMutableDictionary<NSString *, id> *snapshot = [[self->_levelPublisher debugState] mutableCopy];
        snapshot[@"requested"] = @(self->_levelsWanted);
        snapshot[@"signalProbe"] = @(self.signalProbeWanted); // beta builds' hold for a start's capture
        snapshot[@"meterObject"] = @(self->_levelMeter != nil);
        snapshot[@"retiredOutputCount"] = @(self->_retiringVoices.count);
        snapshot[@"outputAudioActive"] = @(self.outputAudioActive);
        snapshot[@"normalizationMode"] = VibeAudioLevelNormalizationModeName(self->_levelNormalizationMode);
        state = snapshot;
    }];
    return state;
}
#endif

@end
