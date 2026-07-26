//
//  SymbolButton.m
//  Vibe
//

#import "SymbolButton.h"

static const CFTimeInterval kFadeDuration = 0.1;

// Only a fallback — every call site sets its own size.
static const CGFloat kDefaultSymbolPointSize = 15;

@implementation SymbolButton {
    CALayer *_colorLayer;  // flat wash of the current state color
    CALayer *_maskLayer;   // the symbol, as the alpha mask carving that wash
    // What _maskLayer's image was built for; skips redundant rasterizations on
    // every layout pass.
    NSString *_renderedSymbolName;
    CGFloat _renderedPointSize;
    NSFontWeight _renderedWeight;
    CGFloat _renderedScale;
    BOOL _hovering;    // the cursor is inside the button
    BOOL _mouseDown;   // a press that began inside us is in progress
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _symbolPointSize = kDefaultSymbolPointSize;
        _symbolWeight = NSFontWeightRegular;
        // CALayer can't tint its contents, so the symbol becomes a mask and the
        // state color rides on the layer beneath it — the color then stays an
        // animatable layer property, as it was with the old shape-layer fill.
        _colorLayer = [CALayer layer];
        _maskLayer = [CALayer layer];
        _colorLayer.mask = _maskLayer;
        [self.layer addSublayer:_colorLayer];
        // Idle sits dim; hover fades to the highlight color at full opacity
        // (no transparency) and a press dims to half that opacity.
        _symbolNormalColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.55];
        _symbolHighlightColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.8];
        _symbolDisabledColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.19];
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

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.needsLayout = YES; // the backing scale is only known once we have a window
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _colorLayer.frame = self.bounds;
    [self updateMaskLayer];
    [CATransaction commit];
}

// Rasterizes the configured symbol at the window's backing scale — a mask layer
// samples only alpha, so the symbol's own black content needs no tinting — and
// centers the result in the bounds.
- (void)updateMaskLayer {
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) {
        scale = 2;
    }
    if (_maskLayer.contents &&
        [_renderedSymbolName isEqualToString:_symbolName] &&
        _renderedPointSize == _symbolPointSize &&
        _renderedWeight == _symbolWeight &&
        _renderedScale == scale) {
        [self centerMaskLayer];
        return;
    }

    NSImage *image = _symbolName.length ? [NSImage imageWithSystemSymbolName:_symbolName
                                                   accessibilityDescription:nil]
                                        : nil;
    image = [image imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:_symbolPointSize
                                                           weight:_symbolWeight]];
    NSSize size = image ? image.size : NSZeroSize;
    if (size.width <= 0 || size.height <= 0) {
        _maskLayer.contents = nil;
        _renderedSymbolName = nil;
        return;
    }

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:(NSInteger)ceil(size.width * scale)
                          pixelsHigh:(NSInteger)ceil(size.height * scale)
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];
    rep.size = size; // point size of the rep — makes the draw below fill the pixel grid
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [image drawInRect:NSMakeRect(0, 0, size.width, size.height)];
    [NSGraphicsContext restoreGraphicsState];

    _maskLayer.contentsScale = scale;
    _maskLayer.contents = (__bridge id)rep.CGImage; // CALayer retains it
    _renderedSymbolName = [_symbolName copy];
    _renderedPointSize = _symbolPointSize;
    _renderedWeight = _symbolWeight;
    _renderedScale = scale;
    [self centerMaskLayer];
}

// Integral origin: a half-point offset would soften the symbol's edges.
- (void)centerMaskLayer {
    CGImageRef image = (__bridge CGImageRef)_maskLayer.contents;
    if (!image) {
        return;
    }
    CGSize size = CGSizeMake(CGImageGetWidth(image) / _renderedScale,
                             CGImageGetHeight(image) / _renderedScale);
    _maskLayer.frame = CGRectMake(round((self.bounds.size.width - size.width) / 2),
                                  round((self.bounds.size.height - size.height) / 2),
                                  size.width, size.height);
}

#pragma mark - State color

- (void)applyColorAnimated:(BOOL)animated {
    NSColor *color;
    if (!self.isEnabled) {
        color = _symbolDisabledColor;
    } else if (_mouseDown && _hovering) {
        // Pressed: half the highlight's opacity.
        color = [_symbolHighlightColor colorWithAlphaComponent:_symbolHighlightColor.alphaComponent * 0.5];
    } else if (_hovering) {
        // Hover: full highlight color.
        color = _symbolHighlightColor;
    } else {
        color = _symbolNormalColor;
    }
    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:kFadeDuration];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _colorLayer.backgroundColor = color.CGColor;
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

- (void)setSymbolName:(NSString *)symbolName {
    if ([_symbolName isEqualToString:symbolName]) {
        return;
    }
    _symbolName = [symbolName copy];
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // instant swap, no fade
    [self updateMaskLayer];
    [CATransaction commit];
}

- (void)setSymbolPointSize:(CGFloat)symbolPointSize {
    _symbolPointSize = symbolPointSize;
    self.needsLayout = YES;
}

- (void)setSymbolWeight:(NSFontWeight)symbolWeight {
    _symbolWeight = symbolWeight;
    self.needsLayout = YES;
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self applyColorAnimated:YES];
}

- (void)setSymbolNormalColor:(NSColor *)color {
    _symbolNormalColor = color;
    [self applyColorAnimated:NO];
}

- (void)setSymbolHighlightColor:(NSColor *)color {
    _symbolHighlightColor = color;
    [self applyColorAnimated:NO];
}

- (void)setSymbolDisabledColor:(NSColor *)color {
    _symbolDisabledColor = color;
    [self applyColorAnimated:NO];
}

#pragma mark - Accessibility

- (NSString *)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (BOOL)accessibilityPerformPress {
    if (!self.isEnabled) {
        return NO;
    }
    [NSApp sendAction:self.action to:self.target from:self];
    return YES;
}

@end
