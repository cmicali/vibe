//
//  MainPlayerController+Window.h
//  Vibe
//
//  The window: the content build, the two content-view siblings, the resize,
//  lock and occlusion rules, and the actions that change its shape or
//  appearance.
//

#import "MainPlayerController.h"

@class MainWindow;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Window) <NSWindowDelegate, NSWindowRestoration>

// Adopts the built subviews as outlets. Runs from init, before windowDidLoad.
- (void)buildContentInWindow:(MainWindow *)window;

// The steady-state sibling frames: the body fills everything left of the
// panel's fixed slice; the panel hugs the right edge, parked past it while
// hidden.
- (NSRect)playerBodyFrame;
- (NSRect)pitchPanelFrame;

// Runs from windowDidLoad, after buildContentInWindow:.
- (void)buildPitchPanel;

// Factory reset's window half: the shipping shape, both panes closed. The
// controller places the siblings, so the window cannot reset alone.
- (void)resetWindowToDefaultShape;

// The playlist reveal: a height change, hence a window action.
- (IBAction)toggleSize:(nullable id)sender;
// Body widths only; the height belongs to the playlist toggle and the drag.
- (IBAction)setWindowSize:(id)sender;
// Shared with the Size checkmarks in +Menus.
+ (CGFloat)contentWidthForSizeIdentifier:(NSString *)identifier;

// The window's right edge sweeps past a stationary panel.
- (IBAction)togglePitchPanel:(nullable id)sender;

// Each apply* below pushes a stored setting, at construction and from its
// live effect, so the setting is read in one place.
- (IBAction)toggleAlwaysOnTop:(nullable id)sender;
- (void)applyAlwaysOnTop;

- (IBAction)toggleWindowPositionLock:(nullable id)sender;
// Sets movable, the lock's only state.
- (void)applyWindowLock;

- (void)applyTrafficLights;

// The theme's app icon, then the Dock tile re-decided from AppSettings.dockIcon.
- (void)applyAppIcon;

// The WindowChrome effect's body. applyWindowBackground alone is the
// appearance-flip half: the overlay's layer color is not dynamic.
- (void)applyWindowChrome;
- (void)applyWindowBackground;

// Never writes the setting.
- (void)applyStoredAppearance;

// The update timer's visibility gate: YES while unoccluded.
- (BOOL)isWindowVisible;

@end

NS_ASSUME_NONNULL_END
