//
//  FolderAccessManager+GrantPanel.h
//  Vibe
//
//  The one place the sandbox grant is *asked for* rather than stored: the
//  folder picker a playlist file raises when its entries turn out to live
//  somewhere the app holds no grant for.
//
//  Split from the manager because the manager is a non-blocking bookmark store
//  — resolve, merge, persist — while this is a modal AppKit run loop that
//  blocks a background worker until a human answers.
//

#import "FolderAccessManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface FolderAccessManager (GrantPanel)

// Runs the folder picker on the main thread and blocks the calling expansion
// worker until it closes, answering whether access was granted. Never call it
// from the main thread — it deadlocks, and asserts so in Debug.
- (BOOL)requestAccessForPlaylistFolder:(NSURL *)playlistURL;

@end

NS_ASSUME_NONNULL_END
