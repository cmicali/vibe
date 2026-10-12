//
//  PlaceholderFiles.h
//  Vibe
//

#import <Foundation/Foundation.h>

#include <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

// The end of every remote placeholder's part file name.
extern NSString *const VibeRemotePlaceholderPartSuffix;

// Under any remote backend's root, from the path's spelling alone: no disk,
// and NO with no root installed. Ask it before a stat. A file under no root
// then pays none.
FOUNDATION_EXPORT BOOL VibePathIsUnderRemotePlaceholderRoot(NSString *path);

// The remote placeholder's mode: see setRemotePlaceholderRoots:.
static inline BOOL VibeFileModeIsRemotePlaceholder(mode_t mode) {
    return S_ISREG(mode) && (mode & S_IRUSR) == 0;
}


@interface PlaceholderFiles : NSObject

// YES for a cloud placeholder whose data is not local. Reading one blocks
// until the provider materializes it, so every background reader asks first.
// One stat of SF_DATALESS, ~2us and materializing nothing; NO when the stat
// fails, since unknown is not dataless. A remote placeholder (below) answers
// YES too.
+ (BOOL)isDatalessFile:(NSURL *)url;

// Under a remote backend's root (the Links store, and on iOS the Dropbox
// mirror), a regular file its owner may not read is a placeholder for a
// remote file. Its stat is the remote file's: size, mtime, and the cache
// key. Any direct open fails instead of reading zeros. Anywhere else an
// unreadable file is merely unreadable.
// CloudFileMaterializer's setRemoteRoot:fetch:read:availability: keeps the
// roots in step with its backends.
+ (void)setRemotePlaceholderRoots:(NSArray<NSURL *> *)roots;
+ (BOOL)isRemotePlaceholderFile:(NSURL *)url;

// A remote placeholder whose tags and art TagLib reads by range
// (PlayableExtensions.tagParsed); any other needs its whole file. The tag
// scan and the art loader both decide by it.
+ (BOOL)readsRemotePlaceholderByRange:(NSURL *)url;

// Where a remote placeholder's bytes stream in until they replace it: a
// hidden sibling, so no listing shows it. Its name ends in
// VibeRemotePlaceholderPartSuffix.
+ (NSURL *)remotePlaceholderPartURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
