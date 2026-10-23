//
//  FolderAccessManager+GrantPanel.h
//  Vibe
//
//  The one place a grant is ASKED for: the folder picker a playlist file
//  raises when its entries lie outside every grant. A modal run loop that
//  blocks a background worker. The store itself never raises a panel.
//

#import "FolderAccessManager.h"

NS_ASSUME_NONNULL_BEGIN

@interface FolderAccessManager (GrantPanel)

// Blocks the calling folder walk's worker until the picker closes. Never call it
// on main: it deadlocks. The app passes the panel's message and its button's
// title, localized.
- (BOOL)requestAccessForPlaylistFolder:(NSURL *)playlistURL
                               message:(NSString *)message
                                prompt:(NSString *)prompt;

@end

NS_ASSUME_NONNULL_END
