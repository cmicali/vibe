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
    LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    VibeLogBuildProvenance();
    [[AppSettings sharedInstance] applicationDidFinishLaunching];
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    return YES;
}

// Scene configuration comes from the Info.plist UIApplicationSceneManifest.

@end
