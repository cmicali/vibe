//
//  TransportKeyMonitor.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// Handles the main window's bare transport keys with a local monitor on
// keyDown and keyUp, rather than relying on the menu's unmodified key
// equivalents. The keys are Space, B, N, P and Tab; A, S and D and Z, X and C
// for skip-seek; and the dual-mode effect keys Q, W, E, R and T, where a tap
// toggles the effect and a hold is momentary — on at keyDown, back to the
// pre-press state at keyUp.
//
// Menu key equivalents fire only as a fallback, after the focused view's
// keyDown and input-context machinery declines the event, and that path is
// fragile. The playlist table's input context can wedge after an unhandled
// letter: press any unbound key while the table is focused and every
// subsequent key beeps, which killed B and N until the app was relaunched. The
// monitor sees the event before any of that runs.
//
// The monitor is installed at init and removed at dealloc, so the owning
// controller simply holds one for the window's lifetime.
@interface TransportKeyMonitor : NSObject

- (instancetype)initWithController:(MainPlayerController *)controller;

@end

NS_ASSUME_NONNULL_END
