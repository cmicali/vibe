//
//  WaveformThemeSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance > Waveform theme. The style setting is the geometry,
//  the theme is the colors — see the root CLAUDE.md's waveform-theme guarantee.
//
//  It is a screen of its own rather than a SettingsChoiceViewController because
//  Custom brings four color wells with it, which a list of titles cannot carry.
//
//  All four of the mac's themes are offered, album art included: each page of
//  the track pager hands its own scrubber the dominant color of the art it was
//  just given, so the palette follows the track being looked at.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WaveformThemeSettingsViewController : UITableViewController

// The display name of the theme actually in force, for the Appearance row's
// value column. Resolved, never the raw stored identifier — see the
// implementation on why a stored album_art reads as Mono here.
+ (NSString *)currentThemeDisplayName;

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
