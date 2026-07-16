//
//  TransportKeyMonitor.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// Handles the bare transport keys (Space/B/N/P/Q/Tab, momentary W/E/R) for the main window with
// a local keyDown monitor instead of relying on the menu's unmodified key
// equivalents. Those only fire as a fallback after the focused view's
// keyDown/input-context machinery declines the event, and that path is
// fragile: the playlist table's input context can wedge after an unhandled
// letter (observed: press any unbound key while the table is focused and
// every subsequent key beeps, killing B/N until relaunch). The monitor sees
// the event before any of that runs.
//
// The monitor is installed at init and removed at dealloc — the owning
// controller just holds one for the window's lifetime.
@interface TransportKeyMonitor : NSObject

- (instancetype)initWithController:(MainPlayerController *)controller;

@end

NS_ASSUME_NONNULL_END
