//
//  BrowserRootViewController.h
//  Vibe (iOS)
//
//  The browser's root: one list of every place it can list. Locations come
//  first: the host's sources, then each folder the user granted
//  (LocationStore). Each opens in a FolderViewController pushed above this
//  one. The plus grants a folder through the system folder picker, and
//  connects a source that has nothing to show yet. The host adds groups of
//  its own below Locations (rootSections).
//

#import <UIKit/UIKit.h>

@protocol VibeBrowserHost;

NS_ASSUME_NONNULL_BEGIN


@interface BrowserRootViewController : UITableViewController

- (instancetype)initWithHost:(id<VibeBrowserHost>)host NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly) id<VibeBrowserHost> host;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Makes the stack the path to `directory`, one screen per folder from the
// source covering it, so Back walks up; a directory no source covers is
// pushed alone. A file in it is scrolled to and selected for a moment.
- (void)showDirectory:(NSURL *)directory highlighting:(nullable NSURL *)file;

// Handed snapshots of the rows an action lifts, framed in window
// coordinates, before the action runs. Every folder pushed above this one
// is handed it too.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

// Set by whoever shows the stack: whether it is materially exposed — its tab
// selected, the card down, the scene foreground-active. The playing row's
// equalizer runs only while this and its own screen are.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
