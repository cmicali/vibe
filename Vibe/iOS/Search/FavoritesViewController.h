//
//  FavoritesViewController.h
//  Vibe (iOS)
//
//  The Favorites tab. It draws FavoritesStore and owns no state. A tap resolves
//  the bookmark and opens it through the ordinary pick path.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FavoritesViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Shows a directory in the Files tab, which this screen knows nothing about:
// where a Dropbox favorite with no song directly inside goes instead of
// opening as an empty playlist.
@property (nonatomic, copy, nullable) void (^showDirectoryHandler)(NSURL *directory);

@end

NS_ASSUME_NONNULL_END
