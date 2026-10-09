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

// A path's spelling for comparison: standardized, and without the aliases
// VibeAliasFreePath drops. Spelling alone, so safe on any thread for any path.
NSString *_Nullable VibeComparablePath(NSString *_Nullable path);

// /tmp, /var and /etc are symlinks into /private, and every path also exists
// under the data volume's firmlink: the spelling with neither, from the string
// alone.
NSString *VibeAliasFreePath(NSString *path);

// Under any remote backend's root, from the path's spelling alone: no disk,
// and NO with no root installed. Ask it before a stat. A file under no root
// then pays none.
FOUNDATION_EXPORT BOOL VibePathIsUnderRemotePlaceholderRoot(NSString *path);

// The remote placeholder's mode: see setRemotePlaceholderRoots:.
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

// Under a remote backend's root (iOS: the Dropbox mirror), a regular file its
// owner may not read is a placeholder for a remote file. Its stat is the
// remote file's: size, mtime, and the cache key. Any direct open fails instead
// of reading zeros. Anywhere else an unreadable file is merely unreadable.
// CloudFileMaterializer's setRemoteRoot:fetch:read:availability: keeps the
// roots in step with its backends. The single-root setter installs exactly
// that root, or none for nil.
+ (void)setRemotePlaceholderRoots:(NSArray<NSURL *> *)roots;
+ (void)setRemotePlaceholderRoot:(nullable NSURL *)root;
+ (BOOL)isRemotePlaceholderFile:(NSURL *)url;

// A remote placeholder whose tags and art TagLib reads by range
// (PlayableExtensions.tagParsed); any other needs its whole file. The tag
// scan and the art loader both decide by it.
+ (BOOL)readsRemotePlaceholderByRange:(NSURL *)url;

// Where a remote placeholder's bytes stream in until they replace it: a
// hidden sibling, so no listing shows it. Its name ends in
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

// One file as its rows: a CUE sheet's tracks, an M3U's readable entries, a
// large local FLAC's embedded cue sheet, else the file whole. Every expansion mints a file's rows here,
// so a sheet inside a file applies wherever the file is opened.
+ (NSArray<AudioTrack *> *)rowsForFile:(NSURL *)url;

// YES when the sandbox, not absence, keeps url from being read: the one case
// a grant would fix. A sheet's rowsForFile: is empty when it is the sheet's
// folder that is denied.
+ (BOOL)isReadDenied:(NSURL *)url;

// The folder's non-empty audio files as rows, non-recursive, hidden entries
// skipped; a CUE sheet among them stands in for its files, as in a walk.
// Synchronous. sort is a parameter because this layer may not read a setting.
+ (NSArray<AudioTrack *> *)rowsInDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The folder's subfolders, its M3U playlists, and the audio files and sheets
// rowsInDirectory: would make rows of, each sorted by `sort`, hidden entries
// skipped. What a browser draws, so a folder plays as it is shown; a playlist
// is not part of that, as a subfolder is not. Synchronous.
+ (void)listDirectory:(NSURL *)dir
             sortedBy:(VibeFolderOpenSort)sort
              folders:(NSArray<NSURL *> *_Nonnull *_Nullable)folders
            playlists:(NSArray<NSURL *> *_Nonnull *_Nullable)playlists
                audio:(NSArray<NSURL *> *_Nonnull *_Nullable)audio;
@end

NS_ASSUME_NONNULL_END
