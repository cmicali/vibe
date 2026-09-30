//
//  NSURLUtil.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "FolderOpenSort.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;

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
// fails, since unknown is not dataless.
+ (BOOL)isDatalessFile:(NSURL *)url;

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

// One file as its rows: a large local FLAC's embedded cue sheet, else the file
// whole. Every expansion mints a file's rows here, so a sheet inside a file
// applies wherever the file is opened.
+ (NSArray<AudioTrack *> *)rowsForFile:(NSURL *)url;

// The folder's non-empty audio files as rows, non-recursive, hidden entries
// skipped; a CUE sheet among them stands in for its files, as in a walk.
// Synchronous. sort is a parameter because this layer may not read a setting.
+ (NSArray<AudioTrack *> *)rowsInDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;
@end

NS_ASSUME_NONNULL_END
