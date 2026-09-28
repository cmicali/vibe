//
//  VibeSlider.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A horizontal 0-1 slider drawn in drawRect:. TRAP: not an NSSlider. AppKit
// draws an NSSlider through a SwiftUI host whose first render brings up a
// Metal device, and the GPU driver's 256 MB texture heap with it for about a
// second, hidden or not; the volume slider alone took the launch footprint
// from ~40 MB to ~305 MB.
//
// A click jumps the knob to the pointer (a grab on the knob keeps its offset)
// and sends the action; a drag sends it on every move; the release sends it
// once more, always. Each is sent from its own event handler, so
// NSApp.currentEvent is the event that moved the knob. Never first responder.
// Its value is NSControl's doubleValue, clamped to 0-1; setting it does not
// send the action.
@interface VibeSlider : NSControl

// The filled side of the track; nil is the system accent. Either way it draws
// gray while the window is not key, as NSSlider's does.
@property (nonatomic, copy, nullable) NSColor *trackFillColor;

// nil is the system's white knob.
@property (nonatomic, copy, nullable) NSColor *knobColor;

@end

NS_ASSUME_NONNULL_END
