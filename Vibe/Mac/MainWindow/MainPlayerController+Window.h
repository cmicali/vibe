//
//  MainPlayerController+Window.h
//  Vibe
//
//  The window itself: building the content hierarchy into it, the two
//  content-view sibling frames, the resize and occlusion rules, and the menu
//  actions that change the window's shape or appearance — size presets, the
//  pitch-panel reveal, always-on-top and the light/dark choice.
//
//  Pure AppKit geometry and lifecycle. The one place it reaches into the
//  player's world is the update timer's occlusion gate, which is a visibility
//  question rather than a playback one.
//

#import "MainPlayerController.h"

@class MainWindow;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Window) <NSWindowDelegate, NSWindowRestoration>

// Builds the content hierarchy into the window and adopts its subviews as the
// controller's outlets. Runs from init, before windowDidLoad.
- (void)buildContentInWindow:(MainWindow *)window;

// The window's two content-view siblings in the resizable steady state: the
// player body fills everything left of the pitch panel's fixed-width slice,
// and the panel hugs the right edge — parked just past it while hidden.
- (NSRect)playerBodyFrame;
- (NSRect)pitchPanelFrame;

// The playlist reveal: ⇥ and View > Show Playlist. It is a window height
// change, hence a window action.
- (IBAction)toggleSize:(nullable id)sender;
// View > Size. The presets set body widths only; the height belongs to the
// playlist toggle and the user's drag.
- (IBAction)setWindowSize:(id)sender;
// The body width each View > Size preset means. It lives next to
// setWindowSize:, because the Size checkmarks in +Menus must resolve the same
// identifier-to-width mapping the action does.
+ (CGFloat)contentWidthForSizeIdentifier:(NSString *)identifier;

// The pitch panel's reveal, which is the window's right edge sweeping past a
// stationary panel rather than a subview sliding in.
- (IBAction)togglePitchPanel:(nullable id)sender;

- (IBAction)toggleAlwaysOnTop:(nullable id)sender;
// Pushes AppSettings.sharedInstance.alwaysOnTop to the window's level. The Settings pane calls
// it after writing the setting; the menu action funnels through it too.
- (void)applyAlwaysOnTop;

// View > Appearance, dispatching on the menu item's identifier. The Settings
// pane calls it with nil after writing the setting.
- (IBAction)setAppearance:(nullable id)sender;

// YES while the window is unoccluded. The update timer's visibility gate.
- (BOOL)isWindowVisible;

@end

NS_ASSUME_NONNULL_END
