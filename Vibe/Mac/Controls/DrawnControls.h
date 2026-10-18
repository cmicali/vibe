//
//  DrawnControls.h
//  Vibe
//
//  TRAP: use custom drawing to avoid AppKit's SwiftUI control hosts and
//  their Metal startup cost on macOS 26. See Mac/Controls/AGENTS.md.
//
//  Both draw gray while the window is not key and at half alpha disabled, as
//  AppKit's do. Neither is first responder except the switch under full
//  keyboard access.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A horizontal 0-1 slider. A click jumps the knob to the pointer (a grab on
// the knob keeps its offset) and sends the action; a drag sends it on every
// move; the release sends it once more, always. Each is sent from its own
// event handler, so NSApp.currentEvent is the event that moved the knob. Its
// value is NSControl's doubleValue, clamped to 0-1; setting it does not send
// the action.
@interface VibeSlider : NSControl

// The filled side of the track; nil is the system accent.
@property (nonatomic, copy, nullable) NSColor *trackFillColor;

// nil is the system's white knob.
@property (nonatomic, copy, nullable) NSColor *knobColor;

// Moves the value by that many 5% steps, a fraction included, and sends the
// action when it moved, as a VoiceOver step does without its rounding. NO
// when disabled or unmoved.
- (BOOL)moveBySteps:(double)steps;

@end

// The small on/off switch, to NSSwitch's measured metrics and colors. A
// click, space or an accessibility press toggles it, slides the knob and
// sends the action; setting state does neither.
@interface VibeSwitch : NSControl
@property (nonatomic) NSControlStateValue state;
@end

NS_ASSUME_NONNULL_END
