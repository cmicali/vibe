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
#import "MainPlayerController+Settings.h" // VibeSettingsLiveEffect, coalesced below

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// Minimum width; a localization that needs more widens every pane.
static const CGFloat kSettingsPaneWidth = 480;

// Minimum content-layout height, below the titlebar.
static const CGFloat kSettingsPaneMinHeight = 480;

// A taller pane scrolls rather than raising every pane's floor.
static const CGFloat kSettingsPaneMaxHeight = 620;

// Shared by the section stack and the Themes pane's editor page.
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

// The slider made continuous and `width` wide, beside a fixed-width readout
// the caller fills: a changing value never nudges the slider.
- (NSStackView *)clusterWithSlider:(NSSlider *)slider width:(CGFloat)width
                        valueLabel:(NSTextField *__strong _Nonnull *_Nonnull)outLabel;

// A secondary-colored wrapping label for rowWithContentView:. It measures
// its height at preferredMaxLayoutWidth, which the pane's viewDidLayout keeps
// at the row's real width; its compression resistance sits below the fitting
// priority, so the unwrapped text never widens every pane, and no width cap
// is set (rowWithContentView:'s trap).
- (NSTextField *)wrappingLabelWithString:(NSString *)text;

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

// The sidebar's search. A pane matches on its own title or on a searchable
// row's title, caption or section header, ignoring case and diacritics.
- (BOOL)matchesSearch:(NSString *)query;
- (NSArray<SettingsRowView *> *)rowsMatchingSearch:(NSString *)query;
// Every row not hidden itself; a pane whose section hides for another reason
// than a page swap excludes it here.
- (BOOL)isRowSearchable:(SettingsRowView *)row;
// Marks the matching rows (nil clears) and, on screen, reveals the first.
- (void)setSearchHighlight:(nullable NSString *)query;
@property (readonly, nonatomic, copy, nullable) NSString *searchQuery;
// Scrolls the first marked row into view; the pane's appearance repeats it.
- (void)revealSearchHits;

// A drag's live work at a steady cadence: each tick, having written its value,
// ORs in the effects it needs, and they apply at most every 1/30 s, so a 120 Hz
// drag re-renders a quarter as often and its last value always lands. The
// effects read the store, so a later apply carries every tick before it.
- (void)applyLiveEffectsDuringDrag:(VibeSettingsLiveEffect)effects;
// Runs after a coalesced apply, with what it applied; a pane redraws what
// shows the effects (the Appearance pane's waveform preview).
- (void)didApplyDragEffects:(VibeSettingsLiveEffect)effects;

// A pane that keeps its own undo stack; Edit > Undo reaches it while the pane
// is selected.
@property (readonly, nonatomic, nullable) NSUndoManager *paneUndoManager;

@end

NS_ASSUME_NONNULL_END
