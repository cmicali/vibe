//
//  LibraryViewController.h
//  Vibe (iOS)
//
//  The home screen: the open folder's tracks, one row each, mirroring the mac
//  playlist table's four columns — number (equalizer bars on the playing row),
//  artwork, title with the artist beside it, duration. The nav bar carries the
//  folder's name and the Open button; an empty playlist gets the
//  content-unavailable state with the same Open action.
//
//  Selecting a row plays it and stays here. Expanding the player is the mini
//  strip's job, not a side effect of picking a track — Apple Music's rule.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface LibraryViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// RootViewController owns the card above the tabs and supplies whether this
// surface is materially exposed. The library combines it with its own
// appearance and the playing row's actual scroll/window intersection.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
