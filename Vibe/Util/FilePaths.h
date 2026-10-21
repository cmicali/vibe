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

// One spelling of a file's URL, for every loader identity: the claim, the
// transfer, the parse, and the source key. A file URL is spelled as
// VibeComparablePath spells its path, and any other URL by its absoluteString.
FOUNDATION_EXPORT NSString *VibeStandardizedAudioOpenPath(NSURL *url);

NS_ASSUME_NONNULL_END
