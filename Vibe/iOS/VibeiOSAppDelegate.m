//
//  VibeiOSAppDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSAppDelegate.h"
#import "NSBundle+BuildInfo.h"
#if DEBUG
#import "DebugCommands.h"
#endif

@implementation VibeiOSAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    NSBundle *bundle = NSBundle.mainBundle;
    LogInfo(@"Vibe %@ starting", bundle.vibeVersionString);
    LogInfo(@"    Source: %@", bundle.vibeGitString);
    LogInfo(@"     Built: %@", bundle.vibeBuildTimeString);
    [[AppSettings sharedInstance] applicationDidFinishLaunching];
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    return YES;
}

// Scene configuration comes from the Info.plist UIApplicationSceneManifest.

@end
