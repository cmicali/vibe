//
//  PitchFaderView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The quartz-lock green shared by the fader's zero LED and the panel's
// readout. It is parameterized by alpha, and the LED glow uses a low-alpha
// variant.
#define VibeQuartzLockGreen(a) [NSColor colorWithRed:0.22 green:0.95 blue:0.40 alpha:(a)]

@class PitchFaderView;

@protocol PitchFaderViewDelegate <NSObject>
- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch;
// Fires once when a pitch gesture ends, on the mouse-up after a click or drag,
// or on the double-click reset. It is the hook for work too heavy to run on
// every drag tick.
- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView;
@end

// A Technics-style vertical pitch fader: the minus range at the top and plus
// at the bottom, so you slide toward yourself to speed up, with a soft detent
// at 0 and a quartz-lock-style green LED. It is hardware-styled, and draws the
// same in light and dark mode.
@interface PitchFaderView : NSView

@property (nullable, weak) id<PitchFaderViewDelegate> delegate;

// The pitch in percent, clamped to ±maxPitch. Setting it programmatically
// redraws but does not fire the delegate; only user interaction does.
@property (nonatomic) float pitch;

@property (nonatomic) float maxPitch; // default 8

@end

NS_ASSUME_NONNULL_END
