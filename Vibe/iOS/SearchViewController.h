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

@end

NS_ASSUME_NONNULL_END
