//
//  FolderAccessRules.h
//  Vibe
//
//  Path-coverage rules, testable without the manager or the sandbox.
//

#import <Foundation/Foundation.h>

// TRAP: coverage has two spellings and the callers need different ones. This
// one is case-sensitive: noteOpenedURLs: compares canonical spellings, and a
// loose match on a case-sensitive volume would skip a bookmark it needs.
static inline BOOL VibePathIsUnderFolder(NSString *path, NSString *root) {
    if (path.length == 0 || root.length == 0) {
        return NO;
    }
    return [path isEqualToString:root]
            || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

// TRAP: for a path that was NOT canonicalized (Launch Services, a pasteboard,
// a track URL), so deliberately case-insensitive. Under-matching would walk
// a path before its grant is restored, or refuse a readable folder.
static inline BOOL VibeUncanonicalPathIsUnderFolder(NSString *path, NSString *root) {
    if (path.length == 0 || root.length == 0) {
        return NO;
    }
    return [path caseInsensitiveCompare:root] == NSOrderedSame
            || [path.lowercaseString hasPrefix:
                    [root stringByAppendingString:@"/"].lowercaseString];
}
