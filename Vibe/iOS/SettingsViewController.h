//
//  SettingsViewController.h
//  Vibe (iOS)
//
//  Behind the gear on the playlist screen: everything the player DRAWS, which
//  here is the whole of what there is to set — the engine's own settings are
//  macOS-only (see Vibe/Common/CLAUDE.md), and the phone owns the rest.
//
//  It writes the settings and posts VibeDisplaySettingsDidChangeNotification;
//  it never reaches for the screens that draw them.
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
