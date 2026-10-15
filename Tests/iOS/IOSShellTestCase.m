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
#import "LinkClient.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "RecentsStore.h"

static LinkStore *sLinkStore;

// Each in the guard's per-pid root (TestFilesystemGuard.m), which goes at exit.
static void VibeInstallShellSingletons(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *processRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"VibeTests-%d", getpid()]];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses = @[DropboxStubProtocol.class];
        // No keychain service: the account lives in memory, and none is adopted.
        DropboxClient *client = [[DropboxClient alloc] initWithAppKey:@"testkey" keychainService:nil
                                                        configuration:configuration];
        DropboxMirror *mirror = [[DropboxMirror alloc]
                initWithClient:client
                       rootURL:[NSURL fileURLWithPath:[processRoot stringByAppendingPathComponent:@"Dropbox"]
                                          isDirectory:YES]
                downloadBudget:8];
        LinkClient *linkClient = [[LinkClient alloc] initWithConfiguration:configuration];
        sLinkStore = [[LinkStore alloc]
                initWithClient:linkClient
                       rootURL:[NSURL fileURLWithPath:[processRoot stringByAppendingPathComponent:@"Links"]
                                          isDirectory:YES]];
        LinkStore *links = sLinkStore;
        method_setImplementation(class_getClassMethod(DropboxMirror.class, @selector(shared)),
                                 imp_implementationWithBlock(^DropboxMirror *(id self) { return mirror; }));
        method_setImplementation(class_getClassMethod(LinkStore.class, @selector(shared)),
                                 imp_implementationWithBlock(^LinkStore *(id self) { return links; }));
    });
}

@implementation IOSShellTestCase

+ (LinkStore *)linkStore {
    VibeInstallShellSingletons();
    return sLinkStore;
}

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
    // Lets a mint or a landing posted to main finish before its folder goes.
    [self settle];
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
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

- (void)settle {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
}

@end
