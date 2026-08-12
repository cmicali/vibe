//
//  AudioSessionController.m
//  Vibe (iOS)
//

#import "AudioSessionController.h"
#import <AVFAudio/AVFAudio.h>

@implementation AudioSessionController

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
        // object:nil — only one engine exists, and the player does not expose
        // it. The macOS handler for this notification lives in the excluded
        // AudioPlayer+Devices; here it just pauses, and the engine's own
        // idle-stop → lazy-restart path is the recovery.
        [center addObserver:self selector:@selector(handleEngineConfigurationChange:)
                       name:AVAudioEngineConfigurationChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)activate {
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

// Session notifications can arrive on any thread; the delegate's transport
// calls belong on main, like every other UI-facing path.
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
            [self.delegate audioSessionShouldPause:self];
        }];
    }
    else if (type == AVAudioSessionInterruptionTypeEnded) {
        NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if ((options & AVAudioSessionInterruptionOptionShouldResume) && self.wasPlayingAtInterruption) {
            [self onMain:^{
                [self.delegate audioSessionShouldResume:self];
            }];
        }
    }
}

- (void)handleRouteChange:(NSNotification *)note {
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    // Only the disappearing-output case pauses — the unplugged-headphones
    // rule. Overrides and new devices keep playing on the new route.
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [self onMain:^{
            [self.delegate audioSessionShouldPause:self];
        }];
    }
}

- (void)handleMediaServicesReset:(NSNotification *)note {
    LogWarn(@"AudioSession: media services were reset");
    [self onMain:^{
        [self.delegate audioSessionShouldPause:self];
    }];
}

- (void)handleEngineConfigurationChange:(NSNotification *)note {
    [self onMain:^{
        [self.delegate audioSessionShouldPause:self];
    }];
}

@end
