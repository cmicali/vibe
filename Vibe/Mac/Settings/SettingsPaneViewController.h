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

// The design width of a pane; the actual width grows to the section stack's
// fitting width when a localization needs more.
static const CGFloat kSettingsPaneWidth = 480;

// Every pane is at least this tall (content-layout height, below the
// titlebar), so the settings window holds one roomy System Settings-like
// size instead of hugging each pane's content.
static const CGFloat kSettingsPaneMinHeight = 480;

@interface SettingsPaneViewController : NSViewController

@property (weak, readonly, nullable) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Builds the pane's root view: the sections stacked top-down, at least the
// design size, grown to fit them.
- (void)loadPaneWithSections:(NSArray<SettingsSectionView *> *)sections;

// A fixed-width popup targeting the pane; pass NULL for a popup whose items
// carry their own targets.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(nullable SEL)action;

// The iOS-style toggle every boolean row uses; reads and writes exactly like
// the checkbox it replaced (NSControlStateValueOn/Off).
- (NSSwitch *)switchWithAction:(SEL)action;

// Reloads every control from AppSettings and live state. Override; the base
// implementation does nothing.
- (void)refreshFromSettings;

@end

NS_ASSUME_NONNULL_END
