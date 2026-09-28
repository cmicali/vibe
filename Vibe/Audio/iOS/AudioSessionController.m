//
//  AudioSessionController.m
//  Vibe (iOS)
//

#import "AudioSessionController.h"
#import "AudioSessionRecoveryRules.h"
#import <AVFAudio/AVFAudio.h>
#import <os/lock.h>

typedef NS_OPTIONS(NSUInteger, VibeAudioSessionRecoveryBlocker) {
    VibeAudioSessionRecoveryBlockerInterruption = 1 << 0,
    VibeAudioSessionRecoveryBlockerRouteLoss = 1 << 1,
    VibeAudioSessionRecoveryBlockerMediaReset = 1 << 2,
};

static NSString *VibeRouteChangeReasonName(NSUInteger reason) {
    switch (reason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: return @"new device";
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: return @"old device unavailable";
        case AVAudioSessionRouteChangeReasonCategoryChange: return @"category change";
        case AVAudioSessionRouteChangeReasonOverride: return @"override";
        case AVAudioSessionRouteChangeReasonWakeFromSleep: return @"wake from sleep";
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory: return @"no suitable route";
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange: return @"configuration change";
        default: return [NSString stringWithFormat:@"reason %lu", (unsigned long)reason];
    }
}

static NSString *VibeConfigurationActionName(VibeAudioSessionConfigurationAction action) {
    switch (action) {
        case VibeAudioSessionConfigurationActionIgnore: return @"ignore";
        case VibeAudioSessionConfigurationActionPause: return @"pause";
        case VibeAudioSessionConfigurationActionRecover: return @"recover";
    }
    return @"unknown";
}

static VibeOutputRouteKind VibeOutputRouteKindForPort(AVAudioSessionPort portType) {
    if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        return VibeOutputRouteKindBuiltInSpeaker;
    }
    if ([portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return VibeOutputRouteKindBuiltInReceiver;
    }
    if ([portType isEqualToString:AVAudioSessionPortHeadphones]
            || [portType isEqualToString:AVAudioSessionPortLineOut]
            || [portType isEqualToString:AVAudioSessionPortUSBAudio]) {
        return VibeOutputRouteKindWired;
    }
    if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP]
            || [portType isEqualToString:AVAudioSessionPortBluetoothLE]
            || [portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        return VibeOutputRouteKindBluetooth;
    }
    if ([portType isEqualToString:AVAudioSessionPortAirPlay]) {
        return VibeOutputRouteKindAirPlay;
    }
    if ([portType isEqualToString:AVAudioSessionPortCarAudio]) {
        return VibeOutputRouteKindCarPlay;
    }
    return VibeOutputRouteKindOther;
}

// The one place a route is classified, for both the indicator the card draws
// and — through VibeAudioSessionOutputRouteKindForRouteKind — the pause/recover
// decision. The first external output decides, else the first output.
static VibeOutputRouteKind VibeOutputRouteKindForRoute(
        AVAudioSessionRouteDescription *route, NSString *__strong *outName) {
    if (outName) {
        *outName = nil;
    }
    if (route.outputs.count == 0) {
        return VibeOutputRouteKindNone;
    }
    AVAudioSessionPortDescription *chosen = route.outputs.firstObject;
    VibeOutputRouteKind kind = VibeOutputRouteKindForPort(chosen.portType);
    for (AVAudioSessionPortDescription *output in route.outputs) {
        VibeOutputRouteKind outputKind = VibeOutputRouteKindForPort(output.portType);
        if (VibeAudioSessionOutputRouteKindForRouteKind(outputKind)
                == VibeAudioSessionOutputRouteExternal) {
            chosen = output;
            kind = outputKind;
            break;
        }
    }
    if (outName) {
        *outName = chosen.portName;
    }
    return kind;
}

@interface AudioSessionController ()
- (BOOL)activateSession;
- (BOOL)activateForInterruptionResume;
- (VibeAudioSessionConfigurationAction)beginConfigurationActionForOutputRoute:
        (VibeAudioSessionOutputRouteKind)currentRoute
        outputLost:(BOOL)outputLost
        generation:(uint64_t *)generation;
- (BOOL)recordOutputRoute:(VibeOutputRouteKind)kind name:(nullable NSString *)name;
- (void)publishOutputRouteChange;
- (void)addConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker;
- (void)removeConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker;
- (VibeAudioSessionRecoveryBlocker)clearConfigurationRecoveryBlockersForActivation;
- (void)restoreConfigurationRecoveryBlockers:(VibeAudioSessionRecoveryBlocker)blockers;
- (BOOL)hasConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker;
- (BOOL)mayAutomaticallyResume;
- (BOOL)deliverAutomaticResumeIfAllowed;
- (BOOL)deliverConfigurationRecoveryForGeneration:(uint64_t)generation;
@end

@implementation AudioSessionController {
    // Main-confined, like every other verdict path here.
    //
    // Whether playback was running when the current interruption began,
    // recorded at the Began edge only: the route-loss pauses that often
    // follow mid-interruption (the route moves to the call's receiver) must
    // not overwrite the verdict the Ended resume depends on.
    BOOL _wasPlayingAtInterruption;
    // An interruption is in progress; the deactivation holds off while set.
    BOOL _interruptionActive;
    // A pause or end asked for the release; activate reclaims it.
    BOOL _deactivationWanted;

    // Route, interruption and reset notifications arrive on separate system
    // queues. The lock makes their receipt order authoritative before any
    // main-thread verdict runs. The route snapshot also lets a route change
    // of any reason recognize disappearing external output.
    os_unfair_lock _configurationRecoveryLock;
    uint64_t _configurationRecoveryGeneration;
    VibeAudioSessionRecoveryBlocker _configurationRecoveryBlockers;
    // The last recorded route, at the resolution the card's indicator draws;
    // the pause/recover decision reads its coarse fold.
    VibeOutputRouteKind _outputRouteKind;
    NSString *_outputRouteName;
}

- (instancetype)initWithDelegate:(id<AudioSessionControllerDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
        _configurationRecoveryLock = OS_UNFAIR_LOCK_INIT;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        AVAudioSession *session = [AVAudioSession sharedInstance];
        // Recorded, deliberately not published: the delegate pointer is set
        // but PlaybackController is still inside its own init.
        NSString *routeName = nil;
        VibeOutputRouteKind routeKind =
                VibeOutputRouteKindForRoute(session.currentRoute, &routeName);
        [self recordOutputRoute:routeKind name:routeName];
        [center addObserver:self selector:@selector(handleInterruption:)
                       name:AVAudioSessionInterruptionNotification object:session];
        [center addObserver:self selector:@selector(handleRouteChange:)
                       name:AVAudioSessionRouteChangeNotification object:session];
        [center addObserver:self selector:@selector(handleMediaServicesReset:)
                       name:AVAudioSessionMediaServicesWereResetNotification object:session];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)activate {
    _deactivationWanted = NO;
    // Clear the old blockers before entering AVAudioSession. A notification
    // racing the synchronous calls then adds a fresh blocker that success
    // cannot erase; failure restores only the blockers this attempt inherited.
    VibeAudioSessionRecoveryBlocker blockersToRestoreOnFailure =
            [self clearConfigurationRecoveryBlockersForActivation];
    // Apple does not guarantee every Began a matching Ended (the app can be
    // suspended, or the session deactivated mid-interruption). A play is the
    // user declaring the interruption over; without this reset one orphaned
    // Began would wedge every future idle deactivation for the process's life.
    _interruptionActive = NO;
    _wasPlayingAtInterruption = NO;
    // Only this explicit path clears route-loss and reset ownership; the
    // interruption-ended resume enters activateSession without it.
    if ([self activateSession]) {
        LogInfo(@"AudioSession: activated");
        return YES;
    }
    [self restoreConfigurationRecoveryBlockers:blockersToRestoreOnFailure];
    return NO;
}

- (BOOL)activateSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error]) {
        LogError(@"AudioSession: setCategory failed (%@)", error);
        return NO;
    }
    if (![session setActive:YES error:&error]) {
        LogError(@"AudioSession: setActive failed (%@)", error);
        return NO;
    }
    // Only on a real change: activate runs before every play, and this is the
    // edge where a destination picked while the session was inactive — which
    // posts no route notification of its own — first becomes visible.
    NSString *routeName = nil;
    VibeOutputRouteKind routeKind =
            VibeOutputRouteKindForRoute(session.currentRoute, &routeName);
    if ([self recordOutputRoute:routeKind name:routeName]) {
        [self publishOutputRouteChange];
    }
    return YES;
}

- (BOOL)activateForInterruptionResume {
    _deactivationWanted = NO;
    // An Ended resume is a system suggestion, not explicit user intent. It
    // must never release a route-loss or media-reset block as activate does.
    return [self mayAutomaticallyResume] && [self activateSession];
}

- (void)deactivateWhenIdle {
    _deactivationWanted = YES;
    [self deactivateIfIdle];
}

// The output's answer is read now, never remembered, so an idle edge a newer
// start has overtaken releases nothing.
- (void)deactivateIfIdle {
    BOOL outputIdle = [self.delegate audioSessionOutputIsIdle:self];
    if (!VibeAudioSessionMayDeactivate(_deactivationWanted, _interruptionActive, outputIdle)) {
        if (_deactivationWanted) {
            LogInfo(@"AudioSession: deactivation held (interruption %d, output idle %d)",
                    _interruptionActive, outputIdle);
        }
        return;
    }
    _deactivationWanted = NO;
    NSError *error = nil;
    // TRAP: a NO here is not a refusal. With audio objects still running the
    // session goes inactive all the same and stops them, so the only thing
    // that keeps a tail from being cut is the idle rule above.
    if (![[AVAudioSession sharedInstance] setActive:NO
                    withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                          error:&error]) {
        LogWarn(@"AudioSession: deactivate failed (%@)", error);
        return;
    }
    LogInfo(@"AudioSession: deactivated");
}

// Session notifications can arrive on any thread; the delegate's transport
// calls and this object's state belong on main, like every other UI-facing
// path.
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    }
    else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

// The route's reason names a loss only sometimes: an output that fell from
// external to built-in, or to nothing, is one whatever the reason says.
- (VibeAudioSessionConfigurationAction)beginConfigurationActionForOutputRoute:
        (VibeAudioSessionOutputRouteKind)currentRoute
        outputLost:(BOOL)outputLost
        generation:(uint64_t *)generation {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    VibeAudioSessionOutputRouteKind previousRoute =
            VibeAudioSessionOutputRouteKindForRouteKind(_outputRouteKind);
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    VibeAudioSessionConfigurationAction action = outputLost
            ? VibeAudioSessionConfigurationActionPause
            : VibeAudioSessionConfigurationActionForRoutes(
                    previousRoute, currentRoute,
                    (blockers & VibeAudioSessionRecoveryBlockerInterruption) != 0,
                    (blockers & VibeAudioSessionRecoveryBlockerRouteLoss) != 0,
                    (blockers & VibeAudioSessionRecoveryBlockerMediaReset) != 0);
    uint64_t newestGeneration = ++_configurationRecoveryGeneration;
    if (action == VibeAudioSessionConfigurationActionPause) {
        _configurationRecoveryBlockers |=
                VibeAudioSessionRecoveryBlockerRouteLoss;
    }
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    if (generation) {
        *generation = newestGeneration;
    }
    return action;
}

// Returns whether the pair actually moved, so the display edge is published
// once per real change rather than once per play.
- (BOOL)recordOutputRoute:(VibeOutputRouteKind)kind name:(nullable NSString *)name {
    // Recording a route must not cancel a pending recovery; safety
    // notifications separately add a blocker, which does cancel it.
    os_unfair_lock_lock(&_configurationRecoveryLock);
    BOOL changed = kind != _outputRouteKind
            || !(name == _outputRouteName || [name isEqualToString:_outputRouteName]);
    _outputRouteKind = kind;
    _outputRouteName = [name copy];
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    if (changed) {
        LogInfo(@"AudioSession: output route is now %lu (%@)",
                (unsigned long)kind, name ?: @"unnamed");
    }
    return changed;
}

- (VibeOutputRouteKind)outputRouteKind {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    VibeOutputRouteKind kind = _outputRouteKind;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return kind;
}

- (NSString *)outputRouteName {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    NSString *name = _outputRouteName;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return name;
}

// TRAP: an unconditional dispatch_async, not onMain:. activateSession
// publishes from inside an activation the play path is waiting on, and this
// edge fans out to every PlaybackObserver; inline, that is re-entrancy.
- (void)publishOutputRouteChange {
    __weak AudioSessionController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        AudioSessionController *strongSelf = weakSelf;
        [strongSelf.delegate audioSessionOutputRouteDidChange:strongSelf];
    });
}

- (void)addConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    _configurationRecoveryGeneration++;
    _configurationRecoveryBlockers |= blocker;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
}

- (void)removeConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    if ((_configurationRecoveryBlockers & blocker) != 0) {
        _configurationRecoveryGeneration++;
        _configurationRecoveryBlockers &= ~blocker;
    }
    os_unfair_lock_unlock(&_configurationRecoveryLock);
}

- (VibeAudioSessionRecoveryBlocker)clearConfigurationRecoveryBlockersForActivation {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    _configurationRecoveryGeneration++;
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    _configurationRecoveryBlockers = 0;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return blockers;
}

- (void)restoreConfigurationRecoveryBlockers:(VibeAudioSessionRecoveryBlocker)blockers {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    _configurationRecoveryGeneration++;
    _configurationRecoveryBlockers |= blockers;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
}

- (BOOL)hasConfigurationRecoveryBlocker:(VibeAudioSessionRecoveryBlocker)blocker {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    BOOL blocked = (_configurationRecoveryBlockers & blocker) != 0;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return blocked;
}

- (BOOL)mayAutomaticallyResume {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return VibeAudioSessionMayAutomaticallyResume(
            (blockers & VibeAudioSessionRecoveryBlockerInterruption) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerRouteLoss) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerMediaReset) != 0);
}

- (BOOL)deliverAutomaticResumeIfAllowed {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    BOOL allowed = VibeAudioSessionMayAutomaticallyResume(
            (blockers & VibeAudioSessionRecoveryBlockerInterruption) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerRouteLoss) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerMediaReset) != 0);
    if (allowed) {
        // Atomic with the safety verdict: this delegate edge only submits
        // player-queue work and never calls back into the session controller.
        [self.delegate audioSessionShouldResume:self];
    }
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return allowed;
}

- (BOOL)deliverConfigurationRecoveryForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    uint64_t newestGeneration = _configurationRecoveryGeneration;
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    BOOL allowed = VibeAudioSessionMayDeliverConfigurationRecovery(
            generation, newestGeneration,
            (blockers & VibeAudioSessionRecoveryBlockerInterruption) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerRouteLoss) != 0,
            (blockers & VibeAudioSessionRecoveryBlockerMediaReset) != 0);
    if (allowed) {
        // Keep validation and player-queue admission indivisible from a route
        // loss or media-reset receipt on another system notification queue.
        [self.delegate audioSessionShouldRecoverOutput:self];
    }
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return allowed;
}

- (void)handleInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        NSUInteger reason = [note.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        LogInfo(@"AudioSession: interruption began (reason %lu)", (unsigned long)reason);
        if (reason == AVAudioSessionInterruptionReasonRouteDisconnected) {
            // TRAP: no Ended follows this one (AirPods into their case,
            // observed on device), so it must own nothing an Ended releases:
            // held as an interruption it kept the session until the next
            // play. The route loss beside it owns the pause and its blocker.
            [self onMain:^{
                [self.delegate audioSessionShouldPause:self];
            }];
            return;
        }
        [self addConfigurationRecoveryBlocker:
                VibeAudioSessionRecoveryBlockerInterruption];
        [self onMain:^{
            BOOL firstEdge = !self->_interruptionActive;
            self->_interruptionActive = YES;
            BOOL wasPlaying = [self.delegate audioSessionShouldPause:self];
            if (firstEdge) {
                // Duplicate Began notifications may reinforce the idempotent
                // pause, but only the first edge owns the matching Ended
                // intent. Later config/route pauses must not erase it.
                self->_wasPlayingAtInterruption = wasPlaying;
            }
        }];
    }
    else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        LogInfo(@"AudioSession: interruption ended (should resume %d)",
                (options & AVAudioSessionInterruptionOptionShouldResume) != 0);
        [self removeConfigurationRecoveryBlocker:
                VibeAudioSessionRecoveryBlockerInterruption];
        [self onMain:^{
            BOOL matchedActiveInterruption = self->_interruptionActive;
            self->_interruptionActive = NO;
            BOOL wasPlaying = matchedActiveInterruption && self->_wasPlayingAtInterruption;
            // Consumed: a duplicate or Began-less Ended (documented after a
            // foregrounding) must not replay a stale YES and resume audio the
            // user has since paused by hand.
            self->_wasPlayingAtInterruption = NO;
            if (!matchedActiveInterruption) {
                // activate may already have declared an orphaned interruption
                // over and reclaimed the session for a user play. A late Ended
                // then owns neither a resume nor a deactivation.
                return;
            }
            BOOL resumed = (options & AVAudioSessionInterruptionOptionShouldResume)
                    && wasPlaying && [self activateForInterruptionResume]
                    && [self deliverAutomaticResumeIfAllowed];
            LogInfo(@"AudioSession: interruption matched, was playing %d, resumed %d", wasPlaying, resumed);
            if (!resumed) {
                // Staying paused: release the session the interruption held.
                [self deactivateWhenIdle];
            }
        }];
    }
}

- (void)handleRouteChange:(NSNotification *)note {
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    NSString *routeName = nil;
    VibeOutputRouteKind routeKind = VibeOutputRouteKindForRoute(
            [AVAudioSession sharedInstance].currentRoute, &routeName);
    // Only disappearing output pauses — the unplugged-headphones rule.
    // Overrides and new devices keep playing on the new route, whose rate the
    // recovery verdict has the pipeline follow, coalesced with the changes
    // after it before main delivery. Classified before the route is
    // recorded: the transition is read against the last one.
    uint64_t configurationRecoveryGeneration = 0;
    VibeAudioSessionConfigurationAction action =
            [self beginConfigurationActionForOutputRoute:
                    VibeAudioSessionOutputRouteKindForRouteKind(routeKind)
                    outputLost:reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable
                    generation:&configurationRecoveryGeneration];
    LogInfo(@"AudioSession: route change (%@) to %@: %@",
            VibeRouteChangeReasonName(reason), routeName ?: @"unnamed",
            VibeConfigurationActionName(action));
    // Published whatever the verdict: a new device, an override and a
    // category change are exactly the cases the indicator exists for.
    if ([self recordOutputRoute:routeKind name:routeName]) {
        [self publishOutputRouteChange];
    }
    if (action == VibeAudioSessionConfigurationActionIgnore) {
        return;
    }
    [self onMain:^{
        if (action == VibeAudioSessionConfigurationActionRecover) {
            if (![self deliverConfigurationRecoveryForGeneration:
                    configurationRecoveryGeneration]) {
                LogInfo(@"AudioSession: output recovery %llu dropped (coalesced or blocked)",
                        configurationRecoveryGeneration);
            }
            return;
        }
        if (![self hasConfigurationRecoveryBlocker:
                VibeAudioSessionRecoveryBlockerRouteLoss]) {
            LogInfo(@"AudioSession: route-loss pause superseded by an activation");
            return; // an explicit activation superseded this late pause
        }
        [self.delegate audioSessionShouldPause:self];
    }];
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    LogWarn(@"AudioSession: media services were reset");
    [self addConfigurationRecoveryBlocker:
            VibeAudioSessionRecoveryBlockerMediaReset];
    // This is deliberately before the main hop: beginMediaServicesReset uses
    // the same lock-and-enqueue edge as play submissions, so a play received
    // after this notification runs on the rebuilt output rather than being
    // destroyed by a reset queued later from main.
    [self.delegate audioSessionDidReceiveMediaServicesReset:self];
    [self onMain:^{
        self->_deactivationWanted = NO; // the session died with the server
        self->_interruptionActive = NO; // whatever was in progress died with the server
        self->_wasPlayingAtInterruption = NO;
    }];
}

@end
