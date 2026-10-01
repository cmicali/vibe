//
//  MainPlayerController+Menus.h
//  Vibe
//
//  Validation for every item the controller targets (MenuValidationRules.h),
//  and the delegate-built View > Theme submenu.
//

#import "MainPlayerController.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Menus) <NSMenuItemValidation>

- (IBAction)selectTheme:(id)sender;

// What choosing the item would do: validated first, sent with the item as
// sender (Size and Pitch Range read its identifier), and only after
// validation, which can swap Convert's action. NO when disabled, hidden,
// unhandled, or a submenu parent.
- (BOOL)performMenuItem:(NSMenuItem *)item;
// Performs the main menu's item with that identifier; the key monitor's one
// way to perform a command it has no special handling for. YES while the item
// is visible, performed or disabled; NO, so the key passes on as unbound,
// when it is hidden or absent.
- (BOOL)performMenuCommandWithIdentifier:(NSString *)identifier;

// Re-resolves colors without writing a setting.
- (void)refreshWaveformTheme;

@end

NS_ASSUME_NONNULL_END
