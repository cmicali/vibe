//
//  FolderArtFileIO.h
//  Vibe
//
//  The resolver's file probe and bounded read. Never on main: a cover
//  on a sleeping disk or a dataless placeholder blocks.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reject oversized covers before allocating their input buffer.
static const unsigned long long kMaxArtFileBytes = 20ull * 1024 * 1024;

// A regular file of plausible size. lstat here and O_NOFOLLOW below: a link
// could point outside the folder's grant, so a symlinked cover is not found.
BOOL VibeFolderArtFileInfo(NSString *path, unsigned long long * _Nullable size);

NSData * _Nullable VibeReadFolderArt(NSString *path);

NS_ASSUME_NONNULL_END
