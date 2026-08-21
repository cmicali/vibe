//
//  SettingsPaneViewController.h
//  Vibe
//
//  Shared scaffolding for the settings panes: the pane sizing, the grouped
//  section stack, and the refresh contract. A pane subclass builds its
//  sections (SettingsFormViews.h) in loadView, hands them to
//  loadPaneWithSections:, and reloads control state in refreshFromSettings,
//  which the base runs on every appearance, whenever the window regains key,
//  and after any menu-bar interaction ends — so the visible pane tracks
//  changes made through the menus or after a system panel.
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

// The panes' host — the tab controller — owns the window's size. A pane's own
// constraints sit below required, so the window edge wins over them while a
// pane is on screen (see SettingsWindowController); this is how a size change
// made while the window is open reaches the frame instead of waiting for the
// next pane switch.
@protocol SettingsPaneSizeHost <NSObject>
- (void)settingsPaneSizeDidChange;
@end

@interface SettingsPaneViewController : NSViewController

@property (weak, readonly, nullable) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Builds the pane's root view: the sections stacked top-down, at least the
// design size, grown to fit them. The size the pane finally presents is the
// shared one below, not this measurement. Entries are normally
// SettingsSectionViews; a plain view stacks the same, full width, for content
// that sits outside any card (the About pane's identity block).
- (void)loadPaneWithSections:(NSArray<__kindof NSView *> *)sections;

// Loads every pane, settles which of its rows are visible, and sizes them all
// to the largest — the one size the window then holds, so a pane switch
// resizes nothing. The settings window controller calls it once, as soon as
// its panes exist; measuring a pane before its rows settle would reserve room
// for rows nobody sees (see paneContentDidChange).
+ (void)settleSharedSizeForPanes:(NSArray<__kindof NSViewController *> *)panes;

// A fixed-width popup targeting the pane; pass NULL for a popup whose items
// carry their own targets.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(nullable SEL)action;

// The iOS-style toggle every boolean row uses; reads and writes exactly like
// the checkbox it replaced (NSControlStateValueOn/Off).
- (NSSwitch *)switchWithAction:(SEL)action;

// Reloads every control from AppSettings and live state. Override; the base
// implementation does nothing.
- (void)refreshFromSettings;

// Remeasures every pane against the rows it is actually showing and re-sizes
// them all to the largest, which is what the settings window sizes itself to.
// The base runs it after every refreshFromSettings; a pane that hides or shows
// a row at any other moment must call it, or the window keeps the size it was
// last measured at.
- (void)paneContentDidChange;

@end

NS_ASSUME_NONNULL_END
