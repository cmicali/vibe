//
//  PlaybackController+ReplacePrompt.h
//  Vibe (iOS)
//
//  The replace question every screen asks before its tap replaces the
//  playlist, and Open URL's road into it.
//

#import "PlaybackController.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (ReplacePrompt)

// Opens urls as the playlist — one through openFileURL:inFolder:, several
// through openURLs:openInPlace: — asking first when the playlist was built by
// hand, with Add Instead as the other answer. Every screen whose tap replaces
// the playlist comes through here. `token` is the receiver's
// replaceRequestTokenOpening:, taken when the user asked: a caller with asynchronous
// work first (a bookmark to resolve, a Dropbox folder to list) is dropped
// here when another open was asked for meanwhile, or an older tap landing
// late would replace what the user chose last.
- (void)confirmReplacingPlaylistFrom:(UIViewController *)presenter
                         openingURLs:(NSArray<NSURL *> *)urls
                            inFolder:(BOOL)inFolder
                               token:(uint64_t)token;

// Open URL's resolve, which both its roads take. A Dropbox folder link goes
// through the linked account (DropboxMirror openSharedFolderLink:…) and
// answers its folder. With no account, or when the account cannot open it,
// LinkStore resolves it with no account, as it does every other link.
// Completion on main, exactly once, with exactly one of file and error. The
// returned block cancels on main, as LinkStore's does.
- (dispatch_block_t)resolveLinkString:(NSString *)string
                           completion:(void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

// Open URL: the typed link resolved (resolveLinkString:…), then its file opened alone
// through confirmReplacing…, which asks when the playlist was built by hand.
// It asks over what is on top of anchor's window when the link settles. The
// sheet, the add sheet, or the card may have come or gone by then. The
// replace token is taken now, so a later open supersedes it. A link that
// fails leaves the playlist as it is. Never the inbox road: it does not
// persist. Completion on main, with exactly one of file and error, before
// the replace question. The returned block cancels the resolve on main, as
// LinkStore's does.
- (dispatch_block_t)openLinkString:(NSString *)string
             replacingPlaylistFrom:(UIViewController *)anchor
                        completion:(nullable void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
