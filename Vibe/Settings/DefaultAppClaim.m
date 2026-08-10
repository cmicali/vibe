//
//  DefaultAppClaim.m
//  Vibe
//

#import "DefaultAppClaim.h"
#import "DocumentTypes.h"
#import <AppKit/AppKit.h>

// App URLs come back from different sources, our own bundle and Launch
// Services, so compare resolved paths rather than URLs: trailing slashes and
// symlinked prefixes differ where the location does not.
static NSString *ResolvedPath(NSURL *_Nullable url) {
    return url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
}

static void AddResolvedPath(NSMutableSet<NSString *> *paths, NSURL *_Nullable url) {
    NSString *path = ResolvedPath(url);
    if (path) {
        [paths addObject:path];
    }
}

@implementation DefaultAppClaim

+ (BOOL)isDefaultAppForAllFileTypes {
    NSArray<UTType *> *types = DocumentTypes.declaredFileTypes;
    if (types.count == 0) {
        return NO; // nothing declared: never claim to be the default
    }
    // Which on-disk locations count as us: the running copy, plus whichever
    // copy Launch Services prefers for our bundle identifier. Launch Services
    // registers by identifier and answers with its preferred copy, so right
    // after a successful registration it regularly names a different path from
    // the running one — a build directory against /Applications — and
    // comparing bundleURL alone reports "not the default" moments after the
    // system said yes. Comparing identifiers directly is not an option
    // instead, since that means reading a foreign bundle's Info.plist, which
    // the App Sandbox denies.
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

// One type at a time, recursively. A request can raise its own system
// confirmation panel, and firing all eight at once would stack eight panels on
// the user. The first failure ends the walk, because the likeliest error is
// the user declining that panel, and re-asking for the remaining types would
// be nagging. The new default takes a moment to show up in
// URLForApplicationToOpenContentType: after the system reports success.
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
