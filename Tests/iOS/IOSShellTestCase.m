//
//  IOSShellTestCase.m
//

#import "IOSShellTestCase.h"

#import <objc/runtime.h>
#include <stdlib.h>

#import "DropboxClient.h"
#import "DropboxMirror.h"
#import "DropboxStubProtocol.h"
#import "FavoritesStore.h"
#import "FolderSession.h"
#import "LocationStore.h"
#import "RecentsStore.h"
#import "TestFilesystemGuard.h"

// In the guard's per-pid root (TestFilesystemGuard.m), which goes at exit.
// The guard redirects LinkStore.shared for every class.
static void VibeInstallShellSingletons(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses = @[DropboxStubProtocol.class];
        // No keychain service: the account lives in memory, and none is adopted.
        DropboxClient *client = [[DropboxClient alloc] initWithAppKey:@"testkey" keychainService:nil
                                                        configuration:configuration];
        DropboxMirror *mirror = [[DropboxMirror alloc]
                initWithClient:client
                       rootURL:[NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:@"Dropbox"]
                                          isDirectory:YES]
                downloadBudget:8];
        method_setImplementation(class_getClassMethod(DropboxMirror.class, @selector(shared)),
                                 imp_implementationWithBlock(^DropboxMirror *(id self) { return mirror; }));
    });
}

@implementation IOSShellTestCase

- (void)setUp {
    [super setUp];
    VibeInstallShellSingletons();
    LocationStore.deviceModelName = @"iPhone";
    // The singletons outlive a test. Emptied through their own API, which
    // also removes their stored keys.
    while (FavoritesStore.shared.favorites.count > 0) {
        [FavoritesStore.shared removeFavoriteAtIndex:0];
    }
    while (LocationStore.shared.folderURLs.count > 0) {
        [LocationStore.shared removeFolderAtIndex:0];
    }
    [RecentsStore.shared clearRecentItems];
    [[[FolderSession alloc] init] clearSession];

    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"IOSShellTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES
                                             attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
}

- (void)tearDown {
    // Delivers what is already queued on main before its folder goes.
    VibeSpinFor(0);
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    [super tearDown];
}

- (NSURL *)folder:(NSString *)relativePath {
    NSURL *url = [_root URLByAppendingPathComponent:relativePath isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return url;
}

- (NSURL *)file:(NSString *)relativePath {
    NSURL *url = [_root URLByAppendingPathComponent:relativePath isDirectory:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    [[relativePath dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES];
    return url;
}

- (BOOL)eventually:(BOOL (^)(void))condition {
    return VibeSpinUntil(condition);
}

- (void)settle {
    VibeSpinFor(kVibeTestNegativeWindow);
}

@end
