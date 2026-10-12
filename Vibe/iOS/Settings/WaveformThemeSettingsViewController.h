//
//  WaveformThemeSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance > Waveform theme; not a SettingsChoiceViewController
//  because Custom brings color wells. All four mac waveform themes are
//  offered; album art's color is per page (root AGENTS.md). Under 3-Band the
//  screen offers the band palettes instead: Rekord Bin, Dengine and Custom.
//  Under Spectrum it offers Spectrum's: RGB, Blue, Green and Custom.
//  The widget's copy of the screen edits the widget's settings, and shows
//  only the dark wells, since the widget is always dark.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformThemeSettingsViewController : UITableViewController

// The theme in force for the current style, resolved: an unknown identifier
// reads as Mono, as Rekord Bin under 3-Band, or as RGB under Spectrum.
+ (NSString *)currentThemeDisplayNameForWidget:(BOOL)widget;

- (instancetype)initForWidget:(BOOL)widget NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
