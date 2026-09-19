//
//  SettingsViewController.h
//  Vibe (iOS)
//
//  Behind the gear on the playlist screen: the root of the settings hierarchy,
//  and nothing else. Four groups, each its own screen, in the mac sidebar's
//  order —
//
//  - Playback, what the player does between tracks;
//  - Appearance, everything the player DRAWS;
//  - Files, the two settings that are about files rather than pixels;
//  - About, the mac About pane's content — icon, version, links, statistics.
//
//  About sits in a section of its own because it is the only one that sets
//  nothing. This screen owns no setting and applies nothing; each child owns
//  its own group. The model is handed down for Playback, the one group whose
//  writes reach the player rather than the screens that draw.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface SettingsViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
