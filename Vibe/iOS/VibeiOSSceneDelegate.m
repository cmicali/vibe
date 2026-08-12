//
//  VibeiOSSceneDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSSceneDelegate.h"
#import "PlayerViewController.h"

@implementation VibeiOSSceneDelegate

- (void)scene:(UIScene *)scene
        willConnectToSession:(UISceneSession *)session
                     options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    PlayerViewController *player = [[PlayerViewController alloc] init];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = player;
    [self.window makeKeyAndVisible];
    if (connectionOptions.URLContexts.count > 0) {
        // Cold launch from "Open in Vibe": the view must exist before the
        // player screen can adopt the URL.
        [player loadViewIfNeeded];
        [player handleOpenURLContexts:connectionOptions.URLContexts];
    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:[PlayerViewController class]]) {
        [(PlayerViewController *)root handleOpenURLContexts:URLContexts];
    }
}

@end
