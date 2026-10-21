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

// A context menu's item: a title, an SF Symbol and no key equivalent. The
// menu bar carries no symbols, as Apple's own menus do not.
+ (NSMenuItem *)symbolItemWithTitle:(NSString *)title
                         symbolName:(NSString *)symbolName
                             action:(SEL)action
                             target:(nullable id)target
                         identifier:(nullable NSString *)identifier;

// The ConvertMenu and FX settings effects' hooks. Each menu is always built
// and hidden in place, and each call re-applies the shortcuts, which a
// hidden menu withdraws.
+ (void)applyConvertMenuVisibility;
+ (void)applyFXMenuVisibility;

// The Shortcuts settings effect's hook: the one place a remappable item's key
// equivalent is set, from the effective shortcuts under the current layout.
+ (void)applyShortcuts;

// The shortcut identifier's command carries under the current layout, the
// one the menu shows and the Shortcuts settings list. None when its effective
// shortcut lands on a reserved key, or on a key an earlier command holds
// (VibeShortcutForMenuItem). A hidden menu is not considered.
+ (VibeShortcut)carriedShortcutForIdentifier:(NSString *)identifier overrides:(nullable NSDictionary *)overrides;

+ (nullable NSMenuItem *)mainMenuItemWithIdentifier:(NSString *)identifier;

// The Keyboard Shortcuts pane's rows: every remappable command under its
// menu's title, in menu order, as @[title, @[@[identifier, label], …]] per
// menu. The labels are the menu's own titles, but the items validation
// retitles take stable names: Play, Convert to FLAC, and the skips in their
// bars form whatever the track's tempo. A submenu's item reads "Skip Back:
// 4 Bars". Built from NSApp.mainMenu on each call.
+ (NSArray<NSArray *> *)shortcutCommandRows;

@end

NS_ASSUME_NONNULL_END
