//
//  SettingsWindowController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

@interface SettingsWindowController : NSWindowController

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Selects the Appearance pane and lands on the theme editor — View > Theme >
// Edit Themes…'s destination. The window must already be shown (the app
// delegate's showThemeSettings: does both).
- (void)showThemeEditor;

@end
