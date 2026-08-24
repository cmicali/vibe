//
//  AudioSessionController.m
//  Vibe (iOS)
//

#import "AudioSessionController.h"
#import "AudioSessionRecoveryRules.h"
#import <AVFAudio/AVFAudio.h>
#import <os/lock.h>

// How long a pause or stop must stand before the session is released. Longer
// than the engine's own ~6s idle stop, so the session is never deactivated
// under a still-running engine, whose I/O makes setActive:NO fail.
static const NSTimeInterval kDeactivateDelaySeconds = 10.0;

typedef NS_OPTIONS(NSUInteger, VibeAudioSessionRecoveryBlocker) {
    VibeAudioSessionRecoveryBlockerInterruption = 1 << 0,
    VibeAudioSessionRecoveryBlockerRouteLoss = 1 << 1,
    VibeAudioSessionRecoveryBlockerMediaReset = 1 << 2,
};

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
// decision. The first non-built-in output decides, exactly as the coarse
// classifier this replaced did, so the fold reproduces its answers.
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
    // Both main-confined, like every other verdict path here.
    //
    // Whether playback was running when the current interruption began,
    // recorded at the Began edge only: the config-change and route-loss
    // pauses that often follow mid-interruption (the route moves to the
    // call's receiver, the engine posts a configuration change) must not
    // overwrite the verdict the Ended resume depends on.
    BOOL _wasPlayingAtInterruption;
    // An interruption is in progress; deactivateWhenIdle holds off while set.
    BOOL _interruptionActive;
    // Cancels a pending deactivation: activate and every newer schedule bump
    // it, and the deferred block no-ops when its captured value went stale.
    uint64_t _activationGeneration;

    // Route, interruption, reset and engine notifications arrive on separate
    // system queues. The lock makes their receipt order authoritative before
    // any main-thread verdict runs. The route snapshot also lets an engine
    // configuration notification recognize disappearing external output even
    // when AVAudioSession posts it before the route-change notification.
    os_unfair_lock _configurationRecoveryLock;
    uint64_t _configurationRecoveryGeneration;
    VibeAudioSessionRecoveryBlocker _configurationRecoveryBlockers;
    VibeAudioSessionOutputRouteKind _lastOutputRoute;
    // The same route, at the resolution the card's indicator draws. Written
    // with _lastOutputRoute under the lock above, so the pair and the fold can
    // never describe two different routes.
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
        // object:nil — only one engine exists at a time, and the player does
        // not expose it; nil also keeps observing across the media-services
        // rebuild's fresh engine. The macOS handler for this notification
        // lives in the excluded AudioPlayer+Devices; here the delegate routes
        // it to the player's own in-place restart.
        [center addObserver:self selector:@selector(handleEngineConfigurationChange:)
                       name:AVAudioEngineConfigurationChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (void)prepareIdleCategory {
    NSError *error = nil;
    if (![[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                                error:&error]) {
        LogError(@"AudioSession: idle setCategory failed (%@)", error);
    }
}

- (BOOL)activate {
    _activationGeneration++; // cancel any pending idle deactivation
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
    // This explicit path alone cleared persistent route-loss/reset ownership
    // above. Automatic interruption recovery enters the helper below without
    // doing so.
    if ([self activateSession]) {
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
    _activationGeneration++; // cancel any pending idle deactivation
    // An Ended resume is a system suggestion, not explicit user intent. It
    // must never release a route-loss or media-reset block as activate does.
    return [self mayAutomaticallyResume] && [self activateSession];
}

- (void)deactivateWhenIdle {
    uint64_t generation = ++_activationGeneration;
    __weak AudioSessionController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeactivateDelaySeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AudioSessionController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_activationGeneration) {
            return; // a play or resume reclaimed the session, or a newer schedule owns it
        }
        if (strongSelf->_interruptionActive) {
            // Deactivating mid-interruption can forfeit the Ended
            // notification; the Ended handler reschedules when no resume
            // follows.
            return;
        }
        NSError *error = nil;
        if (![[AVAudioSession sharedInstance] setActive:NO
                        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                              error:&error]) {
            // Benign: playback may be winding down, or the system already
            // reclaimed the session.
            LogWarn(@"AudioSession: deactivate failed (%@)", error);
        }
    });
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

- (VibeAudioSessionConfigurationAction)beginConfigurationActionForOutputRoute:
        (VibeAudioSessionOutputRouteKind)currentRoute
        generation:(uint64_t *)generation {
    os_unfair_lock_lock(&_configurationRecoveryLock);
    VibeAudioSessionOutputRouteKind previousRoute = _lastOutputRoute;
    VibeAudioSessionRecoveryBlocker blockers = _configurationRecoveryBlockers;
    VibeAudioSessionConfigurationAction action =
            VibeAudioSessionConfigurationActionForRoutes(
                    previousRoute, currentRoute,
                    (blockers & VibeAudioSessionRecoveryBlockerInterruption) != 0,
                    (blockers & VibeAudioSessionRecoveryBlockerRouteLoss) != 0,
                    (blockers & VibeAudioSessionRecoveryBlockerMediaReset) != 0);
    _lastOutputRoute = currentRoute;
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
    // A non-loss route notification may follow the configuration notification
    // it explains. Recording it must not cancel that pending restart; safety
    // notifications separately add a blocker, which does cancel it.
    os_unfair_lock_lock(&_configurationRecoveryLock);
    BOOL changed = kind != _outputRouteKind
            || !(name == _outputRouteName || [name isEqualToString:_outputRouteName]);
    _outputRouteKind = kind;
    _outputRouteName = [name copy];
    _lastOutputRoute = VibeAudioSessionOutputRouteKindForRouteKind(kind);
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

// TRAP: an unconditional dispatch_async, not onMain:. This edge fans out
// through PlaybackController to every observer, and activateSession publishes
// it from inside a session activation the play path is waiting on — running
// that broadcast inline there is a re-entrancy the notification paths never
// have.
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
        [self.delegate audioSessionEngineConfigurationChanged:self];
    }
    os_unfair_lock_unlock(&_configurationRecoveryLock);
    return allowed;
}

- (void)handleInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
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
                // then owns neither a resume nor a new idle-deactivation timer.
                return;
            }
            BOOL resumed = (options & AVAudioSessionInterruptionOptionShouldResume)
                    && wasPlaying && [self activateForInterruptionResume]
                    && [self deliverAutomaticResumeIfAllowed];
            if (!resumed) {
                // Staying paused: release the session claim the interruption
                // handler's own deactivation deferred.
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
    // Published outside the loss branch below: a new device, an override and a
    // category change are exactly the cases the indicator exists for.
    if ([self recordOutputRoute:routeKind name:routeName]) {
        [self publishOutputRouteChange];
    }
    // Only the disappearing-output case pauses — the unplugged-headphones
    // rule. Overrides and new devices keep playing on the new route: the
    // engine stops itself on those too, and the configuration-change verdict
    // below restarts it in place.
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [self addConfigurationRecoveryBlocker:
                VibeAudioSessionRecoveryBlockerRouteLoss];
        [self onMain:^{
            if (![self hasConfigurationRecoveryBlocker:
                    VibeAudioSessionRecoveryBlockerRouteLoss]) {
                return; // an explicit activation superseded this late pause
            }
            [self.delegate audioSessionShouldPause:self];
        }];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    LogWarn(@"AudioSession: media services were reset");
    [self addConfigurationRecoveryBlocker:
            VibeAudioSessionRecoveryBlockerMediaReset];
    // This is deliberately before the main hop: beginMediaServicesReset uses
    // the same lock-and-enqueue edge as play submissions, so a play received
    // after this notification runs on the rebuilt engine rather than being
    // destroyed by a reset queued later from main.
    [self.delegate audioSessionDidReceiveMediaServicesReset:self];
    [self onMain:^{
        self->_activationGeneration++; // every pending session operation belonged to the dead server
        self->_interruptionActive = NO; // whatever was in progress died with the server
        self->_wasPlayingAtInterruption = NO;
    }];
}

- (void)handleEngineConfigurationChange:(NSNotification *)note {
    uint64_t configurationRecoveryGeneration = 0;
    VibeAudioSessionConfigurationAction action =
            [self beginConfigurationActionForOutputRoute:
                    VibeAudioSessionOutputRouteKindForRouteKind(
                            VibeOutputRouteKindForRoute(
                                    [AVAudioSession sharedInstance].currentRoute, NULL))
                    generation:&configurationRecoveryGeneration];
    if (action == VibeAudioSessionConfigurationActionIgnore) {
        return;
    }
    [self onMain:^{
        if (action == VibeAudioSessionConfigurationActionPause) {
            if (![self hasConfigurationRecoveryBlocker:
                    VibeAudioSessionRecoveryBlockerRouteLoss]) {
                return;
            }
            [self.delegate audioSessionShouldPause:self];
            return;
        }
        [self deliverConfigurationRecoveryForGeneration:
                configurationRecoveryGeneration];
    }];
}

@end
