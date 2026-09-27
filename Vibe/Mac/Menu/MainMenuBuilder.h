//
//  MainMenuBuilder.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class MainPlayerController;
@class OpenRecentMenuController;

NS_ASSUME_NONNULL_BEGIN

// A stateless one-shot. Each live submenu's delegate is owned by the object it
// works for and only wired here; validation lives with the items' targets.
@interface MainMenuBuilder : NSObject

// Menu delegates are weak, so openRecentMenuController must outlive the menu.
+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)playerController
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController;

// The main menu's item style, with no key equivalent, for context menus.
+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(nullable id)target
                         identifier:(nullable NSString *)identifier;

// Shared with the window-body context menu, so each identifier, symbol and
// validation branch lives in one place. No key equivalent: the menu bar adds
// its own.
+ (NSMenuItem *)copyNameItemWithTarget:(nullable id)target;
+ (NSMenuItem *)copyFileItemWithTarget:(nullable id)target;
+ (NSMenuItem *)convertToFLACItemWithTarget:(nullable id)target;

// The ConvertMenu settings effect's hook; the menu is always built.
+ (void)applyConvertMenuVisibility;

// Also withdraws or restores the bare shortcuts; the menu is always built.
+ (void)applyFXMenuVisibility;

@end

NS_ASSUME_NONNULL_END
