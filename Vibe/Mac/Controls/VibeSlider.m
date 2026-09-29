//
//  VibeSlider.m
//  Vibe
//

#import "VibeSlider.h"
#import "Formatters.h"

// NSSlider's small size on macOS 26, measured: the knob's ends meet the
// track's at either end of the travel.
static const CGFloat kTrackHeight = 4;
static const CGFloat kKnobWidth = 18;
static const CGFloat kKnobHeight = 14;
static const CGFloat kDisabledAlpha = 0.5;
static const double kAccessibilityStep = 0.05;

static NSColor *AppearanceColor(CGFloat darkWhite, CGFloat darkAlpha, CGFloat lightWhite, CGFloat lightAlpha) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark = [[appearance bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithWhite:darkWhite alpha:darkAlpha]
                    : [NSColor colorWithWhite:lightWhite alpha:lightAlpha];
    }];
}

// Resolved under the drawing appearance, so it answers for a dynamic color too.
static BOOL IsDarkColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return rgb && 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5;
}

@implementation VibeSlider {
    double _value;
    BOOL _tracking; // a press that began enabled
    // So grabbing the knob by its edge does not make it jump.
    CGFloat _grabOffset;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO; // non-opaque: a drag would also drag the window
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (double)doubleValue {
    return _value;
}

- (void)setDoubleValue:(double)value {
    value = isfinite(value) ? MAX(0, MIN(1, value)) : 0;
    if (value != _value) {
        _value = value;
        self.needsDisplay = YES;
    }
}

- (void)setTrackFillColor:(NSColor *)color {
    _trackFillColor = [color copy];
    self.needsDisplay = YES;
}

- (void)setKnobColor:(NSColor *)color {
    _knobColor = [color copy];
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

// Dynamic colors resolve at draw time, so a flip only needs a redraw.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        if (self.window) {
            [center removeObserver:self name:name object:self.window];
        }
        if (newWindow) {
            [center addObserver:self selector:@selector(windowKeyStateDidChange:) name:name object:newWindow];
        }
    }
    [super viewWillMoveToWindow:newWindow];
}

- (void)windowKeyStateDidChange:(NSNotification *)notification {
    self.needsDisplay = YES;
}

#pragma mark - Geometry

// The knob's center travels between these, so it stays inside the bounds.
- (CGFloat)travelMinX {
    return kKnobWidth / 2;
}

- (CGFloat)travelWidth {
    return MAX(0, NSWidth(self.bounds) - kKnobWidth);
}

- (CGFloat)knobCenterX {
    return self.travelMinX + _value * self.travelWidth;
}

- (double)valueForKnobCenterX:(CGFloat)x {
    CGFloat travel = self.travelWidth;
    return travel > 0 ? (x - self.travelMinX) / travel : 0;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    // NSSlider's, measured: the unfilled track, the fill of a window that is
    // not key, and the knob.
    static NSColor *trackColor, *inactiveFillColor, *systemKnobColor, *knobEdgeColor, *darkKnobEdgeColor;
    static NSShadow *knobShadow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trackColor = AppearanceColor(1, 0.1, 0, 0.1);
        inactiveFillColor = AppearanceColor(1, 0.23, 0, 0.23);
        systemKnobColor = AppearanceColor(0.87, 1, 1, 1);
        // Keeps the knob apart from a fill of its own color, the default:
        // dark on a light knob, light on a dark one.
        knobEdgeColor = [NSColor colorWithWhite:0 alpha:0.15];
        darkKnobEdgeColor = [NSColor colorWithWhite:1 alpha:0.4];
        // Drawn past the bounds, which a view may do from macOS 14.
        knobShadow = [[NSShadow alloc] init];
        knobShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.16];
        knobShadow.shadowOffset = NSMakeSize(0, -1.5);
        knobShadow.shadowBlurRadius = 8;
    });

    NSRect bounds = self.bounds;
    CGFloat midY = NSMidY(bounds);
    CGFloat knobX = round(self.knobCenterX);
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    if (!self.isEnabled) {
        CGContextSetAlpha(context, kDisabledAlpha);
        CGContextBeginTransparencyLayer(context, NULL);
    }

    // The two halves meet under the knob, so a translucent fill does not
    // stack on the track.
    NSRect filled = NSMakeRect(0, round(midY - kTrackHeight / 2), knobX, kTrackHeight);
    NSRect unfilled = filled;
    unfilled.origin.x = knobX;
    unfilled.size.width = NSWidth(bounds) - knobX;
    CGFloat radius = kTrackHeight / 2;
    [trackColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:unfilled xRadius:radius yRadius:radius] fill];
    NSColor *fill = self.window.isKeyWindow ? (_trackFillColor ?: NSColor.controlAccentColor) : inactiveFillColor;
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:radius yRadius:radius] fill];

    NSRect knob = NSMakeRect(knobX - kKnobWidth / 2, midY - kKnobHeight / 2, kKnobWidth, kKnobHeight);
    NSBezierPath *knobPath = [NSBezierPath bezierPathWithRoundedRect:knob
                                                             xRadius:kKnobHeight / 2 yRadius:kKnobHeight / 2];
    [NSGraphicsContext saveGraphicsState];
    [knobShadow set];
    NSColor *knobFill = _knobColor ?: systemKnobColor;
    [knobFill setFill];
    [knobPath fill];
    [NSGraphicsContext restoreGraphicsState];
    NSRect edge = NSInsetRect(knob, 0.25, 0.25);
    NSBezierPath *edgePath = [NSBezierPath bezierPathWithRoundedRect:edge
                                                             xRadius:NSHeight(edge) / 2 yRadius:NSHeight(edge) / 2];
    edgePath.lineWidth = 0.5;
    [(IsDarkColor(knobFill) ? darkKnobEdgeColor : knobEdgeColor) setStroke];
    [edgePath stroke];

    if (!self.isEnabled) {
        CGContextEndTransparencyLayer(context);
    }
}

#pragma mark - Mouse

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEnabled) {
        return;
    }
    _tracking = YES;
    CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    CGFloat knobX = self.knobCenterX;
    _grabOffset = fabs(x - knobX) <= kKnobWidth / 2 ? x - knobX : 0;
    [self trackToEvent:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_tracking) {
        [self trackToEvent:event];
    }
}

// TRAP: the release sends the action even when the value did not move: the
// volume control's drag hold is cleared only by an action whose current event
// is the mouse-up (MainPlayerContentView.volumeSliderDidMove).
- (void)mouseUp:(NSEvent *)event {
    if (_tracking) {
        _tracking = NO;
        [self trackToEvent:event];
    }
}

- (void)trackToEvent:(NSEvent *)event {
    CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    double before = _value;
    self.doubleValue = [self valueForKnobCenterX:x - _grabOffset];
    if (_value != before || event.type != NSEventTypeLeftMouseDragged) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
    if (_value != before) {
        NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    }
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilitySliderRole;
}

- (BOOL)isAccessibilityEnabled {
    return self.isEnabled;
}

- (id)accessibilityValue {
    return @(_value);
}

- (id)accessibilityMinValue {
    return @0;
}

- (id)accessibilityMaxValue {
    return @1;
}

- (NSString *)accessibilityValueDescription {
    return [Formatters.sharedInstance percentString:_value];
}

- (BOOL)accessibilityPerformIncrement {
    return [self stepForAccessibility:kAccessibilityStep];
}

- (BOOL)accessibilityPerformDecrement {
    return [self stepForAccessibility:-kAccessibilityStep];
}

// Rounded to the step, so stepping from a dragged value lands on 5% marks.
- (BOOL)stepForAccessibility:(double)delta {
    if (!self.isEnabled) {
        return NO;
    }
    double before = _value;
    self.doubleValue = round((_value + delta) / kAccessibilityStep) * kAccessibilityStep;
    if (_value == before) {
        return NO;
    }
    [NSApp sendAction:self.action to:self.target from:self];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    return YES;
}

@end
