//
//  VibeiOSAppDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSAppDelegate.h"
#import "AppSettings.h"
#import "AudioError.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DropboxMirror.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "NSBundle+BuildInfo.h"
#import "PINCache+VibeAudioCache.h"
#if DEBUG
#import "DebugiOSEntry.h"
#endif

@implementation VibeiOSAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    VibeLogBuildProvenance();
    // Before the player exists, so every play-path error carries the app's domain.
    VibeAudioErrorSetDomain(NSBundle.mainBundle.bundleIdentifier);
    // Before any scene names a folder.
    LocationStore.deviceModelName = UIDevice.currentDevice.localizedModel;
    // Before the scene restores a playlist, which may name a mirror file or a
    // link. From here their placeholders are dataless. Opening one downloads
    // it, and its tags are read by range. Opening a folder then does not
    // download it whole.
    [DropboxMirror.shared installAsRemoteBackend];
    [LinkStore.shared installAsRemoteBackend];
    // Off main: the token refresh and the connections the first play would
    // otherwise open, once, and nothing without an account.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [DropboxMirror.shared.client warmUp];
    });
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    [PINCache removeOtherAudioCacheVersionsKeeping:@[AudioTrackMetadataCache.cacheName, AudioWaveformCache.cacheName]
                                          rootPath:nil
                                        completion:nil];
    [self copyWelcomeTrackIfFirstLaunch];
    return YES;
}

// Once per install, so a user who deletes it from On My iPhone keeps it gone.
- (void)copyWelcomeTrackIfFirstLaunch {
    if (AppSettings.sharedInstance.welcomeTrackSpent) {
        return;
    }
    AppSettings.sharedInstance.welcomeTrackSpent = YES;
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
