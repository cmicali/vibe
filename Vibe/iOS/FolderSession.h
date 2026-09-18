//
//  FolderSession.h
//  Vibe (iOS)
//
//  Owns the picked locations of the current playlist — one base folder or file
//  plus any additions: the document picker, the security-scoped access to each
//  result, the bookmarks that restore them on relaunch, and the
//  directory-as-playlist listing. The player screen feeds the resulting URL
//  list into Playlist; this class never touches playback.
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

// An Add landed: urls (never empty, already in playlist order) go on the end
// of the current playlist. Nothing about the base — folder, star, bookmark —
// changed, and nothing plays. May carry URLs the playlist already holds; the
// controller decides what to do with those.
- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<NSURL *> *)urls;

// The picked location held no audio files.
- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session;

// A restore restorePersistedFolder returned YES for came to nothing: the
// bookmark no longer resolves, or the folder has emptied. The player shows
// the empty state it would have shown for a NO return.
- (void)folderSessionRestoreDidFail:(FolderSession *)session;

@end

@interface FolderSession : NSObject

@property (nonatomic, weak) id<FolderSessionDelegate> delegate;

// The base folder's display name, or nil before anything was opened (or after
// a single-file open).
@property (nonatomic, readonly, nullable) NSString *folderDisplayName;

// The BASE folder — the Playlist tab's title, the star, the bookmark — or nil:
// a single-file playlist has none. An Add never moves it, so a single-file
// base with an appended folder keeps the title "Playlist" and no star: the
// star bookmarks the playlist's identity, and a single file has none.
@property (nonatomic, readonly, nullable) NSURL *folderURL;

// This session's contribution to the search scope: the base folder, if any,
// then every added folder. A folder grant covers the WHOLE subtree, so its
// subfolders are searchable even though the directory-as-playlist listing is
// flat. Files never appear here — a single-file pick is a scope, not a root.
//
// TRANSIENT, unlike the roots SearchFolderStore holds — they are gone at the
// next open. That is why adding a folder inside one in Settings is not
// redundant, and so why coverage there is tested against the persistent roots
// and never against these. PlaybackController.searchRoots composes the two.
@property (nonatomic, readonly) NSArray<NSURL *> *searchRoots;

// Presents the system document picker (folders + the declared audio types, in
// place). appending decides both what the pick does and what it may pick: NO
// is the empty state's Open — one folder or file, replacing the playlist — and
// YES is the Files tab's Add button, which takes several items at once and
// lands through the same prologue an Add from anywhere else does.
- (void)presentPickerFromViewController:(UIViewController *)presenter
                              appending:(BOOL)appending;

// Opens URLs delivered from outside the picker ("Open in Vibe" from Files or
// the share sheet, the Files tab's browser, a favorite). N URLs in pick order
// — the browser's multi-select Open; one is the common case. openInPlace
// mirrors UIOpenURLContext.options: NO means a copy in the inbox, readable
// without a scope, never bookmarked, and one track whatever it sits beside.
- (void)openURLs:(NSArray<NSURL *> *)urls openInPlace:(BOOL)openInPlace;

// Appends the tracks of each URL — a folder's listing, or a file as one track,
// never a file's directory — to the current playlist. Onto a session that has
// never landed a playlist this IS an open: it plays and presents, which is the
// mac's addURLs: empty-playlist rule, owned here.
- (void)addURLs:(NSArray<NSURL *> *)urls;

// The token a caller takes on MAIN at the moment the user asks for an Add,
// when it has asynchronous work of its own to do before it has a URL — a
// favorite's bookmark resolve. Handing it back to addURLs:token: judges the
// request by when the user asked rather than by when the provider answered, so
// an Add whose resolve outlived a replace is dropped instead of landing on a
// playlist the user has since replaced. addURLs: is the token-free form for a
// caller that already has its URLs: it takes the token itself.
//
// Staleness only. It does NOT reserve a place in the append lane, so a later
// Add with a URL in hand can still overtake one waiting on a slow provider;
// both land, in provider order rather than tap order.
- (uint64_t)addRequestToken;
- (void)addURLs:(NSArray<NSURL *> *)urls token:(uint64_t)token;

// A file found under one of searchRoots, so already covered by a grant in hand.
// Expands to its OWN directory as the playlist with it selected, exactly as
// picking it would — a search hit deep in the tree is not a one-track playlist.
//
// The covering persistent grant is retained independently for this playlist,
// even if its Settings row is removed meanwhile. The session bookmark is left
// as it is: re-pointing it at a subfolder would shrink next launch's searchable
// root to it.
- (void)openFileFromSearchRoots:(NSURL *)url;

// Kicks off resolving the persisted bookmarks — the base and every addition;
// the union re-delivers through the delegate with restored:YES. NO means
// nothing was persisted and no attempt starts. YES means an attempt is in
// flight — resolution and the directory listings are provider I/O and run off
// the main thread, so the outcome arrives later: folderSession:didOpenTracks:…
// on success, folderSessionRestoreDidFail: otherwise. All delegate calls land
// on main.
//
// The bookmarks resolve a bounded few at a time and merge in persisted order.
// That keeps one stalled provider from making every other bookmark wait its
// turn; it does NOT keep one from delaying launch, since the walk needs the
// whole union. The listing and the minting after it stay serial.
- (BOOL)restorePersistedFolder;

// Mints a fresh bookmark for the base folder so something outside this session
// can reopen it later — Favorites is the only caller. The mint runs off main
// under a temporary hold on the live scope, the same hold every open takes,
// because minting needs that scope OPEN and an open landing meanwhile releases
// it. completion lands on main; both arguments are nil when there is no base
// folder or the mint failed.
//
// It carries no openIntentGeneration, unlike an open: it changes no session
// state, and the user starred the folder that was open when they asked — a
// newer open landing first does not retract that.
- (void)bookmarkOpenFolderWithCompletion:(void (^)(NSURL *_Nullable folderURL,
                                                   NSData *_Nullable bookmark))completion;

// The standardized PATH of the last track the player screen wants restored
// next launch. Stored alongside the bookmark; nil clears it. A path and not a
// filename because the playlist spans folders once an Add has landed, and two
// albums both holding "01.wav" parked on the wrong one. The path is not
// sufficient on its own either — a provider can hand the same file back under
// a different absolute path — so the restore match is two-tier: exact path,
// then filename. A value written by an older build IS a bare filename and
// restores through that second tier unchanged.
@property (nonatomic, copy, nullable) NSString *persistedTrackPath;

@end

NS_ASSUME_NONNULL_END
