//
//  FolderAccessRules.h
//  Vibe
//
//  Path-coverage rules for the granted-folder store, as static inlines so the
//  tests reach them without the manager, the sandbox or NSUserDefaults.
//

#import <Foundation/Foundation.h>

// Whether path lies at or under root. TRAP: coverage has two spellings and the
// callers need different ones. This one is case-sensitive: both sides are
// canonical on-disk spellings by the time noteOpenedURLs: compares them, and
// on a case-SENSITIVE volume a loose match here would skip a bookmark the app
// actually needs.
static inline BOOL VibePathIsUnderFolder(NSString *path, NSString *root) {
    if (path.length == 0 || root.length == 0) {
        return NO;
    }
    return [path isEqualToString:root]
            || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

// The same question for an open that has NOT been canonicalized — a URL
// straight off Launch Services or a pasteboard. TRAP: deliberately
// case-insensitive, the other spelling, which is the safe direction here:
// over-matching only makes an open wait for a grant it did not need, while
// under-matching walks a path whose grant has not been restored yet.
static inline BOOL VibeUncanonicalPathIsUnderFolder(NSString *path, NSString *root) {
    if (path.length == 0 || root.length == 0) {
        return NO;
    }
    return [path caseInsensitiveCompare:root] == NSOrderedSame
            || [path.lowercaseString hasPrefix:
                    [root stringByAppendingString:@"/"].lowercaseString];
}
