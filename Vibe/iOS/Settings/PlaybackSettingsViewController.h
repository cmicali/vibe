//
//  PlaybackSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Playback: Track transitions (On track end, Crossfade) and
//  Resampling. A write notifies no screen — the player plays from these — so
//  each ends on the model's applyTrackTransitionSettings or
//  applyResamplingSetting.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackSettingsViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
