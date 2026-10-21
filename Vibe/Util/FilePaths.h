//
//  FilePaths.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A path's spelling for comparison: standardized, and without the aliases
// VibeAliasFreePath drops. Spelling alone, so safe on any thread for any path.
FOUNDATION_EXPORT NSString *_Nullable VibeComparablePath(NSString *_Nullable path);

// /tmp, /var and /etc are symlinks into /private, and every path also exists
// under the data volume's firmlink: the spelling with neither, from the string
// alone.
FOUNDATION_EXPORT NSString *VibeAliasFreePath(NSString *path);

NS_ASSUME_NONNULL_END
