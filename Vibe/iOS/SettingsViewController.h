//
//  SettingsViewController.h
//  Vibe (iOS)
//
//  Behind the gear on the playlist screen. Two kinds of thing, in that order:
//
//  - everything the player DRAWS — waveform style, time display, file info. The
//    engine's own settings are macOS-only (see Vibe/Common/CLAUDE.md), so this
//    is the whole of what there is to set. Writing one posts
//    VibeDisplaySettingsDidChangeNotification.
//  - the folders the user has given the app to SEARCH (SearchFolderStore), last
//    on the screen because it grants access rather than changing an appearance.
//    The store owns the grants and its own notification.
//
//  It writes settings and presents the folder picker; it never reaches for the
//  screens that draw them, and it holds no playback handle.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsViewController : UITableViewController

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
