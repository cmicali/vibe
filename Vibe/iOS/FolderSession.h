//
//  FolderSession.h
//  Vibe (iOS)
//
//  Owns exactly one picked location: the document picker, the
//  security-scoped access to its result, the bookmark that restores it on
//  relaunch, and the directory-as-playlist listing. The player screen feeds
//  the resulting URL list into Playlist; this class never touches playback.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FolderSession;

@protocol FolderSessionDelegate <NSObject>

// A pick or a restore resolved to a playable URL list. urls is never empty.
// folderURL is nil for a single-file pick or an open-in-place file whose
// directory no held grant covers. selectedURL names the specific file the
// user chose when a file pick expanded to its directory — play that one, not
// the first; nil otherwise. restored distinguishes a relaunch restore (park,
// don't autoplay) from a user pick.
- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<NSURL *> *)urls
            folderURL:(nullable NSURL *)folderURL
          selectedURL:(nullable NSURL *)selectedURL
             restored:(BOOL)restored;

// The picked location held no audio files.
- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session;

// A restore restorePersistedFolder returned YES for came to nothing: the
// bookmark no longer resolves, or the folder has emptied. The player shows
// the empty state it would have shown for a NO return.
- (void)folderSessionRestoreDidFail:(FolderSession *)session;

@end

@interface FolderSession : NSObject

@property (nonatomic, weak) id<FolderSessionDelegate> delegate;

// The current folder's display name, or nil before anything was opened (or
// after a single-file open).
@property (nonatomic, readonly, nullable) NSString *folderDisplayName;

// This session's contribution to the search scope: the open folder, or nil. A
// folder grant covers the WHOLE subtree, so its subfolders are searchable even
// though the directory-as-playlist listing is flat.
//
// TRANSIENT, unlike the roots SearchFolderStore holds — it is gone at the next
// open. That is why adding a folder inside it in Settings is not redundant, and
// so why coverage there is tested against the persistent roots and never
// against this one. PlaybackController.searchRoots composes the two.
@property (nonatomic, readonly, nullable) NSURL *searchRoot;

// Presents the system document picker (folders + the declared audio types,
// in place, single selection).
- (void)presentPickerFromViewController:(UIViewController *)presenter;

// Adopts a URL delivered from outside the picker ("Open in Vibe" from Files
// or the share sheet). openInPlace mirrors UIOpenURLContext.options.
- (void)openExternalURL:(NSURL *)url openInPlace:(BOOL)openInPlace;

// A file found under one of searchRoots, so already covered by a grant in hand.
// Expands to its OWN directory as the playlist with it selected, exactly as
// picking it would — a search hit deep in the tree is not a one-track playlist.
//
// The grant and the bookmark are deliberately left as they are: the scope in
// hand already covers the subtree, and re-pointing the bookmark at a subfolder
// would shrink next launch's searchable root to it.
- (void)openFileFromSearchRoots:(NSURL *)url;

// Kicks off resolving the persisted bookmark; the folder re-delivers through
// the delegate with restored:YES. NO means nothing was persisted and no
// attempt starts. YES means an attempt is in flight — resolution and the
// directory listing are provider I/O and run off the main thread, so the
// outcome arrives later: folderSession:didOpenTracks:… on success,
// folderSessionRestoreDidFail: otherwise. All delegate calls land on main.
- (BOOL)restorePersistedFolder;

// The last track filename the player screen wants restored next launch.
// Stored alongside the bookmark; nil clears it.
@property (nonatomic, copy, nullable) NSString *persistedTrackFileName;

@end

NS_ASSUME_NONNULL_END
