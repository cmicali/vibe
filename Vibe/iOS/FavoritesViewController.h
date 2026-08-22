//
//  FavoritesViewController.h
//  Vibe (iOS)
//
//  The Favorites tab: the folders the user starred on the Playlist tab, one
//  row each, name over the folder that contains it. It draws FavoritesStore
//  and owns no state of its own.
//
//  Tapping a row opens that folder exactly as picking it in the document
//  picker would — it resolves the bookmark and hands the URL to the ordinary
//  adoption path, so the grant, the listing order, the autoplay and the card
//  are all the pick's, not this screen's.
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

@end

NS_ASSUME_NONNULL_END
