//
//  MainPlayerController+Menus.h
//  Vibe
//
//  The menu-bar state for the View and Controls menus, and the delegate-built
//  View > Theme submenu. AppKit reaches everything here without extra
//  wiring: item validation arrives through the items' target, the controller,
//  and menuNeedsUpdate: through the NSMenuDelegate wiring MainMenuBuilder
//  installs.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Menus) <NSMenuItemValidation>

// The action of the items menuNeedsUpdate: builds for the View > Theme
// submenu: applies the picked theme and requests the composed effect.
- (IBAction)selectTheme:(id)sender;

// Re-resolves colors without writing a setting — a custom color was edited,
// an artwork color landed, or the settings live-effect mapping requested it.
- (void)refreshWaveformTheme;

@end

NS_ASSUME_NONNULL_END
