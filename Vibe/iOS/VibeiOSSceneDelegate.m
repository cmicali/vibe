//
//  VibeiOSSceneDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSSceneDelegate.h"
#import "PlaybackController.h"
#import "RootViewController.h"
#import "SearchFolderStore.h"

@implementation VibeiOSSceneDelegate {
    // One engine per process, so multi-scene is off.
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
    // The card's strip layout's floor: a 150pt art, its insets and the window
    // controls' inset. iPadOS 26 holds a window taller than this anyway (about
    // 486pt). nil (a no-op) on iPhone.
    windowScene.sizeRestrictions.minimumSize = CGSizeMake(320, 200);
    _playback = [[PlaybackController alloc] init];
    RootViewController *root = [[RootViewController alloc] initWithPlayback:_playback];
    _root = root;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    // The screens observe before anything is adopted. Exactly one launch path
    // runs, so a cold "Open in Vibe" never pays for a restore it replaces.
    [root loadViewIfNeeded];
    [self setSceneActive:scene.activationState == UISceneActivationStateForegroundActive];
    // Opens and plays nothing, and resolves off main.
    [SearchFolderStore.shared restorePersistedFolders];
    if (connectionOptions.URLContexts.count > 0) {
        [_playback handleOpenURLContexts:connectionOptions.URLContexts];
    }
    else {
        [_playback restorePersistedSession];
    }
}

// Foreground-inactive is off: views stay attached under Control Center and the
// app switcher, so only the scene owner can fail the UI timer and equalizer
// closed there.
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

#pragma mark - The widget's way in

// A scene can be connected before building its controller, and an intent can
// find the app launched with no scene at all.
+ (PlaybackController *)connectedPlayback {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene.delegate isKindOfClass:VibeiOSSceneDelegate.class]) {
            PlaybackController *playback = ((VibeiOSSceneDelegate *)scene.delegate).playback;
            if (playback) {
                return playback;
            }
        }
    }
    return nil;
}

@end
