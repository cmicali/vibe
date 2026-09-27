//
//  AppearanceSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance: everything the player DRAWS — waveform style, the
//  widget's waveform style, theme, time display, file info. Every row but the
//  file-info switch pushes its own picker, so this screen is the summary.
//  Every write ends on VibeNotifyDisplaySettingsChanged().
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppearanceSettingsViewController : UITableViewController

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
