//
//  VibeiOSSceneDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSSceneDelegate.h"
#import "PlaybackController.h"
#import "RootViewController.h"
#import "SearchFolderStore.h"

@implementation VibeiOSSceneDelegate {
    // The scene owns the one PlaybackController — one engine per process,
    // which is why UIApplicationSupportsMultipleScenes is off. The screens
    // borrow it.
    PlaybackController *_playback;
    RootViewController *_root;
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
    _root = root;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    // The screens must exist — and be observing — before anything is adopted.
    // Exactly one of the two launch paths runs: a cold "Open in Vibe" adopts
    // the arriving URL directly, everything else restores the persisted
    // session — never both, so the open does not pay for a restore it
    // immediately replaces.
    [root loadViewIfNeeded];
    [self setSceneActive:scene.activationState == UISceneActivationStateForegroundActive];
    // Not part of the either/or below: this opens nothing and plays nothing, it
    // just takes back the search grants the user gave us. It resolves off main
    // and reports through its own notification, so it cannot delay either path.
    [SearchFolderStore.shared restorePersistedFolders];
    if (connectionOptions.URLContexts.count > 0) {
        [_playback handleOpenURLContexts:connectionOptions.URLContexts];
    }
    else {
        [_playback restorePersistedSession];
    }
}

// Foreground-inactive is an off state, not a halfway foreground. Views remain
// attached under Control Center and the app switcher, so only the scene owner
// can make both the UI timer and the equalizer fail closed there.
- (void)setSceneActive:(BOOL)active {
    _playback.sceneActive = active;
    _root.sceneActive = active;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [self setSceneActive:YES];
}

- (void)sceneWillResignActive:(UIScene *)scene {
    [self setSceneActive:NO];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [self setSceneActive:NO];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [_playback handleOpenURLContexts:URLContexts];
}

@end
