//
//  SettingsWindowController.m
//  Vibe
//

#import "SettingsWindowController.h"
#import "Constants.h"
#import "SettingsAdvancedViewController.h"
#import "SettingsAppearanceViewController.h"
#import "SettingsConvertViewController.h"
#import "SettingsGeneralViewController.h"
#import "SettingsPlaybackViewController.h"
#import "VibeStrings.h"

// Owns the tab-switch window resize. The panes' size constraints sit just
// below required (see SettingsPaneViewController), so the tab controller's
// own layout pass no longer snaps the window; this animates it to the
// incoming pane's preferredContentSize instead, top-left anchored, at the
// app's one fixed window-resize duration.
@interface SettingsTabViewController : NSTabViewController
@end

@implementation SettingsTabViewController

// Swallow the selected child's preferredContentSize instead of adopting it:
// a window whose contentViewController's preferredContentSize changes is
// resized by AppKit immediately, which is the snap that beats the animated
// resize below to the target frame and turns it into a no-op.
- (void)setPreferredContentSize:(NSSize)preferredContentSize {
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(NSTabViewItem *)tabViewItem {
    [super tabView:tabView didSelectTabViewItem:tabViewItem];
    NSWindow *window = self.view.window;
    NSViewController *pane = tabViewItem.viewController;
    if (!window || !pane) {
        return;
    }
    NSSize target = pane.preferredContentSize;
    NSRect content = [window contentRectForFrameRect:window.frame];
    content.origin.y += content.size.height - target.height;
    content.size = target;
    NSRect targetFrame = [window frameRectForContentRect:content];
    // The animator, not setFrame:display:animate: — the legacy blocking
    // stepper consumes its duration without rendering a single intermediate
    // frame here, an invisible "animation".
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = kWindowResizeAnimationDuration;
        [[window animator] setFrame:targetFrame display:YES];
    }];
}

@end

@implementation SettingsWindowController

// The pane's title is what names the tab AND the window: the tab controller
// propagates the selected child's title to itself, the window binds its own
// title to its contentViewController's, and setting the window title by hand
// instead loses to that chain — the propagation clears it to nil on every
// tab switch.
static NSTabViewItem *PaneItem(NSViewController *pane, NSString *label, NSString *symbolName) {
    pane.title = label;
    NSTabViewItem *item = [NSTabViewItem tabViewItemWithViewController:pane];
    item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:label];
    return item;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    SettingsTabViewController *tabs = [[SettingsTabViewController alloc] init];
    tabs.tabStyle = NSTabViewControllerTabStyleToolbar;

    [tabs addTabViewItem:PaneItem([[SettingsGeneralViewController alloc] initWithPlayerController:playerController],
                                  STR_SETTINGS_GENERAL, @"gearshape")];
    // The tab titles reuse the Playback and Appearance menu strings: same
    // word, same translations.
    [tabs addTabViewItem:PaneItem([[SettingsPlaybackViewController alloc] initWithPlayerController:playerController],
                                  STR_MENU_PLAYBACK, @"play.circle")];
    [tabs addTabViewItem:PaneItem([[SettingsAppearanceViewController alloc] initWithPlayerController:playerController],
                                  STR_MENU_VIEW_APPEARANCE, @"paintbrush")];
    // The Convert tab reuses the Convert menu's string too.
    [tabs addTabViewItem:PaneItem([[SettingsConvertViewController alloc] initWithPlayerController:playerController],
                                  STR_MENU_CONVERT, @"arrow.triangle.2.circlepath")];
    [tabs addTabViewItem:PaneItem([[SettingsAdvancedViewController alloc] initWithPlayerController:playerController],
                                  STR_SETTINGS_ADVANCED, @"gearshape.2")];

    // The window title comes from the title-propagation chain above, never
    // set directly here.
    NSWindow *window = [NSWindow windowWithContentViewController:tabs];
    // Not resizable: each pane owns its size.
    window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    window.toolbarStyle = NSWindowToolbarStylePreference;
    window.releasedWhenClosed = NO;
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        // After center, so a saved position wins over the default one.
        self.windowFrameAutosaveName = @"SettingsWindow";
        // The autosaved frame restores a SIZE too — possibly a different
        // pane's, and the sub-required pane constraints no longer correct it.
        // Re-assert the selected pane's size, top-left anchored like the
        // tab-switch resize, so the restored top edge stays put.
        NSSize paneSize = tabs.tabViewItems.firstObject.viewController.preferredContentSize;
        if (paneSize.width > 0) {
            NSRect content = [window contentRectForFrameRect:window.frame];
            content.origin.y += content.size.height - paneSize.height;
            content.size = paneSize;
            [window setFrame:[window frameRectForContentRect:content] display:NO];
        }
    }
    return self;
}

// File > Close (⌘W) is nil-targeted closeFile:; catching it while this window
// is key closes it, instead of falling through to the player's version, which
// clears the playlist.
- (IBAction)closeFile:(nullable id)sender {
    [self.window performClose:sender];
}

@end
