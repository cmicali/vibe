//
//  NetworkReadAheadRules.h
//  Vibe
//
//  Which files read ahead (NetworkReadAhead.m), from a mount table alone.
//

#import <Foundation/Foundation.h>
#import "FilePaths.h"

#include <sys/mount.h>

NS_ASSUME_NONNULL_BEGIN

// A spelling for comparing a mount's name and a path, from the string alone:
// VibeAliasFreePath's, ending in exactly one slash. The slash makes a prefix
// whole components. It also spells the data volume's own mount as the root.
static inline NSString *VibeMountSpelling(NSString *path) {
    NSUInteger end = path.length;
    while (end > 0 && [path characterAtIndex:end - 1] == '/') {
        end--;
    }
    return VibeAliasFreePath([[path substringToIndex:end] stringByAppendingString:@"/"]);
}

// The index of the mount holding `path` in a getfsstat table: the longest
// mount name that is a whole-component prefix of it. -1 for none.
static inline int VibeMountHoldingPath(const struct statfs *_Nullable mounts, int count, NSString *path) {
    NSString *spelledPath = VibeMountSpelling(path);
    int best = -1;
    NSUInteger bestLength = 0;
    for (int i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:mounts[i].f_mntonname];
        NSString *mount = name ? VibeMountSpelling(name) : nil;
        if (mount && [spelledPath hasPrefix:mount] && (best < 0 || mount.length > bestLength)) {
            best = i;
            bestLength = mount.length;
        }
    }
    return best;
}

// The network mount a file reads ahead from: the mount holding it, when that
// is a network one. A network mount is any mount not flagged MNT_LOCAL. NULL
// is the direct road, as is no mount or an empty table.
static inline const struct statfs *_Nullable VibeMountReadsAhead(const struct statfs *_Nullable mounts, int count,
                                                                 NSString *path) {
    int index = VibeMountHoldingPath(mounts, count, path);
    return index >= 0 && (mounts[index].f_flags & MNT_LOCAL) == 0 ? &mounts[index] : NULL;
}

NS_ASSUME_NONNULL_END
