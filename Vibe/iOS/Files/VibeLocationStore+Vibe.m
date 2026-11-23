//
//  VibeLocationStore+Vibe.m
//  Vibe (iOS)
//

#import "VibeLocationStore+Vibe.h"

#import "DropboxMirror+Shared.h"
#import "FilePaths.h"
#import "VibeStrings.h"

@implementation VibeLocationStore (Vibe)

+ (void)installVibeWithDeviceModelName:(NSString *)modelName {
    NSString *documentsPath = VibeComparablePath(VibeLocationStore.containerDocumentsURL.path);
    NSString *device = [NSString stringWithFormat:STR_BROWSER_ON_DEVICE, modelName];
    // TRAP: shipped keys. Changing either loses every user's Locations.
    [VibeLocationStore configureWithBookmarksKey:@"VibeiOSSearchFolderBookmarks"
                                 suppressionsKey:@"VibeiOSSearchFolderRestoreSuppressions"
                                       rootNamer:^NSString *(NSURL *url, NSString *path) {
        // The account's mirror directory is named for its Dropbox account id.
        if ([[DropboxMirror.shared derivedDropboxPathForURL:url] isEqualToString:@""]) {
            return VibeNotLocalized(@"Dropbox");
        }
        return [path isEqualToString:documentsPath] ? device : nil;
    }];
}

@end
