//
//  DefaultAppRegistration.m
//  Vibe
//

#import "DefaultAppRegistration.h"
#import "DocumentTypes.h"
#import <AppKit/AppKit.h>

// Our bundle and Launch Services spell one location differently (trailing
// slashes, symlinked prefixes).
static NSString *ResolvedPath(NSURL *_Nullable url) {
    return url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
}

static void AddResolvedPath(NSMutableSet<NSString *> *paths, NSURL *_Nullable url) {
    NSString *path = ResolvedPath(url);
    if (path) {
        [paths addObject:path];
    }
}

@implementation DefaultAppRegistration

+ (void)checkIsDefaultAppForAllFileTypes:(void (^)(BOOL isDefault))completion {
    // URLForApplicationToOpenContentType: is a synchronous XPC lookup per type.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<UTType *> *claimed = [self claimedTypes];
        BOOL isDefault = claimed.count > 0 && [self typesNotYetOursAmong:claimed].count == 0;
        run_on_main_thread({
            completion(isDefault);
        });
    });
}

+ (void)makeDefaultAppWithCompletion:(void (^)(BOOL refused))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Already ours raises no prompt for nothing.
        NSArray<UTType *> *types = [self typesNotYetOursAmong:[self claimedTypes]];
        [self requestTypes:types atIndex:0 failures:0 declined:NO completion:completion];
    });
}

#pragma mark - Private

// Finder opens a file by the type its extension resolves to, which another
// app's declaration can make a type of its own, so that type is claimed
// beside the declared one. Only one conforming to the declaration counts:
// .mp4 resolves to video, which public.mpeg-4-audio does not claim.
+ (NSArray<UTType *> *)claimedTypes {
    NSMutableOrderedSet<UTType *> *types = [NSMutableOrderedSet new];
    for (UTType *declared in DocumentTypes.defaultHandlerTypes) {
        [types addObject:declared];
        for (NSString *extension in declared.tags[UTTagClassFilenameExtension]) {
            UTType *resolved = [UTType typeWithFilenameExtension:extension];
            if (resolved && [resolved conformsToType:declared]) {
                [types addObject:resolved];
            }
        }
    }
    return types.array;
}

+ (NSArray<UTType *> *)typesNotYetOursAmong:(NSArray<UTType *> *)types {
    // Launch Services registers by identifier and answers with its preferred
    // copy, which may not be the running one, so both count. Comparing
    // identifiers would mean reading a foreign Info.plist, which the sandbox
    // denies.
    NSMutableSet<NSString *> *ourLocations = [NSMutableSet new];
    AddResolvedPath(ourLocations, NSBundle.mainBundle.bundleURL);
    AddResolvedPath(ourLocations, [NSWorkspace.sharedWorkspace
                                  URLForApplicationWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]);
    NSMutableArray<UTType *> *notOurs = [NSMutableArray new];
    for (UTType *type in types) {
        NSString *handlerPath = ResolvedPath([NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:type]);
        if (!handlerPath || ![ourLocations containsObject:handlerPath]) {
            [notOurs addObject:type];
        }
    }
    return notOurs;
}

// One type at a time: each request can raise its own confirmation panel, and
// they must not stack. TRAP: a failure ends only its own type — the user
// keeping Books for one format once ended the walk there, silently, leaving
// every later format unclaimed.
+ (void)requestTypes:(NSArray<UTType *> *)types atIndex:(NSUInteger)index
            failures:(NSUInteger)failures declined:(BOOL)declined
          completion:(void (^)(BOOL refused))completion {
    if (index >= types.count) {
        BOOL refused = types.count > 0 && failures == types.count && !declined;
        run_on_main_thread({
            completion(refused);
        });
        return;
    }
    UTType *type = types[index];
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:NSBundle.mainBundle.bundleURL
                                         toOpenContentType:type
                                         completionHandler:^(NSError *error) {
        BOOL userDeclined = NO;
        if (error) {
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
            userDeclined = underlying.code == userCanceledErr;
            LogWarn(@"Could not become the default app for %@: %@", type.identifier, error);
        }
        else {
            LogInfo(@"Registered as the default app for %@", type.identifier);
        }
        [self requestTypes:types atIndex:index + 1 failures:failures + (error ? 1 : 0)
                  declined:declined || userDeclined completion:completion];
    }];
}

@end
