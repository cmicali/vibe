//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Width the main window grows by when the pitch panel is revealed.
extern const CGFloat kPitchPanelWidth;

@class PitchControlPanel;

// A panel-level delegate. The fader inside the panel is an implementation
// detail, so gestures are reported with the panel as the sender.
@protocol PitchControlPanelDelegate <NSObject>
- (void)pitchControlPanel:(PitchControlPanel *)panel didChangePitch:(float)pitch;
// Fires once when a pitch gesture ends, on the mouse-up after a click or drag,
// or on the double-click reset. It is the hook for work too heavy to run on
// every drag tick.
- (void)pitchControlPanelDidEndAdjusting:(PitchControlPanel *)panel;
@end

// The slide-out strip on the window's right edge: a PITCH title, a live
// percent readout and a Technics-style fader. Fader changes are forwarded to
// the panel's delegate, and setting .pitch programmatically updates both the
// fader and the readout without firing it.
@interface PitchControlPanel : NSView

@property (nullable, weak) id<PitchControlPanelDelegate> delegate;

@property (nonatomic) float pitch;

// The fader range in percent, forwarded to the fader, which rescales and
// re-clamps. Keep it in sync with AudioPlayer.maxPitch.
@property (nonatomic) float maxPitch;

@end

NS_ASSUME_NONNULL_END
