//
//  DrawnControls.m
//  Vibe
//

#import "DrawnControls.h"
#import "Formatters.h"
#import "NSView+DarkMode.h"
#import "PlatformColor.h"

static const CGFloat kDisabledAlpha = 0.5;

static NSColor *AppearanceGray(CGFloat darkWhite, CGFloat darkAlpha, CGFloat lightWhite, CGFloat lightAlpha) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return appearance.isDark ? [NSColor colorWithWhite:darkWhite alpha:darkAlpha]
                                 : [NSColor colorWithWhite:lightWhite alpha:lightAlpha];
    }];
}

// Both controls answer it; declared here for ObserveKeyState.
@interface VibeSlider ()
- (void)windowKeyStateDidChange:(NSNotification *)notification;
@end

// Sends the view windowKeyStateDidChange: for its next window's key changes.
static void ObserveKeyState(NSView *view, NSWindow *newWindow) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        if (view.window) {
            [center removeObserver:view name:name object:view.window];
        }
        if (newWindow) {
            [center addObserver:view selector:@selector(windowKeyStateDidChange:) name:name object:newWindow];
        }
    }
}

// Resolved under the drawing appearance, so it answers for a dynamic color too.
static BOOL IsDarkColor(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return rgb && 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5;
}

// A disabled control draws at kDisabledAlpha as one layer, so its parts do not
// show through each other.
static void DrawDimmedWhenDisabled(NSControl *control, void (^draw)(void)) {
    if (control.isEnabled) {
        draw();
        return;
    }
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSetAlpha(context, kDisabledAlpha);
    CGContextBeginTransparencyLayer(context, NULL);
    draw();
    CGContextEndTransparencyLayer(context);
}

#pragma mark - VibeSlider

// NSSlider's small size on macOS 26, measured: the knob's ends meet the
// track's at either end of the travel.
static const CGFloat kSliderTrackHeight = 4;
static const CGFloat kSliderKnobWidth = 18;
static const CGFloat kSliderKnobHeight = 14;
static const double kSliderAccessibilityStep = 0.05;

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

// Set on every resolution of the waveform's theme, mostly unchanged.
- (void)setTrackFillColor:(NSColor *)color {
    if (![color isEqual:_trackFillColor]) {
        _trackFillColor = [color copy];
        self.needsDisplay = YES;
    }
}

- (void)setKnobColor:(NSColor *)color {
    if (![color isEqual:_knobColor]) {
        _knobColor = [color copy];
        self.needsDisplay = YES;
    }
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
    ObserveKeyState(self, newWindow);
    [super viewWillMoveToWindow:newWindow];
}

- (void)windowKeyStateDidChange:(NSNotification *)notification {
    self.needsDisplay = YES;
}

#pragma mark Geometry

// The knob's center travels between these, so it stays inside the bounds.
- (CGFloat)travelMinX {
    return kSliderKnobWidth / 2;
}

- (CGFloat)travelWidth {
    return MAX(0, NSWidth(self.bounds) - kSliderKnobWidth);
}

- (CGFloat)knobCenterX {
    return self.travelMinX + _value * self.travelWidth;
}

- (double)valueForKnobCenterX:(CGFloat)x {
    CGFloat travel = self.travelWidth;
    return travel > 0 ? (x - self.travelMinX) / travel : 0;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    // NSSlider's, measured: the unfilled track, the fill of a window that is
    // not key, and the knob.
    static NSColor *trackColor, *inactiveFillColor, *systemKnobColor, *knobEdgeColor, *darkKnobEdgeColor;
    static NSShadow *knobShadow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trackColor = AppearanceGray(1, 0.1, 0, 0.1);
        inactiveFillColor = AppearanceGray(1, 0.23, 0, 0.23);
        systemKnobColor = AppearanceGray(0.87, 1, 1, 1);
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
    DrawDimmedWhenDisabled(self, ^{
        // The two halves meet under the knob, so a translucent fill does not
        // stack on the track.
        NSRect filled = NSMakeRect(0, round(midY - kSliderTrackHeight / 2), knobX, kSliderTrackHeight);
        NSRect unfilled = filled;
        unfilled.origin.x = knobX;
        unfilled.size.width = NSWidth(bounds) - knobX;
        CGFloat radius = kSliderTrackHeight / 2;
        [trackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:unfilled xRadius:radius yRadius:radius] fill];
        NSColor *fill = self.window.isKeyWindow ? (self->_trackFillColor ?: NSColor.controlAccentColor)
                                                : inactiveFillColor;
        [fill setFill];
        [[NSBezierPath bezierPathWithRoundedRect:filled xRadius:radius yRadius:radius] fill];

        NSRect knob = NSMakeRect(knobX - kSliderKnobWidth / 2, midY - kSliderKnobHeight / 2,
                                 kSliderKnobWidth, kSliderKnobHeight);
        NSBezierPath *knobPath = [NSBezierPath bezierPathWithRoundedRect:knob
                                                                 xRadius:kSliderKnobHeight / 2
                                                                 yRadius:kSliderKnobHeight / 2];
        [NSGraphicsContext saveGraphicsState];
        [knobShadow set];
        NSColor *knobFill = self->_knobColor ?: systemKnobColor;
        [knobFill setFill];
        [knobPath fill];
        [NSGraphicsContext restoreGraphicsState];
        NSRect edge = NSInsetRect(knob, 0.25, 0.25);
        NSBezierPath *edgePath = [NSBezierPath bezierPathWithRoundedRect:edge
                                                                 xRadius:NSHeight(edge) / 2
                                                                 yRadius:NSHeight(edge) / 2];
        edgePath.lineWidth = 0.5;
        [(IsDarkColor(knobFill) ? darkKnobEdgeColor : knobEdgeColor) setStroke];
        [edgePath stroke];
    });
}

#pragma mark Mouse

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEnabled) {
        return;
    }
    _tracking = YES;
    CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
    CGFloat knobX = self.knobCenterX;
    _grabOffset = fabs(x - knobX) <= kSliderKnobWidth / 2 ? x - knobX : 0;
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

#pragma mark Accessibility

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
    return [self stepForAccessibility:kSliderAccessibilityStep];
}

- (BOOL)accessibilityPerformDecrement {
    return [self stepForAccessibility:-kSliderAccessibilityStep];
}

// Rounded to the step, so stepping from a dragged value lands on 5% marks.
- (BOOL)stepForAccessibility:(double)delta {
    if (!self.isEnabled) {
        return NO;
    }
    double before = _value;
    self.doubleValue = round((_value + delta) / kSliderAccessibilityStep) * kSliderAccessibilityStep;
    if (_value == before) {
        return NO;
    }
    [NSApp sendAction:self.action to:self.target from:self];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
    return YES;
}

@end

#pragma mark - VibeSwitch

// NSSwitch's small size on macOS 27, measured: a 44x20 pill track, a 26x16
// capsule knob inset 2 points.
static const CGFloat kSwitchWidth = 44;
static const CGFloat kSwitchHeight = 20;
static const CGFloat kSwitchKnobWidth = 26;
static const CGFloat kSwitchKnobInset = 2;
static const NSTimeInterval kSwitchSlideDuration = 0.2;
static NSString *const kSwitchKnobPositionKey = @"knobPosition";

@interface VibeSwitch ()
// 0 off, 1 on; animated between by a toggle.
@property (nonatomic) CGFloat knobPosition;
@end

@implementation VibeSwitch {
    BOOL _tracking; // a press that began enabled
}

+ (id)defaultAnimationForKey:(NSAnimatablePropertyKey)key {
    return [key isEqualToString:kSwitchKnobPositionKey] ? [CABasicAnimation animation]
                                                        : [super defaultAnimationForKey:key];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(kSwitchWidth, kSwitchHeight);
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return self.isEnabled && NSApp.isFullKeyboardAccessEnabled;
}

- (void)setState:(NSControlStateValue)state {
    state = state == NSControlStateValueOff ? NSControlStateValueOff : NSControlStateValueOn;
    if (state != _state) {
        _state = state;
        self.knobPosition = state == NSControlStateValueOn;
    }
}

- (void)setKnobPosition:(CGFloat)position {
    _knobPosition = position;
    self.needsDisplay = YES;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    ObserveKeyState(self, newWindow);
    [super viewWillMoveToWindow:newWindow];
}

// Key state colors only the on side.
- (void)windowKeyStateDidChange:(NSNotification *)notification {
    if (_knobPosition > 0) {
        self.needsDisplay = YES;
    }
}

- (void)toggle {
    _state = _state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion
                ? 0 : kSwitchSlideDuration;
        self.animator.knobPosition = self->_state == NSControlStateValueOn;
    }];
    [NSApp sendAction:self.action to:self.target from:self];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}

- (void)performClick:(id)sender {
    if (self.isEnabled) [self toggle];
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirtyRect {
    // NSSwitch's, measured: the off track, the on track of a window that is
    // not key, and the knob.
    static NSColor *offTrackColor, *inactiveOnTrackColor, *knobColor;
    static NSShadow *knobShadow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        offTrackColor = AppearanceGray(1, 0.09, 0, 0.1);
        inactiveOnTrackColor = AppearanceGray(1, 0.14, 0, 0.14);
        knobColor = AppearanceGray(1, 0.86, 1, 1);
        knobShadow = [[NSShadow alloc] init];
        knobShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.16];
        knobShadow.shadowOffset = NSMakeSize(0, -0.5);
        knobShadow.shadowBlurRadius = 2;
    });

    NSRect track = NSMakeRect(0, round(NSMidY(self.bounds) - kSwitchHeight / 2), NSWidth(self.bounds), kSwitchHeight);
    CGFloat position = _knobPosition;
    DrawDimmedWhenDisabled(self, ^{
        NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track
                                                                  xRadius:kSwitchHeight / 2 yRadius:kSwitchHeight / 2];
        [offTrackColor setFill];
        [trackPath fill];
        if (position > 0) {
            NSColor *onColor = self.window.isKeyWindow ? NSColor.controlAccentColor : inactiveOnTrackColor;
            [VibeColorWithScaledAlpha(onColor, position) setFill];
            [trackPath fill];
        }

        CGFloat travel = NSWidth(track) - 2 * kSwitchKnobInset - kSwitchKnobWidth;
        NSRect knob = NSMakeRect(NSMinX(track) + kSwitchKnobInset + position * travel,
                                 NSMinY(track) + kSwitchKnobInset,
                                 kSwitchKnobWidth, kSwitchHeight - 2 * kSwitchKnobInset);
        [NSGraphicsContext saveGraphicsState];
        [knobShadow set];
        [knobColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:NSHeight(knob) / 2 yRadius:NSHeight(knob) / 2] fill];
        [NSGraphicsContext restoreGraphicsState];
    });
}

- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds
                                     xRadius:kSwitchHeight / 2 yRadius:kSwitchHeight / 2] fill];
}

- (NSRect)focusRingMaskBounds {
    return self.bounds;
}

#pragma mark Events

- (void)mouseDown:(NSEvent *)event {
    _tracking = self.isEnabled;
}

- (void)mouseUp:(NSEvent *)event {
    if (!_tracking) {
        return;
    }
    _tracking = NO;
    if (NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], self.bounds)) {
        [self toggle];
    }
}

- (void)keyDown:(NSEvent *)event {
    if (self.isEnabled && [event.charactersIgnoringModifiers isEqualToString:@" "]) {
        [self toggle];
    } else {
        [super keyDown:event];
    }
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityCheckBoxRole;
}

- (NSAccessibilitySubrole)accessibilitySubrole {
    return NSAccessibilitySwitchSubrole;
}

- (BOOL)isAccessibilityEnabled {
    return self.isEnabled;
}

- (id)accessibilityValue {
    return @(_state == NSControlStateValueOn);
}

- (BOOL)accessibilityPerformPress {
    if (!self.isEnabled) {
        return NO;
    }
    [self toggle];
    return YES;
}

@end
