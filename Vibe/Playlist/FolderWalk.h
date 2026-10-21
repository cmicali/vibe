//
//  FolderWalk.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "FolderOpenSort.h"

NS_ASSUME_NONNULL_BEGIN

@class PlaylistEntry;

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


@interface FolderWalk : NSObject

+ (void)setPlaylistFolderGrantHandler:(nullable VibePlaylistFolderGrantHandler)handler;
+ (void)setWalkedDirectoriesHandler:(nullable VibeWalkedDirectoriesHandler)handler;
+ (void)setBulkOpenDirectoriesHandler:(nullable VibeBulkOpenDirectoriesHandler)handler;

// Expands folders and top-level playlist files to entries and filters to
// playable extensions, on a four-wide queue; callers order overlapping results
// (OpenRequestCoordinator). A file is one entry; a CUE sheet — opened, or met
// in a walked folder, where it claims its files — is an entry per track.
// folderCount is how many top-level URLs were directories. Completion runs on
// the expansion worker, so the caller makes its rows off main.
//
// sort orders each expanded folder's audio only: top-level URLs and a playlist
// file's entries keep the order the user gave.
+ (void)expandAndFilterList:(NSArray<NSURL *> *)list
                   sortedBy:(VibeFolderOpenSort)sort
                 completion:(void (^)(NSArray<PlaylistEntry *> *entries, NSUInteger folderCount))completion;

// Common/PlayableExtensions' set.
+ (NSSet<NSString *> *)supportedExtensions;

// One file as its entries: a CUE sheet's tracks, an M3U's readable entries, a
// large local FLAC's embedded cue sheet, else the file whole. Every expansion
// makes a file's entries here, so a sheet inside a file applies wherever the
// file is opened.
+ (NSArray<PlaylistEntry *> *)entriesForFile:(NSURL *)url;

// YES when the sandbox, not absence, keeps url from being read: the one case
// a grant would fix. A sheet's entriesForFile: is empty when it is the sheet's
// folder that is denied.
+ (BOOL)isReadDenied:(NSURL *)url;

// The folder's non-empty audio files as entries, non-recursive, hidden files
// skipped; a CUE sheet among them stands in for its files, as in a walk.
// Synchronous. sort is a parameter because this layer may not read a setting.
+ (NSArray<PlaylistEntry *> *)entriesInDirectory:(NSURL *)dir sortedBy:(VibeFolderOpenSort)sort;

// The folder's subfolders, its M3U playlists, and the audio files and sheets
// entriesInDirectory: would make entries of, each sorted by `sort`, hidden
// files skipped. What a browser draws, so a folder plays as it is shown; a playlist
// is not part of that, as a subfolder is not. Synchronous.
+ (void)listDirectory:(NSURL *)dir
             sortedBy:(VibeFolderOpenSort)sort
              folders:(NSArray<NSURL *> *_Nonnull *_Nullable)folders
            playlists:(NSArray<NSURL *> *_Nonnull *_Nullable)playlists
                audio:(NSArray<NSURL *> *_Nonnull *_Nullable)audio;
@end

NS_ASSUME_NONNULL_END
