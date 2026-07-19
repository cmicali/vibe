//
//  MainPlayerController+Menus.h
//  Vibe
//
//  Menu-bar state for the View/Controls menus and the delegate-built
//  waveform-style submenu, split from the main implementation purely for
//  file size. AppKit reaches everything here without extra wiring — item
//  validation through the items' target (the controller), menuNeedsUpdate:
//  through the NSMenuDelegate wiring MainMenuBuilder installs.
//
//  NSMenuItemValidation conformance is declared on this category (not the
//  class extension) so the compiler checks its implementation in this file.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Menus) <NSMenuItemValidation>

// Action of the items menuNeedsUpdate: builds for the waveform-style submenu.
- (IBAction)setWaveformStyle:(id)sender;

@end

NS_ASSUME_NONNULL_END
