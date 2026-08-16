//
//  SearchViewController.h
//  Vibe (iOS)
//
//  The Search tab: a standard search field over the open folder's tracks
//  (title, artist, filename), filtering live. The empty query lists
//  everything, so the screen doubles as a browse list. Selecting a result
//  plays it and stays here, exactly as the library's rows do.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface SearchViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
