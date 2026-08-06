//
//  MainPlayerController+Menus.h
//  Vibe
//
//  The menu-bar state for the View and Controls menus, and the delegate-built
//  waveform-style submenu, split from the main implementation purely for file
//  size. AppKit reaches everything here without extra wiring: item validation
//  arrives through the items' target, the controller, and menuNeedsUpdate:
//  through the NSMenuDelegate wiring MainMenuBuilder installs.
//
//  The NSMenuItemValidation conformance is declared on this category rather
//  than the class extension, so that the compiler checks its implementation in
//  this file.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Menus) <NSMenuItemValidation>

// The action of the items menuNeedsUpdate: builds for the waveform-style
// submenu.
- (IBAction)setWaveformStyle:(id)sender;

@end

NS_ASSUME_NONNULL_END
