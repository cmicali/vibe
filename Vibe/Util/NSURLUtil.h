//
//  NSURLUtil.h
//  Vibe
//

#import <Foundation/Foundation.h>

#include <sys/stat.h>

#import "FolderOpenSort.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;

// The end of every remote placeholder's part file name.
extern NSString *const VibeRemotePlaceholderPartSuffix;

// A path's spelling for comparison: standardized, and without the /private
// that one API adds to /var and another drops.
NSString *VibeComparablePath(NSString *path);

// Under the remote backend's root; no disk, and NO with no root installed. For a caller that has already stat'ed the file.
FOUNDATION_EXPORT BOOL VibePathIsUnderRemotePlaceholderRoot(NSString *path);

// The remote placeholder's mode: see setRemotePlaceholderRoot:.
static inline BOOL VibeFileModeIsRemotePlaceholder(mode_t mode) {
    return S_ISREG(mode) && (mode & S_IRUSR) == 0;
}

// Asks the user to grant the folder a playlist file's entries live in, and
// answers whether they did. Runs on an expansion worker and must block until
// answered. Unset (as in tests), unreadable entries are skipped.
typedef BOOL (^VibePlaylistFolderGrantHandler)(NSURL *playlistURL);

// What an expansion saw of the folders it touched, for the folder-art
// resolver. Unset, it is discarded. Both are called on an expansion worker.

// Covers keyed by directory, spelled as on disk. Every directory was listed in
// full, so "no cover" is an answer. Once per top-level folder expanded.
typedef void (^VibeWalkedDirectoriesHandler)(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *artFilenameByDirectory);

// The loose files' folders in a bulk open, unlisted: only that a listing each
// is a fair price. Once per expansion; never for a single file.
typedef void (^VibeBulkOpenDirectoriesHandler)(NSSet<NSString *> *directories);


@interface NSURLUtil : NSObject

+ (void)setPlaylistFolderGrantHandler:(nullable VibePlaylistFolderGrantHandler)handler;
+ (void)setWalkedDirectoriesHandler:(nullable VibeWalkedDirectoriesHandler)handler;
+ (void)setBulkOpenDirectoriesHandler:(nullable VibeBulkOpenDirectoriesHandler)handler;

// YES for a cloud placeholder whose data is not local. Reading one blocks
// until the provider materializes it, so every background reader asks first.
// One stat of SF_DATALESS, ~2us and materializing nothing; NO when the stat
// fails, since unknown is not dataless. A remote placeholder (below) answers
// YES too.
+ (BOOL)isDatalessFile:(NSURL *)url;

// Under the remote backend's root (iOS: the Dropbox mirror, installed through
// CloudFileMaterializer's setRemoteRoot:fetch:read:), a regular file its
// owner may not read is a placeholder for a remote file: its stat — size,
// mtime, the cache key — is the remote file's, and any direct open fails
// instead of reading zeros. Anywhere else, and on the mac, which installs no
// root, an unreadable file is merely unreadable.
+ (void)setRemotePlaceholderRoot:(nullable NSURL *)root;
+ (BOOL)isRemotePlaceholderFile:(NSURL *)url;

// A remote placeholder whose tags and art TagLib reads by range
// (PlayableExtensions.tagParsed); any other needs its whole file. The tag
// scan and the art loader both decide by it.
+ (BOOL)readsRemotePlaceholderByRange:(NSURL *)url;

// Where a remote placeholder's bytes stream in until they replace it: a
// hidden sibling, so no listing shows it, whose size is the transfer's
// progress (DownloadProgressMonitor's poll reads it). Its name ends in
// VibeRemotePlaceholderPartSuffix.
+ (NSURL *)remotePlaceholderPartURL:(NSURL *)url;

// Expands folders and top-level playlist files to rows and filters to playable
// extensions, on a four-wide queue; callers order overlapping results
// (OpenRequestCoordinator). A file is one row; a CUE sheet — opened, or met in
// a walked folder, where it claims its files — is a row per track. folderCount
// is how many top-level URLs were directories. Completion runs on main.
//
// sort orders each expanded folder's audio only: top-level URLs and a playlist
// file's entries keep the order the user gave.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                   sortedBy:(VibeFolderOpenSort)sort
                 completion:(void (^)(NSArray<AudioTrack *> *rows, NSUInteger folderCount))completion;

// Common/PlayableExtensions' set.
+ (NSSet<NSString *> *)supportedExtensions;

// One file as its rows: a CUE sheet's tracks, a large local FLAC's embedded
// cue sheet, else the file whole. Every expansion mints a file's rows here,
// so a sheet inside a file applies wherever the file is opened.
+ (NSArray<AudioTrack *> *)rowsForFile:(NSURL *)url;

// The folder's non-empty audio files as rows, non-recursive, hidden entries
// skipped; a CUE sheet among them stands in for its files, as in a walk.
// Synchronous. sort is a parameter because this layer may not read a setting.
+ (NSArray<AudioTrack *> *)rowsInDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The walk's own order and the keys a listing must prefetch for it, so a
// directory shown elsewhere lists in the order it opens in.
+ (NSArray<NSURLResourceKey> *)listingKeysForSort:(VibeFolderOpenSort)sort;
+ (void)sortURLs:(NSMutableArray<NSURL *> *)urls by:(VibeFolderOpenSort)sort;
@end

NS_ASSUME_NONNULL_END
