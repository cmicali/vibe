//
//  SettingsViewController.h
//  Vibe (iOS)
//
//  Behind the gear on the playlist screen: the root of the settings hierarchy,
//  and nothing else. Three groups, each its own screen —
//
//  - Appearance, everything the player DRAWS;
//  - Files, the two settings that are about files rather than pixels;
//  - About, the mac About pane's content — icon, version, links, statistics.
//
//  About sits in a section of its own because it is the only one that sets
//  nothing. This screen owns no setting and posts nothing; each child owns its
//  own group, and each writes through the same
//  VibeNotifyDisplaySettingsChanged() the card listens on.
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
