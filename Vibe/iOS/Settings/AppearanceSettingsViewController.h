//
//  AppearanceSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Appearance: everything the player DRAWS. The waveform's style and
//  theme, the time display, and the file-info switch — the engine's own
//  settings are macOS-only (see Vibe/Common/CLAUDE.md), so this is the whole of
//  what there is to set here.
//
//  Four rows and no lists: each choice with more than two answers pushes its
//  own picker, so this screen stays the summary you read the current settings
//  off. Writing any of them ends on VibeNotifyDisplaySettingsChanged().
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
