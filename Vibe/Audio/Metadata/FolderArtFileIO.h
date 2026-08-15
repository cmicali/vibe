//
//  FolderArtFileIO.h
//  Vibe
//
//  The two raw file operations the folder-art resolver performs on a candidate
//  cover, kept apart from it because both are POSIX rather than Foundation and
//  both carry a trap that is easy to lose in a longer file.
//
//  Neither ever runs on the main thread: a cover can sit on a sleeping disk or
//  an unmaterialized file-provider placeholder, and both calls block.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A cover is a few hundred KB. Past this it is a scan or a print master, and
// reading it costs more than the art is worth — the folder counts as having
// none, permanently, like any other settled answer.
static const unsigned long long kMaxArtFileBytes = 20ull * 1024 * 1024;

// YES when path is a regular file of a plausible size for a cover, reporting
// that size. lstat rather than stat, and O_NOFOLLOW on the read below:
// following a link would read whatever it points at, which the folder's grant
// never covered. The price is that a symlinked cover.jpg is not found.
BOOL VibeFolderArtFileInfo(NSString *path, unsigned long long * _Nullable size);

// The bytes of the cover at path, or nil for anything that is not a readable
// regular file of a plausible size.
NSData * _Nullable VibeReadFolderArt(NSString *path);

NS_ASSUME_NONNULL_END
