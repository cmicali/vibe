//
//  SettingsPaneViewController.h
//  Vibe
//
//  A pane subclass builds its sections (SettingsFormViews.h) in loadView,
//  hands them to loadPaneWithSections:, and reloads control state in
//  refreshFromSettings, which the base runs for the selected pane on
//  appearance, on regaining key, and after menu tracking ends.
//

#import <Cocoa/Cocoa.h>
#import "DrawnControls.h"
#import "SettingsFormViews.h"

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// Minimum width; a localization that needs more widens every pane.
static const CGFloat kSettingsPaneWidth = 480;

// Minimum content-layout height, below the titlebar.
static const CGFloat kSettingsPaneMinHeight = 480;

// A taller pane scrolls rather than raising every pane's floor.
static const CGFloat kSettingsPaneMaxHeight = 620;

// Shared by the section stack and the Appearance pane's editor page.
static const CGFloat kPanePadding = 20;

// The tab controller. A pane carries no size constraints
// (loadPaneWithSections:), so this is the only way its size reaches the window.
@protocol SettingsPaneSizeHost <NSObject>
- (void)settingsPaneSizeDidChange;
@end

@interface SettingsPaneViewController : NSViewController

@property (weak, readonly, nullable) MainPlayerController *playerController;

// The largest pane's natural size, shared by every pane.
// TRAP: deliberately NOT preferredContentSize. macOS 26.5 turns a nonzero one
// into priority-501 equalities on the pane's view, one above
// NSLayoutPriorityWindowSizeStayPut, which pin the window's size.
@property (readonly, nonatomic) NSSize sharedPaneSize;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Entries are normally SettingsSectionViews; a plain view stacks full width,
// outside any card (the About pane's identity block).
- (void)loadPaneWithSections:(NSArray<__kindof NSView *> *)sections;

// Loads every pane, resolves only its layout state (no refresh work), and
// sizes them all to the largest, so a pane switch resizes nothing.
+ (void)settleSharedSizeForPanes:(NSArray<__kindof NSViewController *> *)panes;

// The System Settings inline dropdown. width caps a runaway title rather than
// sizing the popup. Pass NULL for a popup whose items carry their own targets.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(nullable SEL)action;

// Localized title shown, stable identifier on representedObject.
- (void)addItem:(NSString *)title value:(nullable id)value to:(NSPopUpButton *)popUp;

// Selects the item whose representedObject is value, or none.
- (void)selectValue:(nullable id)value in:(NSPopUpButton *)popUp;

// Reads and writes NSControlStateValueOn/Off, like a checkbox.
- (VibeSwitch *)switchWithAction:(SEL)action;

// Resolves only state that changes the pane's measured layout (rows hidden or
// revealed). The shared-size pass calls it on every pane, so it must not start
// refresh work.
- (void)resolveLayoutStateFromSettings;

// Reloads every control. Only ever called for the selected pane.
- (void)refreshFromSettings;

// Remeasures this pane and, when its natural size moved, re-sizes every pane
// to the largest in one animated transaction with the window frame. No-op
// while the window is hidden. A pane that hides or shows a row outside
// refreshSettingsAndPaneSize must call it, or the window keeps a stale size.
- (void)paneContentDidChange;

// The three steps above; every selected-pane trigger and the debug channel's
// store-writing verbs run it.
- (void)refreshSettingsAndPaneSize;

@end

NS_ASSUME_NONNULL_END
