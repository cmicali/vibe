//
//  WaveformThemeSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance > Waveform theme; not a SettingsChoiceViewController
//  because Custom brings four color wells. All four mac themes are offered;
//  album art's color is per page (root CLAUDE.md).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformThemeSettingsViewController : UITableViewController

// The theme in force, resolved: an unknown identifier reads as Mono.
+ (NSString *)currentThemeDisplayName;

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
