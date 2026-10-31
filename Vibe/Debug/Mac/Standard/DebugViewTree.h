//
//  DebugViewTree.h
//  vibe-libs
//
//  What dump_view_tree, dump_menu, and click_menu read: the windows and their
//  view trees, the menu bar, and the menu item search.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Every window and its content view's tree, as the JSON reply.
NSString *VibeViewTreeDump(void);

// menu's items, validated as opening the menu would validate them.
NSArray *VibeMenuArray(NSMenu *menu);

// The first item in menu or its submenus whose identifier or title is
// identifierOrTitle, or nil.
NSMenuItem *_Nullable VibeFindMenuItem(NSMenu *menu, NSString *identifierOrTitle);

NS_ASSUME_NONNULL_END
