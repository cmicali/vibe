//
//  FolderSession.h
//  Vibe (iOS)
//
//  Owns the picked locations of the current playlist: a base folder or file
//  plus any additions, their security scopes, the restore bookmarks and the
//  listing. It never touches playback. The system pickers belong to the Files
//  tab's browser and to RootViewController. Their URLs reach this class
//  through PlaybackController. What an open brings is recorded in RecentsStore.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class FolderSession;

@protocol FolderSessionDelegate <NSObject>

// rows is never empty. folderURL is nil for a single-file base. selectedURL
// is the picked file when a file pick expanded to its directory. restored: a
// relaunch restore, to park rather than play.
- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<AudioTrack *> *)rows
            folderURL:(nullable NSURL *)folderURL
          selectedURL:(nullable NSURL *)selectedURL
             restored:(BOOL)restored;

// An Add settled. Nonempty rows append in order and may include duplicates.
// Empty rows report an Add that found nothing. The base stays unchanged.
- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<AudioTrack *> *)rows;

// The picked location held no audio files.
- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session;

// A restore that restorePersistedFolder returned YES for came to nothing.
- (void)folderSessionRestoreDidFail:(FolderSession *)session;

// After an open or Add settled empty because a picked CUE sheet's folder is
// denied: a sheet's grant reaches the sheet alone, never the audio beside it.
// openSheetURL:inGrantedFolder:appending: takes the folder the user grants.
- (void)folderSession:(FolderSession *)session
        needsFolderOfSheetAtURL:(NSURL *)sheetURL
                      appending:(BOOL)appending;

@end

@interface FolderSession : NSObject

@property (nonatomic, weak) id<FolderSessionDelegate> delegate;

// Nil whenever folderURL is.
@property (nonatomic, readonly, nullable) NSString *folderDisplayName;

// An Add has landed on the playlist now loaded, or it was restored with
// additions: the playlist is no longer something one reopen rebuilds.
@property (nonatomic, readonly) BOOL hasAdditions;

// The BASE folder: the Playlist tab's title, the star, the bookmark. Nil for a
// single-file base, which an appended folder never replaces.
@property (nonatomic, readonly, nullable) NSURL *folderURL;

// The base folder, if any, then every added folder; never a file. TRANSIENT,
// gone at the next open, so LocationStore tests coverage against its own
// persistent roots, never these.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

@end

// The entry points: open, add, clear and cancel.
@interface FolderSession (ExternalOpens)

// URLs in pick order. openInPlace NO means an inbox
// copy: no scope, never bookmarked, one track whatever it sits beside.
- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace;

// Appends a folder's listing, or a file as one track, never its directory.
// Onto a session that never landed a playlist, this IS an open.
- (void)addURLs:(NSArray<NSURL *> *)urls;

// Taken on MAIN when the user asks, by a caller with asynchronous work before
// it has a URL, so an Add whose resolve outlived a replace is dropped.
// Staleness only: it reserves no place in the append lane, so two Adds can land
// in provider order rather than tap order.
- (uint64_t)addRequestToken;
- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token;

// One URL: a folder opens; a file plays alone or, inFolder, as its own
// directory with it selected where a root covers that. The covering grant is
// retained for this playlist even if its Location is removed. Whether the open
// becomes the session bookmark is decided here, never by the caller.
- (void)openURL:(NSURL *)url inFolder:(BOOL)inFolder;

// The sheet needsFolderOfSheetAtURL: named, again, with the folder just
// picked held for the playlist like a starred folder's root: an open expands
// to the sheet's directory, an Add appends the sheet's rows. A folder that
// does not cover the sheet finds nothing and asks again.
- (void)openSheetURL:(NSURL *)sheetURL inGrantedFolder:(NSURL *)folderURL appending:(BOOL)appending;

// Back to never-opened: every scope released, and the persisted bookmarks and
// remembered track REMOVED, so the next launch restores nothing. Supersedes
// any open in flight. Main thread; no delegate call.
- (void)clearSession;

// Gives up the open in flight: it is dropped when it finishes, and the
// playlist standing answers for it, as for an open that found nothing. Main
// thread; no delegate call.
- (void)cancelOpen;

@end

// The launch restore, the bookmarks and the remembered track.
@interface FolderSession (Persistence)

// NO: nothing was persisted. YES: an attempt is in flight, ending in
// didOpenTracks:…restored:YES or folderSessionRestoreDidFail:, on main.
- (BOOL)restorePersistedFolder;

// Mints a bookmark for the base folder, off main under a hold on the live
// scope. Completion on main; both nil when there is no base or the mint failed.
// No generation: the user starred the folder open when they asked, and a newer
// open does not retract that.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *_Nullable folderURL,
                                                   NSData *_Nullable bookmark))completion;

// Mints a bookmark for a folder this session does NOT own, which arrives with
// the browser's grant and so is started directly; the open folder's hold must
// come from the scoped list instead. Completion on main; nil on failure.
- (void)bookmarkFolderURL:(NSURL *)folderURL
               completion:(void (^)(NSData *_Nullable bookmark))completion;

// The track to park on next launch: its standardized PATH, plus a cue row's
// window (AudioTrack.standardizedSourceKey); nil clears it. A path because
// the playlist spans folders; the restore still falls back to the filename
// (PlaybackController), which also serves an older build's value.
@property (nonatomic, copy, nullable) NSString *persistedTrackKey;

@end

NS_ASSUME_NONNULL_END
