//
//  VibeiOSAppDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSAppDelegate.h"
#import "AppSettings.h"
#import "CloudFileMaterializer.h"
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
    // here a mirror placeholder is dataless and opening it downloads it.
    [CloudFileMaterializer setRemoteFetch:^BOOL(NSURL *url, void (^onCancel)(dispatch_block_t),
                                                NSError **error) {
        return [DropboxMirror.shared fetchPlaceholderAtURL:url onCancel:onCancel error:error];
    }];
    // A placeholder's tags are read by range, so opening a folder does not
    // download it whole.
    CloudFileMaterializer.remoteRead = ^NSData *(NSURL *url, uint64_t offset, uint64_t length,
                                                 NSError **error) {
        return [DropboxMirror.shared readPlaceholderAtURL:url offset:offset length:length error:error];
    };
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    return YES;
}

@end
