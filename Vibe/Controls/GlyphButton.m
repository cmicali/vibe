//
//  GlyphButton.m
//  Vibe
//

#import "GlyphButton.h"

static const CFTimeInterval kFadeDuration = 0.1;

// Glyph proportions, as fractions of the glyph box side (a ~26pt box inside
// the 50pt transport buttons). Corner rounding is ~1pt — softened corners,
// not pills.
static const CGFloat kCornerRadius   = 0.04;
static const CGFloat kPlayWidth      = 0.90;  // triangle, full box height
static const CGFloat kPauseBarWidth  = 0.22;  // two bars, full box height
static const CGFloat kPauseTotalWidth = 0.78; // bars + gap, centered
static const CGFloat kSkipBarWidth   = 0.10;  // triangle + right bar
static const CGFloat kSkipTriWidth   = 0.85;
static const CGFloat kListWidth      = 0.78;  // four lines; matches the pause pair's width so the icons read equal-sized
static const CGFloat kListLineHeight = 0.10;

// Rounds each corner with an arc; the path stays a plain polygon otherwise.
static void addRoundedTriangle(CGMutablePathRef path, CGPoint a, CGPoint b, CGPoint c, CGFloat radius) {
    const CGPoint pts[3] = {a, b, c};
    CGPathMoveToPoint(path, NULL, (c.x + a.x) / 2, (c.y + a.y) / 2);
    for (int i = 0; i < 3; i++) {
        CGPoint corner = pts[i];
        CGPoint next = pts[(i + 1) % 3];
        CGPathAddArcToPoint(path, NULL, corner.x, corner.y, (corner.x + next.x) / 2, (corner.y + next.y) / 2, radius);
    }
    CGPathCloseSubpath(path);
}

@implementation GlyphButton {
    CAShapeLayer *_glyphLayer;
    BOOL _hovering;    // the cursor is inside the button
    BOOL _mouseDown;   // a press that began inside us is in progress
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _glyphLayer = [CAShapeLayer layer];
        [self.layer addSublayer:_glyphLayer];
        // Idle sits dim; hover fades to the highlight color at full opacity
        // (no transparency) and a press dims to half that opacity.
        _glyphNormalColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.55];
        _glyphHighlightColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.8];
        _glyphDisabledColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.19];
        // EnabledDuringMouseDrag: exited/entered don't fire during a drag
        // without it, and drag-off/drag-back is exactly a mid-drag exit.
        [self addTrackingArea:[[NSTrackingArea alloc]
                initWithRect:self.bounds
                     options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                             NSTrackingMouseEnteredAndExited | NSTrackingEnabledDuringMouseDrag
                       owner:self userInfo:nil]];
        [self applyColorAnimated:NO];
    }
    return self;
}

// The window is movable-by-background; without this a click on the button
// would also start a window drag (NSControl is non-opaque, unlike NSButton).
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

#pragma mark - Layer geometry

// CAShapeLayer rasterizes its path at contentsScale; keep it at the window's
// backing scale or the glyph renders blurry on retina.
- (void)updateContentsScale {
    CGFloat scale = self.window.backingScaleFactor;
    if (scale > 0) {
        _glyphLayer.contentsScale = scale;
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateContentsScale];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateContentsScale];
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glyphLayer.frame = self.bounds;
    _glyphLayer.path = [self glyphPath];
    [CATransaction commit];
}

- (CGPathRef)glyphPath {
    CGFloat side = _glyphSize > 0 ? _glyphSize : MIN(self.bounds.size.width, self.bounds.size.height);
    CGRect box = CGRectMake((self.bounds.size.width - side) / 2,
                            (self.bounds.size.height - side) / 2, side, side);
    CGFloat radius = kCornerRadius * side;
    CGMutablePathRef path = CGPathCreateMutable();
    switch (_glyph) {
        case GlyphButtonGlyphPlay: {
            CGFloat x = CGRectGetMinX(box) + (1 - kPlayWidth) / 2 * side;
            addRoundedTriangle(path,
                    CGPointMake(x, CGRectGetMaxY(box)),
                    CGPointMake(x, CGRectGetMinY(box)),
                    CGPointMake(x + kPlayWidth * side, CGRectGetMidY(box)),
                    radius);
            break;
        }
        case GlyphButtonGlyphPause: {
            CGFloat barWidth = kPauseBarWidth * side;
            CGFloat inset = (1 - kPauseTotalWidth) / 2 * side; // centers the pair
            CGPathAddRoundedRect(path, NULL,
                    CGRectMake(CGRectGetMinX(box) + inset, CGRectGetMinY(box), barWidth, side),
                    radius, radius);
            CGPathAddRoundedRect(path, NULL,
                    CGRectMake(CGRectGetMaxX(box) - inset - barWidth, CGRectGetMinY(box), barWidth, side),
                    radius, radius);
            break;
        }
        case GlyphButtonGlyphSkipNext: {
            addRoundedTriangle(path,
                    CGPointMake(CGRectGetMinX(box), CGRectGetMaxY(box)),
                    CGPointMake(CGRectGetMinX(box), CGRectGetMinY(box)),
                    CGPointMake(CGRectGetMinX(box) + kSkipTriWidth * side, CGRectGetMidY(box)),
                    radius);
            CGPathAddRoundedRect(path, NULL,
                    CGRectMake(CGRectGetMaxX(box) - kSkipBarWidth * side, CGRectGetMinY(box),
                               kSkipBarWidth * side, side),
                    radius, radius);
            break;
        }
        case GlyphButtonGlyphPlaylist: {
            CGFloat width = kListWidth * side;
            CGFloat lineHeight = kListLineHeight * side;
            CGFloat x = CGRectGetMidX(box) - width / 2;
            CGFloat bottom = CGRectGetMidY(box) - width / 2; // lines fill a centered square
            CGFloat step = (width - lineHeight) / 3;
            for (int i = 0; i < 4; i++) {
                CGPathAddRoundedRect(path, NULL,
                        CGRectMake(x, bottom + i * step, width, lineHeight),
                        lineHeight / 2, lineHeight / 2);
            }
            break;
        }
        case GlyphButtonGlyphClose:
        case GlyphButtonGlyphMinimize: {
            CGPathAddEllipseInRect(path, NULL, box);
            break;
        }
    }
    return (CGPathRef)CFAutorelease(path);
}

#pragma mark - State color

- (void)applyColorAnimated:(BOOL)animated {
    NSColor *color;
    if (!self.isEnabled) {
        color = _glyphDisabledColor;
    } else if (_mouseDown && _hovering) {
        // Pressed: half the highlight's opacity.
        color = [_glyphHighlightColor colorWithAlphaComponent:_glyphHighlightColor.alphaComponent * 0.5];
    } else if (_hovering) {
        // Hover: full highlight color.
        color = _glyphHighlightColor;
    } else {
        color = _glyphNormalColor;
    }
    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:kFadeDuration];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _glyphLayer.fillColor = color.CGColor;
    [CATransaction commit];
}

#pragma mark - Mouse handling (momentary push)

// Disabled buttons are click-through, so a click over them still drags the
// window.
- (NSView *)hitTest:(NSPoint)point {
    return self.isEnabled ? [super hitTest:point] : nil;
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEnabled) {
        return;
    }
    _mouseDown = YES;
    _hovering = YES; // pressing implies the cursor is inside
    [self applyColorAnimated:YES];
}

- (void)mouseEntered:(NSEvent *)event {
    _hovering = YES;
    [self applyColorAnimated:YES];
}

- (void)mouseExited:(NSEvent *)event {
    _hovering = NO;
    [self applyColorAnimated:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_mouseDown) {
        return;
    }
    _mouseDown = NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _hovering = NSPointInRect(point, self.bounds); // released inside → stay in hover state
    [self applyColorAnimated:YES];
    // Re-check isEnabled: the button can be disabled mid-press (mouseDown:
    // only gates the press starting).
    if (_hovering && self.isEnabled) {
        [NSApp sendAction:self.action to:self.target from:self];
    }
}

#pragma mark - Properties

- (void)setGlyph:(GlyphButtonGlyph)glyph {
    if (_glyph == glyph) {
        return;
    }
    _glyph = glyph;
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // instant swap, no fade
    _glyphLayer.path = [self glyphPath];
    [CATransaction commit];
}

- (void)setGlyphSize:(CGFloat)glyphSize {
    _glyphSize = glyphSize;
    self.needsLayout = YES;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyColorAnimated:YES];
}

- (void)setGlyphNormalColor:(NSColor *)color {
    _glyphNormalColor = color;
    [self applyColorAnimated:NO];
}

- (void)setGlyphHighlightColor:(NSColor *)color {
    _glyphHighlightColor = color;
    [self applyColorAnimated:NO];
}

- (void)setGlyphDisabledColor:(NSColor *)color {
    _glyphDisabledColor = color;
    [self applyColorAnimated:NO];
}

#pragma mark - Accessibility

- (NSString *)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
    switch (_glyph) {
        case GlyphButtonGlyphPlay:     return @"Play";
        case GlyphButtonGlyphPause:    return @"Pause";
        case GlyphButtonGlyphSkipNext: return @"Next Track";
        case GlyphButtonGlyphPlaylist: return @"Toggle Playlist";
        case GlyphButtonGlyphClose:    return @"Close";
        case GlyphButtonGlyphMinimize: return @"Minimize";
    }
    return @"";
}

- (BOOL)accessibilityPerformPress {
    if (!self.isEnabled) {
        return NO;
    }
    [NSApp sendAction:self.action to:self.target from:self];
    return YES;
}

@end
