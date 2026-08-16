//
//  VibeiOSSceneDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSSceneDelegate.h"
#import "PlaybackController.h"
#import "RootViewController.h"

@implementation VibeiOSSceneDelegate {
    // The scene owns the one PlaybackController — one engine per process,
    // which is why UIApplicationSupportsMultipleScenes is off. The screens
    // borrow it.
    PlaybackController *_playback;
}

- (void)scene:(UIScene *)scene
        willConnectToSession:(UISceneSession *)session
                     options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    // iPadOS 26 windowing: 320x480 is the portrait layout's floor (waveform
    // band + bottom bar leave no room below it). sizeRestrictions is nil on
    // iPhone, so this is a no-op there.
    windowScene.sizeRestrictions.minimumSize = CGSizeMake(320, 480);
    _playback = [[PlaybackController alloc] init];
    RootViewController *root = [[RootViewController alloc] initWithPlayback:_playback];
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    // The screens must exist — and be observing — before anything is adopted.
    // Exactly one of the two launch paths runs: a cold "Open in Vibe" adopts
    // the arriving URL directly, everything else restores the persisted
    // session — never both, so the open does not pay for a restore it
    // immediately replaces.
    [root loadViewIfNeeded];
    if (connectionOptions.URLContexts.count > 0) {
        [_playback handleOpenURLContexts:connectionOptions.URLContexts];
    }
    else {
        [_playback restorePersistedSession];
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [_playback handleOpenURLContexts:URLContexts];
}

@end
