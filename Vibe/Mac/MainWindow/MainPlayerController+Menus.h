//
//  MainPlayerController+Menus.h
//  Vibe
//
//  The menu-bar state for the View and Controls menus, and the delegate-built
//  waveform-style submenu. AppKit reaches everything here without extra
//  wiring: item validation arrives through the items' target, the controller,
//  and menuNeedsUpdate: through the NSMenuDelegate wiring MainMenuBuilder
//  installs.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Menus) <NSMenuItemValidation>

// The action of the items menuNeedsUpdate: builds for the waveform-style
// submenu.
- (IBAction)setWaveformStyle:(id)sender;

// The waveform-style registry, re-exposed for the Settings pane's popup:
// stable identifiers in, localized names for display only.
- (NSArray<NSString *> *)availableWaveformStyleIdentifiers;
- (NSString *)displayNameForWaveformStyle:(NSString *)identifier;

// Re-resolves colors without writing a setting — a custom color was edited,
// an artwork color landed, or the settings live-effect mapping requested it.
- (void)refreshWaveformTheme;

@end

NS_ASSUME_NONNULL_END
