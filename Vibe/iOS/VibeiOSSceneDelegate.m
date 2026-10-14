//
//  VibeiOSSceneDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSSceneDelegate.h"
#import "AudioTrack.h"
#import "BrowserRules.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "RecentsStore.h"
#import "RootViewController.h"

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
    // The card's strip layout needs room for 150pt art and insets. Nil on iPhone.
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
    [LocationStore.shared restorePersistedFolders];
    if (connectionOptions.URLContexts.count > 0) {
        [_playback handleOpenURLContexts:connectionOptions.URLContexts];
    }
    else {
        [_playback restorePersistedSession];
    }
    // After the launch's open, so the playlist holds what it brought back.
    __weak PlaybackController *weakPlayback = _playback;
    [_playback performWhenLaunchOpenSettled:^{
        [VibeiOSSceneDelegate pruneLinksKeptBy:weakPlayback];
    }];
}

// The playlist is the session's base and its additions, as the launch
// restored them. The prune itself runs on the store's queue.
+ (void)pruneLinksKeptBy:(PlaybackController *)playback {
    if (!playback) {
        return;
    }
    [LinkStore.shared pruneKeepingTracks:playback.playlist.tracks
                              recentURLs:VibeRecentItemURLs(RecentsStore.shared.recentItems)];
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
+ (nullable VibeiOSSceneDelegate *)connectedDelegate {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene.delegate isKindOfClass:VibeiOSSceneDelegate.class]) {
            VibeiOSSceneDelegate *delegate = (VibeiOSSceneDelegate *)scene.delegate;
            if (delegate.playback) {
                return delegate;
            }
        }
    }
    return nil;
}

+ (PlaybackController *)connectedPlayback {
    return [self connectedDelegate].playback;
}

+ (void)showPlaylist {
    VibeiOSSceneDelegate *delegate = [self connectedDelegate];
    if (delegate) {
        [delegate->_root showPlaylist];
    }
}

@end
