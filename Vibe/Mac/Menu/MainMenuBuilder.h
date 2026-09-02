//
//  MainMenuBuilder.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class AppDelegate;
@class MainPlayerController;
@class OpenRecentMenuController;

NS_ASSUME_NONNULL_BEGIN

// Builds the app's menu bar. It is a stateless one-shot, so there is nothing
// to instantiate or keep alive. Every live submenu's delegate is owned by the
// object it works for and supplied here to be wired: Open Recent by the app
// delegate's OpenRecentMenuController, Output by the player's
// OutputDevicesMenuController, and View > Theme by the player controller
// itself. Item validation lives with the items' targets, in
// MainPlayerController+Menus.
@interface MainMenuBuilder : NSObject

// Builds the menu bar and sets it as NSApp.mainMenu, and as its servicesMenu.
// Menu delegates are weak references, so openRecentMenuController must outlive
// the menu; the app delegate owns it.
+ (void)installMainMenuWithAppDelegate:(AppDelegate *)appDelegate
                      playerController:(MainPlayerController *)playerController
              openRecentMenuController:(OpenRecentMenuController *)openRecentMenuController;

// One symbol-carrying item with no key equivalent, for context menus that
// want the main menu's item style without duplicating its SF Symbol wiring.
+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(nullable id)target
                         identifier:(nullable NSString *)identifier;

// The items the window-body context menu shares with the main menu: same
// title, symbol, identifier and, through the identifier, the same validation
// branch. Vending them keeps each identifier and symbol in exactly one file.
// They carry no key equivalent — that is the menu bar's concern, and
// installMainMenuWithAppDelegate: adds it to its own copies.
+ (NSMenuItem *)copyNameItemWithTarget:(nullable id)target;
+ (NSMenuItem *)copyFileItemWithTarget:(nullable id)target;
+ (NSMenuItem *)convertToFLACItemWithTarget:(nullable id)target;

// Shows or hides the menu bar's Convert menu in place. The build seeds the
// initial state; the ConvertMenu settings effect calls this after a write.
+ (void)applyConvertMenuVisibility;

// Shows or hides the FX menu and withdraws or restores its bare shortcuts when
// this run has an FX graph. The graph itself remains a launch-time choice.
+ (void)applyFXMenuVisibility;

@end

NS_ASSUME_NONNULL_END
