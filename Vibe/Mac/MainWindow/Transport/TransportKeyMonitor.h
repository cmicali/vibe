//
//  TransportKeyMonitor.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// The main window's shortcuts (ShortcutRules.h), through a local monitor on
// keyDown and keyUp; in other windows only a Command binding's unwanted
// repeats, which the menu bar would perform.
// Menu key equivalents fire only after the focused view's input context
// declines the event, and an unhandled key can wedge the playlist table's
// input context so every later key beeps; the monitor sees the event first.
// Installed at init, removed at dealloc.
@interface TransportKeyMonitor : NSObject

- (instancetype)initWithController:(MainPlayerController *)controller;

// window is explicit so host-less tests can drive the real handler.
- (nullable NSEvent *)handleKeyEvent:(NSEvent *)event inWindow:(nullable NSWindow *)window;

@end

NS_ASSUME_NONNULL_END
