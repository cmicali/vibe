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
    // here a mirror placeholder is dataless, opening it downloads it, and its
    // tags are read by range, so opening a folder does not download it whole.
    [CloudFileMaterializer setRemoteRoot:DropboxMirror.shared.rootURL
                                   fetch:^BOOL(NSURL *url, void (^onCancel)(dispatch_block_t),
                                               NSError **error) {
        return [DropboxMirror.shared fetchPlaceholderAtURL:url onCancel:onCancel error:error];
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        return [DropboxMirror.shared readPlaceholderAtURL:url offset:offset length:length error:error];
    } availability:nil];
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    return YES;
}

@end
