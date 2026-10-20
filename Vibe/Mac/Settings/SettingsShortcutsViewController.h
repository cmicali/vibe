//
//  SettingsShortcutsViewController.h
//  Vibe
//

#import "SettingsPaneViewController.h"

@class MainPlayerController;

// Every remappable command (ShortcutRules.h) listed in menu order under its
// menu's title. Recording is a state of the pane, not a control.
@interface SettingsShortcutsViewController : SettingsPaneViewController

// Every shortcut write is the player's (assignShortcut:toCommand:loser:).
@property (weak, readonly) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController
                             effectsSink:(void (^)(NSUInteger effects))sink;

@end
