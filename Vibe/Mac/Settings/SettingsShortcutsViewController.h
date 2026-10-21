//
//  SettingsShortcutsViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@class MainPlayerController;

// The app's remappable commands, listed in groups under their titles.
// Recording is a state of the pane, not a control.
@interface SettingsShortcutsViewController : SettingsPaneViewController

// Every shortcut write is the player's (assignShortcut:toCommand:loser:).
@property (weak, readonly) MainPlayerController *playerController;

// commandRows answers the groups, @[title, @[@[identifier, label,
// @(default)], …]] each, and is asked again on every refresh: a label can
// follow a setting. The pane reads nothing else about a command.
- (instancetype)initWithPlayerController:(MainPlayerController *)playerController
                             effectsSink:(void (^)(NSUInteger effects))sink
                             commandRows:(NSArray<NSArray *> *(^)(void))commandRows;

@end
