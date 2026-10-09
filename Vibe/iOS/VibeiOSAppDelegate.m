//
//  VibeiOSAppDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSAppDelegate.h"
#import "AppSettings.h"
#import "DropboxMirror.h"
#import "NSBundle+BuildInfo.h"
#if DEBUG
#import "DebugCommands.h"
#endif

@implementation VibeiOSAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    VibeLogBuildProvenance();
    // Before the scene restores a playlist, which may lie in the mirror: from
    // here a mirror placeholder is dataless, opening it downloads it, and its
    // tags are read by range, so opening a folder does not download it whole.
    [DropboxMirror.shared installAsRemoteBackend];
    // Off main: the token refresh and the connections the first play would
    // otherwise open, once, and nothing without an account.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [DropboxMirror.shared.client warmUp];
    });
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    [self copyWelcomeTrackIfFirstLaunch];
    return YES;
}

// Once per install, so a user who deletes it from On My iPhone keeps it gone.
- (void)copyWelcomeTrackIfFirstLaunch {
    if (AppSettings.sharedInstance.welcomeTrackLoaded) {
        return;
    }
    AppSettings.sharedInstance.welcomeTrackLoaded = YES;
    NSURL *source = [NSBundle.mainBundle URLForResource:@"vibe-theme" withExtension:@"mp3"];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    if (!source || !documents) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSURL *target = [documents URLByAppendingPathComponent:source.lastPathComponent];
        if (![NSFileManager.defaultManager copyItemAtURL:source toURL:target error:&error]) {
            LogWarn(@"Welcome track not copied: %@", error.localizedDescription);
        }
    });
}

@end
