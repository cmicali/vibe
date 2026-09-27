//
//  PlaybackSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Playback: Track transitions (On track end, Crossfade),
//  Resampling, the audio effects switch and BPM detection. A write ends on the
//  model — applyTrackTransitionSettings, applyResamplingSetting,
//  applyFXSetting — because the player plays from these; the effects switch
//  also notifies the card, whose FX pad is drawn from the setting.
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
