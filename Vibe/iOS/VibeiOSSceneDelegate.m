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
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[PlayerViewController alloc] init];
    [self.window makeKeyAndVisible];
}

@end
