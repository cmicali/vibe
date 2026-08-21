//
//  SearchViewController.h
//  Vibe (iOS)
//
//  The Search tab has two answers: the open playlist, matched live by tags and
//  filename, and files under every transient or persistent search root, matched
//  asynchronously by filename and containing folder. An empty query lists the
//  playlist as a browse view but never dumps the recursive file index.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface SearchViewController : UITableViewController

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Whether the root currently leaves this tab materially exposed. The search
// controller combines this with its own appearance lifecycle, cancels hidden
// file filtering, and refreshes once when the card reveals the tab again.
@property (nonatomic, getter=isMaterialSurfaceVisible) BOOL materialSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
