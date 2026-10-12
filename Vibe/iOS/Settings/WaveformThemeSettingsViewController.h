//
//  WaveformThemeSettingsViewController.h
//  Vibe (iOS)
//
//  The widget edits only dark colors because its background is always dark.

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
