//
//  SearchViewController.h
//  Vibe (iOS)
//
//  The search circle's screen: a standard search field over the current
//  directory's tracks (title, artist, filename), Mail-style — the field is
//  focused on appear and results filter live. Selecting a result plays it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class Playlist;

@interface SearchViewController : UITableViewController

- (instancetype)initWithPlaylist:(Playlist *)playlist;

@property (nonatomic, copy, nullable) void (^onSelectTrack)(NSUInteger index);

// Re-filters the current query against the playlist's current contents. The
// owner forwards playlist replacement while the sheet is up, so an external
// open cannot leave the results indexing a departed playlist.
- (void)reloadAll;

@end

NS_ASSUME_NONNULL_END
