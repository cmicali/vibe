//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "PitchFaderView.h"
#import "Fonts.h"

// Slot/knob geometry (points).
static const CGFloat kSlotWidth       = 6;
static const CGFloat kKnobWidth       = 40;
static const CGFloat kKnobHeight      = 22;
static const CGFloat kTickLength      = 9;
static const CGFloat kTickGap         = 6;  // gap between slot and ticks
static const CGFloat kLabelGap        = 4;  // gap between ticks and labels
// Dragging inside this band snaps to exactly 0 — the center detent.
static const float   kDetentPercent   = 0.35f;

@implementation PitchFaderView {
    BOOL    _dragging;
    // Offset between the mouse-down point and the knob center, so grabbing
    // the knob by its edge doesn't make it jump.
    CGFloat _dragOffsetY;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _maxPitch = 8;
    }
    return self;
}

- (BOOL)isFlipped {
    // Flipped so y grows downward: pitch maps top(-) to bottom(+) directly.
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    // The window is movable-by-background and this view is non-opaque, so
    // without this a fader drag ALSO drags the whole window along.
    return NO;
}

- (void)setMaxPitch:(float)maxPitch {
    if (maxPitch != _maxPitch) {
        _maxPitch = maxPitch;
        _pitch = MAX(-maxPitch, MIN(maxPitch, _pitch));
        self.needsDisplay = YES;
    }
}

- (void)setPitch:(float)pitch {
    pitch = MAX(-_maxPitch, MIN(_maxPitch, pitch));
    if (pitch != _pitch) {
        _pitch = pitch;
        self.needsDisplay = YES;
    }
}

#pragma mark - Geometry

// Vertical travel of the knob center: inset so the knob never clips.
- (CGFloat)travelTop {
    return kKnobHeight / 2 + 2;
}

- (CGFloat)travelBottom {
    return self.bounds.size.height - kKnobHeight / 2 - 2;
}

- (CGFloat)yForPitch:(float)pitch {
    CGFloat fraction = (pitch + _maxPitch) / (2 * _maxPitch); // 0 = top (-max)
    return self.travelTop + fraction * (self.travelBottom - self.travelTop);
}

- (float)pitchForY:(CGFloat)y {
    CGFloat travel = self.travelBottom - self.travelTop;
    if (travel <= 0) {
        return 0;
    }
    CGFloat fraction = (y - self.travelTop) / travel;
    return (float)(fraction * 2 * _maxPitch) - _maxPitch;
}

- (NSRect)knobRect {
    CGFloat centerX = NSMidX(self.bounds);
    return NSMakeRect(centerX - kKnobWidth / 2,
                      [self yForPitch:_pitch] - kKnobHeight / 2,
                      kKnobWidth, kKnobHeight);
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    CGFloat centerX = NSMidX(self.bounds);

    [self drawScaleAroundCenterX:centerX];
    [self drawSlotAtCenterX:centerX];
    [self drawZeroLEDAtCenterX:centerX];
    [self drawKnobInRect:self.knobRect];
}

- (void)drawScaleAroundCenterX:(CGFloat)centerX {
    NSColor *tickColor = [NSColor colorWithWhite:0.62 alpha:1];
    NSColor *minorTickColor = [NSColor colorWithWhite:0.38 alpha:1];
    NSDictionary *labelAttributes = @{
            NSFontAttributeName: [Fonts fontForNumbers:8 bold:NO],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.62 alpha:1],
    };
    NSDictionary *signAttributes = @{
            NSFontAttributeName: [Fonts fontForNumbers:9 bold:YES],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.62 alpha:1],
    };

    // Adapt density to the travel: the short (playlist-hidden) window has only
    // a few points per percent, where the full Technics scale turns to mush.
    CGFloat pointsPerPercent = (self.travelBottom - self.travelTop) / (2 * _maxPitch);
    int tickStep = pointsPerPercent >= 4 ? 1 : 2;
    int labelStep = 2;
    while (labelStep * pointsPerPercent < 13 && labelStep < (int)_maxPitch) {
        labelStep *= 2; // 2 -> 4 -> 8; falls back to just ±max below
    }
    if (labelStep * pointsPerPercent < 13) {
        labelStep = (int)_maxPitch;
    }

    CGFloat tickInnerX = kSlotWidth / 2 + kTickGap;
    for (int value = (int)-_maxPitch; value <= (int)_maxPitch; value += tickStep) {
        BOOL major = (value % 2 == 0);
        CGFloat y = [self yForPitch:(float)value] + 0.5;
        CGFloat length = major ? kTickLength : kTickLength - 3;
        // 0 gets the full-width Technics center bar.
        if (value == 0) {
            length = kTickLength + 3;
        }
        NSBezierPath *tick = [NSBezierPath bezierPath];
        tick.lineWidth = (value == 0) ? 1.5 : 1;
        // Both sides of the slot, like the printed scale on the deck.
        [tick moveToPoint:NSMakePoint(centerX - tickInnerX - length, y)];
        [tick lineToPoint:NSMakePoint(centerX - tickInnerX, y)];
        [tick moveToPoint:NSMakePoint(centerX + tickInnerX, y)];
        [tick lineToPoint:NSMakePoint(centerX + tickInnerX + length, y)];
        [(major ? tickColor : minorTickColor) setStroke];
        [tick stroke];

        if (value % labelStep == 0 && value != 0) {
            NSString *label = [NSString stringWithFormat:@"%d", abs(value)];
            NSSize size = [label sizeWithAttributes:labelAttributes];
            CGFloat x = centerX - tickInnerX - kTickLength - kLabelGap - size.width;
            [label drawAtPoint:NSMakePoint(x, y - size.height / 2) withAttributes:labelAttributes];
        }
    }

    // Minus above, plus below the scale on the right side (Technics layout:
    // slide down/toward you to speed up).
    NSSize minusSize = [@"−" sizeWithAttributes:signAttributes];
    [@"−" drawAtPoint:NSMakePoint(centerX + tickInnerX + kTickLength + kLabelGap,
                                  [self yForPitch:-_maxPitch] - minusSize.height / 2)
       withAttributes:signAttributes];
    NSSize plusSize = [@"+" sizeWithAttributes:signAttributes];
    [@"+" drawAtPoint:NSMakePoint(centerX + tickInnerX + kTickLength + kLabelGap,
                                  [self yForPitch:_maxPitch] - plusSize.height / 2)
       withAttributes:signAttributes];
}

- (void)drawSlotAtCenterX:(CGFloat)centerX {
    NSRect slotRect = NSMakeRect(centerX - kSlotWidth / 2, self.travelTop - 3,
                                 kSlotWidth, self.travelBottom - self.travelTop + 6);
    NSBezierPath *slot = [NSBezierPath bezierPathWithRoundedRect:slotRect xRadius:2 yRadius:2];
    [[NSColor colorWithWhite:0.02 alpha:1] setFill];
    [slot fill];
    // Bottom-edge highlight sells the recessed slot.
    [[NSColor colorWithWhite:0.30 alpha:1] setStroke];
    slot.lineWidth = 0.5;
    [slot stroke];
}

- (void)drawZeroLEDAtCenterX:(CGFloat)centerX {
    // Quartz-lock style LED left of the center bar: lit green at exactly 0.
    BOOL locked = (_pitch == 0);
    CGFloat ledRadius = 2.5;
    CGFloat x = centerX - kSlotWidth / 2 - kTickGap - kTickLength - kLabelGap - 14;
    NSRect ledRect = NSMakeRect(x - ledRadius, [self yForPitch:0] - ledRadius,
                                ledRadius * 2, ledRadius * 2);
    NSBezierPath *led = [NSBezierPath bezierPathWithOvalInRect:ledRect];
    if (locked) {
        [[NSColor colorWithRed:0.22 green:0.95 blue:0.40 alpha:1] setFill];
        [led fill];
        // Soft glow.
        [[NSColor colorWithRed:0.22 green:0.95 blue:0.40 alpha:0.30] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(ledRect, -2.5, -2.5)] fill];
    }
    else {
        [[NSColor colorWithRed:0.10 green:0.25 blue:0.12 alpha:1] setFill];
        [led fill];
    }
}

- (void)drawKnobInRect:(NSRect)knobRect {
    // Drop shadow under the cap.
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.6];
    shadow.shadowOffset = NSMakeSize(0, -2);
    shadow.shadowBlurRadius = 4;

    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:knobRect xRadius:2.5 yRadius:2.5];
    [[NSColor colorWithWhite:0.16 alpha:1] setFill];
    [cap fill];
    [NSGraphicsContext restoreGraphicsState];

    // Machined-top gradient: darker at the vertical extremes, lighter middle.
    NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:
            [NSColor colorWithWhite:0.10 alpha:1], 0.0,
            [NSColor colorWithWhite:0.30 alpha:1], 0.42,
            [NSColor colorWithWhite:0.30 alpha:1], 0.58,
            [NSColor colorWithWhite:0.08 alpha:1], 1.0,
            nil];
    [gradient drawInBezierPath:cap angle:self.isFlipped ? 90 : -90];

    [[NSColor colorWithWhite:0 alpha:0.9] setStroke];
    cap.lineWidth = 1;
    [cap stroke];

    // The classic white index line across the middle of the cap.
    NSRect lineRect = NSMakeRect(knobRect.origin.x + 2, NSMidY(knobRect) - 1,
                                 knobRect.size.width - 4, 2);
    [[NSColor colorWithWhite:0.95 alpha:1] setFill];
    NSRectFill(lineRect);
}

#pragma mark - Mouse

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.clickCount == 2) {
        [self userSetPitch:0];
        [self.delegate pitchFaderViewDidEndAdjusting:self];
        return;
    }
    _dragging = YES;
    if (NSPointInRect(point, NSInsetRect(self.knobRect, -6, -4))) {
        _dragOffsetY = point.y - [self yForPitch:_pitch];
    }
    else {
        // Clicked the scale: jump the knob there and keep dragging.
        _dragOffsetY = 0;
        [self userSetPitch:[self pitchForY:point.y]];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) {
        return;
    }
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self userSetPitch:[self pitchForY:point.y - _dragOffsetY]];
}

- (void)mouseUp:(NSEvent *)event {
    if (_dragging) {
        _dragging = NO;
        [self.delegate pitchFaderViewDidEndAdjusting:self];
    }
}

- (void)userSetPitch:(float)pitch {
    if (fabsf(pitch) < kDetentPercent) {
        pitch = 0; // center detent
    }
    pitch = roundf(pitch * 10) / 10; // 0.1% steps
    // Clamp before the dedupe: past the travel ends pitchForY: keeps growing,
    // and comparing the unclamped value would fire the delegate with the same
    // clamped pitch on every mouse move.
    pitch = MAX(-_maxPitch, MIN(_maxPitch, pitch));
    if (pitch == _pitch) {
        return;
    }
    self.pitch = pitch;
    [self.delegate pitchFaderView:self didChangePitch:self.pitch];
}

@end
