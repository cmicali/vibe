//
//  AudioSessionController.m
//  Vibe (iOS)
//

#import "AudioSessionController.h"
#import <AVFAudio/AVFAudio.h>

// How long a pause or stop must stand before the session is released. Longer
// than the engine's own ~6s idle stop, so the session is never deactivated
// under a still-running engine, whose I/O makes setActive:NO fail.
static const NSTimeInterval kDeactivateDelaySeconds = 10.0;

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
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        AVAudioSession *session = [AVAudioSession sharedInstance];
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

- (BOOL)activate {
    _activationGeneration++; // cancel any pending idle deactivation
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
    return YES;
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

- (void)handleInterruption:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        [self onMain:^{
            self->_interruptionActive = YES;
            self->_wasPlayingAtInterruption = [self.delegate audioSessionShouldPause:self];
        }];
    }
    else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        [self onMain:^{
            self->_interruptionActive = NO;
            if ((options & AVAudioSessionInterruptionOptionShouldResume) && self->_wasPlayingAtInterruption) {
                [self.delegate audioSessionShouldResume:self];
            }
            else {
                // Staying paused: release the session claim the interruption
                // handler's own deactivation deferred.
                [self deactivateWhenIdle];
            }
        }];
    }
}

- (void)handleRouteChange:(NSNotification *)note {
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    // Only the disappearing-output case pauses — the unplugged-headphones
    // rule. Overrides and new devices keep playing on the new route: the
    // engine stops itself on those too, and the configuration-change verdict
    // below restarts it in place.
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [self onMain:^{
            [self.delegate audioSessionShouldPause:self];
        }];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    LogWarn(@"AudioSession: media services were reset");
    [self onMain:^{
        self->_interruptionActive = NO; // whatever was in progress died with the server
        [self.delegate audioSessionMediaServicesWereReset:self];
    }];
}

- (void)handleEngineConfigurationChange:(NSNotification *)note {
    [self onMain:^{
        [self.delegate audioSessionEngineConfigurationChanged:self];
    }];
}

@end
