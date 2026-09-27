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

// Re-resolves colors without writing a setting.
- (void)refreshWaveformTheme;

@end

NS_ASSUME_NONNULL_END
