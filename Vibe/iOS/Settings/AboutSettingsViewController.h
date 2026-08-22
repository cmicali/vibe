//
//  AboutSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > About: the mac About pane's content, in a grouped list. The app
//  icon, name and version as the table's header; the three project links; the
//  lifetime AppStats counters under a Statistics heading.
//
//  It reads and opens; it writes nothing. The one thing it does NOT carry is
//  the mac's vectorballs About window — that panel is the mac app menu's
//  "About Vibe", which iOS has no menu bar to put anywhere.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AboutSettingsViewController : UITableViewController

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
