//
//  SettingsPaneViewController.h
//  Vibe
//
//  Shared scaffolding for the settings panes: the pane sizing, the
//  top-centered form grid, and the refresh contract. A pane subclass builds
//  its controls in loadView, hands them to loadPaneWithSize:grid:, and
//  reloads control state in refreshFromSettings, which the base runs on every
//  appearance, whenever the window regains key, and after any menu-bar
//  interaction ends — so the visible pane tracks changes made through the
//  menus or after a system panel.
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// The design width of a pane; the actual width grows to the form grid's
// fitting width when a localization needs more.
static const CGFloat kSettingsPaneWidth = 480;

// Every pane is at least this tall (content-layout height, below the
// titlebar), so the settings window holds one roomy System Settings-like
// size instead of hugging each pane's content.
static const CGFloat kSettingsPaneMinHeight = 480;

@interface SettingsPaneViewController : NSViewController

@property (weak, readonly, nullable) MainPlayerController *playerController;

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController;

// Builds the pane's root view: at least size, grown to fit the grid, with
// the grid pinned top-center.
- (void)loadPaneWithSize:(NSSize)size grid:(NSGridView *)grid;

// A two-column form grid: labels in column 0, trailing-aligned; controls in
// column 1. Use NSGridCell.emptyContentView for a label-less row.
+ (NSGridView *)formGridWithRows:(NSArray<NSArray<NSView *> *> *)rows;

// A fixed-width popup targeting the pane; pass NULL for a popup whose items
// carry their own targets.
- (NSPopUpButton *)popUpButtonWithWidth:(CGFloat)width action:(nullable SEL)action;

// Reloads every control from AppSettings and live state. Override; the base
// implementation does nothing.
- (void)refreshFromSettings;

@end

NS_ASSUME_NONNULL_END
