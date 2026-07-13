//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class PitchFaderView;

@protocol PitchFaderViewDelegate <NSObject>
- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch;
@end

// Technics-style vertical pitch fader: minus range at the top, plus at the
// bottom (slide toward you to speed up), soft detent at 0 with a quartz-lock
// style green LED. Hardware-styled — draws the same in light and dark mode.
@interface PitchFaderView : NSView

@property (nullable, weak) id<PitchFaderViewDelegate> delegate;

// Percent, clamped to ±maxPitch. Setting it programmatically redraws but does
// NOT fire the delegate (only user interaction does).
@property (nonatomic) float pitch;

@property (nonatomic) float maxPitch; // default 10

@end

NS_ASSUME_NONNULL_END
