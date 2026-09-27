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
        BOOL isDefault = [self isDefaultAppForAllFileTypes];
        run_on_main_thread({
            completion(isDefault);
        });
    });
}

+ (BOOL)isDefaultAppForAllFileTypes {
    NSArray<UTType *> *types = DocumentTypes.declaredFileTypes;
    if (types.count == 0) {
        return NO;
    }
    // Launch Services registers by identifier and answers with its preferred
    // copy, which may not be the running one, so both count. Comparing
    // identifiers would mean reading a foreign Info.plist, which the sandbox
    // denies.
    NSMutableSet<NSString *> *ourLocations = [NSMutableSet new];
    AddResolvedPath(ourLocations, NSBundle.mainBundle.bundleURL);
    AddResolvedPath(ourLocations, [NSWorkspace.sharedWorkspace
                                  URLForApplicationWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]);
    for (UTType *type in types) {
        NSURL *handler = [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:type];
        NSString *handlerPath = ResolvedPath(handler);
        if (!handlerPath || ![ourLocations containsObject:handlerPath]) {
            return NO;
        }
    }
    return YES;
}

+ (void)makeDefaultApp {
    [self setDefaultAppForTypes:DocumentTypes.declaredFileTypes atIndex:0];
}

#pragma mark - Private

// One type at a time: each request can raise its own confirmation panel, and
// they must not stack. The first failure, likeliest a refusal, ends the walk.
+ (void)setDefaultAppForTypes:(NSArray<UTType *> *)types atIndex:(NSUInteger)index {
    if (index >= types.count) {
        return;
    }
    UTType *type = types[index];
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:NSBundle.mainBundle.bundleURL
                                         toOpenContentType:type
                                         completionHandler:^(NSError *error) {
        if (error) {
            LogWarn(@"Could not become the default app for %@: %@", type.identifier, error);
            return;
        }
        LogInfo(@"Registered as the default app for %@", type.identifier);
        [self setDefaultAppForTypes:types atIndex:index + 1];
    }];
}

@end
