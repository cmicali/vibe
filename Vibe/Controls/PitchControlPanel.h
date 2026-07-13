//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "PitchFaderView.h"

NS_ASSUME_NONNULL_BEGIN

// Width the main window grows by when the pitch panel is revealed.
extern const CGFloat kPitchPanelWidth;

// The slide-out strip on the window's right edge: PITCH title, live percent
// readout, and a Technics-style fader. Fader changes are forwarded to the
// panel's delegate; setting .pitch programmatically updates fader + readout
// without firing it.
@interface PitchControlPanel : NSView

@property (nullable, weak) id<PitchFaderViewDelegate> delegate;

@property (nonatomic) float pitch;

// Fader range in percent; forwarded to the fader (which rescales and
// re-clamps). Keep in sync with AudioPlayer.maxPitch.
@property (nonatomic) float maxPitch;

@end

NS_ASSUME_NONNULL_END
