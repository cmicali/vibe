//
//  SearchViewController.h
//  Vibe (iOS)
//
//  Two sections: the open playlist, matched live by tags and filename, and the
//  files under every search root, matched off main by filename and folder. An
//  empty query lists the playlist but never dumps the file index.
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

// Whether the root's card and tab selection leave this tab exposed. Hidden,
// file filtering is cancelled; revealed, one current pass runs.
@property (nonatomic, getter=isMaterialSurfaceVisible) BOOL materialSurfaceVisible;

// Open Folder: shows a directory in the Files tab, which this screen knows
// nothing about.
@property (nonatomic, copy, nullable) void (^showDirectoryHandler)(NSURL *directory);

@end

NS_ASSUME_NONNULL_END
