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

@end

@interface FolderSession : NSObject

@property (nonatomic, weak) id<FolderSessionDelegate> delegate;

// The current folder's display name, or nil before anything was opened (or
// after a single-file open).
@property (nonatomic, readonly, nullable) NSString *folderDisplayName;

// Presents the system document picker (folders + the declared audio types,
// in place, single selection).
- (void)presentPickerFromViewController:(UIViewController *)presenter;

// Adopts a URL delivered from outside the picker ("Open in Vibe" from Files
// or the share sheet). openInPlace mirrors UIOpenURLContext.options.
- (void)openExternalURL:(NSURL *)url openInPlace:(BOOL)openInPlace;

// Resolves the persisted bookmark and re-delivers the folder through the
// delegate with restored:YES. NO when nothing was persisted or the bookmark
// no longer resolves.
- (BOOL)restorePersistedFolder;

// The last track filename the player screen wants restored next launch.
// Stored alongside the bookmark; nil clears it.
@property (nonatomic, copy, nullable) NSString *persistedTrackFileName;

@end

NS_ASSUME_NONNULL_END
