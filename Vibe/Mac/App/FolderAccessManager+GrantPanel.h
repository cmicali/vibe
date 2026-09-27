//
//  FolderAccessManager+GrantPanel.h
//  Vibe
//
//  The one place a grant is ASKED for: the folder picker a playlist file
//  raises when its entries lie outside every grant. A modal run loop that
//  blocks a background worker, split from the non-blocking store.
//

#import "FolderAccessManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface FolderAccessManager (GrantPanel)

// Blocks the calling expansion worker until the picker closes. Never call it
// on main: it deadlocks.
- (BOOL)requestAccessForPlaylistFolder:(NSURL *)playlistURL;

@end

NS_ASSUME_NONNULL_END
