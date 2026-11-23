//
//  BrowserRootViewController.h
//  Vibe (iOS)
//
//  The browser's root: one list of every place it can list. Locations come
//  first: the host's sources, then each folder the user granted
//  (LocationStore). Each opens in a FolderViewController pushed above this
//  one. The plus grants a folder through the system folder picker, and
//  connects a source that has nothing to show yet. An app adds groups of
//  its own below Locations by subclassing (appSections).
//

#import <UIKit/UIKit.h>

@class FolderViewController;
@protocol VibeBrowserHost;

NS_ASSUME_NONNULL_BEGIN

// One row an app adds to the root.
@interface VibeBrowserRootRow : NSObject

+ (instancetype)rowWithTitle:(NSString *)title image:(UIImage *)image handler:(dispatch_block_t)handler;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) UIImage *image;
@property (nonatomic, readonly, copy) dispatch_block_t handler;
// Drawn in the tint with no disclosure: the row does something, rather than
// going somewhere.
@property (nonatomic) BOOL isAction;
// The row spins in its icon slot.
@property (nonatomic) BOOL spinning;

@end

// The delegate of the location picker. A subclass with pickers of its own
// answers them and hands the rest to super.
@interface BrowserRootViewController : UITableViewController <UIDocumentPickerDelegate>

- (instancetype)initWithHost:(id<VibeBrowserHost>)host NS_DESIGNATED_INITIALIZER;
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

#pragma mark For a subclass

// The groups below Locations, asked whenever the table reads them. Empty
// here.
- (NSArray<NSArray<VibeBrowserRootRow *> *> *)appSections;
// Redraws one of appSections after its rows changed.
- (void)reloadAppSection:(NSUInteger)index animated:(BOOL)animated;
- (void)pushDirectory:(NSURL *)url;
// Closes the sheet the stack is in, by its presenter, so a sheet over the
// root closes with it.
- (void)dismissSheet;

@end

NS_ASSUME_NONNULL_END
