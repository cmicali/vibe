//
//  MainMenuBuilder.h
//  Vibe
//

#import <Cocoa/Cocoa.h>
#import "ShortcutRules.h"

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

// The ConvertMenu and FX settings effects' hooks. Each menu is always built
// and hidden in place, and each call re-applies the shortcuts, which a
// hidden menu withdraws.
+ (void)applyConvertMenuVisibility;
+ (void)applyFXMenuVisibility;

// The Shortcuts settings effect's hook: the one place a remappable item's key
// equivalent is set, from the effective shortcuts under the current layout.
+ (void)applyShortcuts;

+ (nullable NSMenuItem *)mainMenuItemWithIdentifier:(NSString *)identifier;

// The key's lowercase character under the current layout, 0 when it has none;
// what the rules compare against the fixed and character shortcuts.
+ (unichar)characterForKeyCode:(unsigned short)keyCode;

// The key's name as the menu draws it, nil for a key no layout names.
+ (nullable NSString *)labelForKeyCode:(unsigned short)keyCode;

// ⌃⌥⇧⌘ then the key, as the menu draws it; the unassigned label for None.
+ (NSString *)displayStringForShortcut:(VibeShortcut)shortcut;

@end

NS_ASSUME_NONNULL_END
