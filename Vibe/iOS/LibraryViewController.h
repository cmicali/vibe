//
//  LibraryViewController.h
//  Vibe (iOS)
//
//  The Playlist tab. Selecting a row plays it and stays here; expanding the
//  card is the mini strip's job.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface LibraryViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Whether the root's card and tab selection leave this surface exposed.
@property (nonatomic) BOOL equalizerSurfaceVisible;

// The empty state's Open. Set by the shell, the only thing that knows about
// tabs; the library holds no reference back.
@property (nonatomic, copy, nullable) void (^openFilesHandler)(void);

@end

NS_ASSUME_NONNULL_END
