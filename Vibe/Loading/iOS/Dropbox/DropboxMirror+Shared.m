//
//  DropboxMirror+Shared.m
//  Vibe (iOS)
//

#import "DropboxMirror+Shared.h"

#import "SettingsRules.h"

NSString *const VibeDropboxDownloadBudgetKey = @"VibeiOSDropboxDownloadBudget";

// TRAP: each of these names data a signed-in user already has. A change signs
// the user out, or orphans every listed folder's index.
static NSString *const kAppKeyInfoKey = @"VibeDropboxAppKey";
static NSString *const kKeychainService = @"com.commonwealthrecordings.Vibe.dropbox";
static NSString *const kIndexAttribute = @"com.commonwealthrecordings.vibe.dropbox";

@implementation DropboxMirror (Shared)

+ (DropboxMirror *)shared {
    static DropboxMirror *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *appKey = [NSBundle.mainBundle objectForInfoDictionaryKey:kAppKeyInfoKey];
        NSAssert(appKey.length > 0, @"%@ missing from Info.plist", kAppKeyInfoKey);
        DropboxClient *client = [[DropboxClient alloc] initWithAppKey:appKey ?: @""
                                                      keychainService:kKeychainService
                                                        configuration:NSURLSessionConfiguration.defaultSessionConfiguration];
        NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:NULL];
        NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:VibeDropboxDownloadBudgetKey];
        shared = [[DropboxMirror alloc] initWithClient:client
                                               rootURL:[support URLByAppendingPathComponent:@"Dropbox"
                                                                                isDirectory:YES]
                                        indexAttribute:kIndexAttribute
                                        downloadBudget:kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(saved)]];
    });
    return shared;
}

@end
