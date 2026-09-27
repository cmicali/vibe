//
//  PitchFaderView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Shared by the fader's zero LED (and its low-alpha glow) and the readout.
#define VibeQuartzLockGreen(a) [NSColor colorWithRed:0.22 green:0.95 blue:0.40 alpha:(a)]

@class PitchFaderView;

@protocol PitchFaderViewDelegate <NSObject>
- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch;
// Once per gesture (mouse-up, double-click reset or an accessibility step).
- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView;
@end

// A Technics-style fader: minus at the top, plus at the bottom, a detent at 0
// and a quartz-lock LED. Hardware-styled, the same in both appearances.
@interface PitchFaderView : NSView

@property (nullable, weak) id<PitchFaderViewDelegate> delegate;

// Percent, clamped to ±maxPitch. Setting it does not fire the delegate.
@property (nonatomic) float pitch;

@property (nonatomic) float maxPitch; // default 8

@end

NS_ASSUME_NONNULL_END
