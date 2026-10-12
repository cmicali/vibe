//
//  AppearanceSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance: waveform style, theme, playhead line and centering,
//  the widget's own style and centering, time display, file info and the
//  shuffle/repeat controls. Hiding those controls also turns both modes off
//  through the model. Every write ends on VibeNotifyDisplaySettingsChanged().
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface AppearanceSettingsViewController : UITableViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
