//
//  SettingsPaneViewController.h
//  Vibe
//
//  Shared scaffolding for the settings panes: the pane sizing, the grouped
//  section stack, and the refresh contract. A pane subclass builds its
//  sections (SettingsFormViews.h) in loadView, hands them to
//  loadPaneWithSections:, and reloads control state in refreshFromSettings,
//  which the base runs for the selected pane on every appearance, whenever
//  the window regains key, and after any menu-bar interaction ends.
//

#import <Cocoa/Cocoa.h>
#import "SettingsFormViews.h"

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// The design width of a pane; the shared width grows to the widest pane's
// section stack when a localization needs more.
static const CGFloat kSettingsPaneWidth = 480;

// No pane is ever shorter than this (content-layout height, below the
// titlebar), so the settings window holds one roomy System Settings-like
// size instead of hugging its panes' content.
static const CGFloat kSettingsPaneMinHeight = 480;

// The content inset every pane page uses — the base section stack and the
// Appearance pane's editor page alike.
static const CGFloat kPanePadding = 20;

// The panes' host — the tab controller — owns the window's size. A pane's own
// constraints sit below required, so the window edge wins over them while a
// pane is on screen (see SettingsWindowController); this is how a size change
// made while the window is open reaches the frame.
@protocol SettingsPaneSizeHost <NSObject>
- (void)settingsPaneSizeDidChange;
@end

@interface SettingsPaneViewController : NSViewController

@property (weak, readonly, nullable) MainPlayerController *playerController;

// The one size every pane presents — the largest pane's, applied by
// settleSharedSizeForPanes:. TRAP: deliberately NOT preferredContentSize.
// macOS 26.5 turns a nonzero preferredContentSize into active equality
// constraints on the pane's view at priority 501 — one above
// NSLayoutPriorityWindowSizeStayPut — which fully determines the window's
// size: no resize cursor at all, and every programmatic resize snapped back.
@property (readonly, nonatomic) NSSize sharedPaneSize;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Builds the pane's root view: the sections stacked top-down, at least the
// design size, grown to fit them. The size the pane finally presents is the
// shared one below, not this measurement. Entries are normally
// SettingsSectionViews; a plain view stacks the same, full width, for content
// that sits outside any card (the About pane's identity block).
- (void)loadPaneWithSections:(NSArray<__kindof NSView *> *)sections;

// Loads every pane, resolves only the state that affects its layout, and sizes
// them all to the largest — the one size the window then holds, so a pane
// switch resizes nothing. Full refreshes remain selected-pane work.
+ (void)settleSharedSizeForPanes:(NSArray<__kindof NSViewController *> *)panes;

// The System Settings inline dropdown — borderless, the value beside an
// always-drawn chevron badge, no hover treatment (the reference has none),
// value hugging the row's trailing edge; width caps a runaway title. Pass
// NULL for a popup whose items carry their own targets.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(nullable SEL)action;

// One popup item: title shown, stable identifier on representedObject — the
// pairing every settings popup uses, so a mis-paired title/value cannot
// happen one line at a time.
- (void)addItem:(NSString *)title value:(nullable id)value to:(NSPopUpButton *)popUp;

// The iOS-style toggle every boolean row uses; reads and writes exactly like
// the checkbox it replaced (NSControlStateValueOn/Off).
- (NSSwitch *)switchWithAction:(SEL)action;

// Resolves only state that changes the pane's measured layout. Override when
// settings hide or reveal rows; the eager shared-size pass calls this for all
// panes and must not start refresh work.
- (void)resolveLayoutStateFromSettings;

// Reloads every control from AppSettings and live state. The base invokes it
// only for the selected pane; the eager shared-size pass never calls it.
- (void)refreshFromSettings;

// Remeasures every pane against the rows it is actually showing and re-sizes
// them all to the largest, which is what the settings window sizes itself to.
// The remeasurement, the stack layout and the window frame land in one
// animated transaction while the window is visible, so the rows cannot jump
// ahead of the window. The base selected-pane refresh path runs it after
// refreshing; a pane that hides or shows a row at any other moment must call
// it, or the window keeps the size it was last measured at.
- (void)paneContentDidChange;

// The three steps above as one refresh — what every selected-pane trigger
// (appearance, window-key regain, menu-tracking end) runs. The debug
// channel's store-writing verbs run it too, so a scripted write is followed
// by the same refresh a user gesture gets.
- (void)refreshSettingsAndPaneSize;

@end

NS_ASSUME_NONNULL_END
