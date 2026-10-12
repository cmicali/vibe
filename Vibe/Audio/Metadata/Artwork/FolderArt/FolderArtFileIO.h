//
//  FolderArtFileIO.h
//  Vibe
//
//  The resolver's two POSIX calls on a candidate cover. Never on main: a cover
//  on a sleeping disk or a dataless placeholder blocks.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Past this it is a scan or a print master; the folder settles as having none.
static const unsigned long long kMaxArtFileBytes = 20ull * 1024 * 1024;

// A regular file of plausible size. lstat here and O_NOFOLLOW below: a link
// could point outside the folder's grant, so a symlinked cover is not found.
BOOL VibeFolderArtFileInfo(NSString *path, unsigned long long * _Nullable size);

NSData * _Nullable VibeReadFolderArt(NSString *path);

NS_ASSUME_NONNULL_END
