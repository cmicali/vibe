//
//  SymbolButton.m
//  Vibe
//

#import "SymbolButton.h"

static const CFTimeInterval kFadeDuration = 0.1;

// A fallback only: every call site sets its own size.
static const CGFloat kDefaultSymbolPointSize = 15;

// The factory state strengths: the resting alpha, and what hover, press and
// disabled do to it. setSymbolColorsFromRestingColor: scales a picked color's
// alpha by these ratios, and a custom image fades its opacity by the same
// ones, so every button state keeps one relationship whatever draws it.
static const CGFloat kRestingAlpha = 0.55;
static const CGFloat kHoverAlpha = 0.8;
static const CGFloat kDisabledAlpha = 0.19;
static const CGFloat kPressedFraction = 0.5;

// SF Symbol glyphs draw at roughly this fraction of their configured point
// size, so a custom image fits the same box a glyph fills.
static const CGFloat kGlyphFractionOfPointSize = 0.8;

@implementation SymbolButton {
    CALayer *_colorLayer;  // flat wash of the current state color
    CALayer *_maskLayer;   // the symbol, as the alpha mask carving that wash
    CALayer *_imageLayer;  // the custom image, when one replaces the symbol
    // What _maskLayer's image was built for. It skips redundant rasterizations
    // on every layout pass.
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
        // CALayer cannot tint its contents, so the symbol becomes a mask and
        // the state color rides on the layer beneath it. The color then stays
        // an animatable layer property.
        _colorLayer = [CALayer layer];
        _maskLayer = [CALayer layer];
        _colorLayer.mask = _maskLayer;
        [self.layer addSublayer:_colorLayer];
        // The custom image's layer sits beside the color layer, hidden until
        // an image is set; the state fades then ride its opacity instead.
        _imageLayer = [CALayer layer];
        _imageLayer.contentsGravity = kCAGravityResizeAspect;
        _imageLayer.hidden = YES;
        [self.layer addSublayer:_imageLayer];
        // Idle sits dim. Hover fades to the highlight color at full opacity,
        // with no transparency, and a press dims to half that opacity.
        _symbolNormalColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kRestingAlpha];
        _symbolHighlightColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kHoverAlpha];
        _symbolDisabledColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kDisabledAlpha];
        // EnabledDuringMouseDrag is needed because exited and entered do not
        // fire during a drag without it, and dragging off and back is exactly
        // a mid-drag exit.
        [self addTrackingArea:[[NSTrackingArea alloc]
                initWithRect:self.bounds
                     options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                             NSTrackingMouseEnteredAndExited | NSTrackingEnabledDuringMouseDrag
                       owner:self userInfo:nil]];
        [self applyColorAnimated:NO];
    }
    return self;
}

// The window is movable by its background, and without this a click on the
// button would also start a window drag, since NSControl is non-opaque, unlike
// NSButton.
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

// A click on an inactive window should work the transport, not merely activate
// it: a player is reached for while another app is frontmost. Same rule as the
// playlist drop zone's.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
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
    [self updateImageLayer];
    [CATransaction commit];
}

// The custom image as the layer's own contents — AppKit draws an NSImage set
// there at the layer's contentsScale from its best rep — aspect-fit by the
// layer's gravity into the box a glyph of the configured point size fills,
// and centered.
- (void)updateImageLayer {
    _imageLayer.hidden = (_image == nil);
    _imageLayer.contents = _image;
    if (!_image) {
        return;
    }
    CGFloat scale = self.window.backingScaleFactor;
    _imageLayer.contentsScale = scale > 0 ? scale : 2;
    CGFloat box = round(_symbolPointSize * kGlyphFractionOfPointSize);
    [self centerLayer:_imageLayer size:NSMakeSize(box, box)];
}

// Rasterizes the configured symbol at the window's backing scale and centers
// the result in the bounds. A mask layer samples only alpha, so the symbol's
// own black content needs no tinting.
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

// An integral origin, because a half-point offset would soften the symbol's
// edges.
- (void)centerMaskLayer {
    CGImageRef image = (__bridge CGImageRef)_maskLayer.contents;
    if (!image) {
        return;
    }
    [self centerLayer:_maskLayer size:NSMakeSize(CGImageGetWidth(image) / _renderedScale,
                                                 CGImageGetHeight(image) / _renderedScale)];
}

- (void)centerLayer:(CALayer *)layer size:(NSSize)size {
    layer.frame = CGRectMake(round((self.bounds.size.width - size.width) / 2),
                             round((self.bounds.size.height - size.height) / 2),
                             size.width, size.height);
}

#pragma mark - State color

- (void)applyColorAnimated:(BOOL)animated {
    NSColor *color;
    // The image's opacity by state, the factory ratios over full strength at
    // hover: a custom picture reads as itself when hovered and rests a step
    // dimmer, as the glyphs do.
    float opacity;
    if (!self.isEnabled) {
        color = _symbolDisabledColor;
        opacity = kDisabledAlpha / kHoverAlpha;
    } else if (_mouseDown && _hovering) {
        color = [_symbolHighlightColor colorWithAlphaComponent:
                _symbolHighlightColor.alphaComponent * kPressedFraction];
        opacity = kPressedFraction;
    } else if (_hovering) {
        color = _symbolHighlightColor;
        opacity = 1;
    } else {
        color = _symbolNormalColor;
        opacity = kRestingAlpha / kHoverAlpha;
    }
    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:kFadeDuration];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _colorLayer.backgroundColor = color.CGColor;
    _imageLayer.opacity = opacity;
    [CATransaction commit];
}

- (void)setSymbolColorsFromRestingColor:(NSColor *)color {
    CGFloat alpha = color.alphaComponent;
    _symbolNormalColor = color;
    _symbolHighlightColor = [color colorWithAlphaComponent:MIN(1, alpha * (kHoverAlpha / kRestingAlpha))];
    _symbolDisabledColor = [color colorWithAlphaComponent:alpha * (kDisabledAlpha / kRestingAlpha)];
    [self applyColorAnimated:NO];
}

#pragma mark - Mouse handling (momentary push)

// Disabled buttons are click-through, so a click over one still drags the
// window. So are invisible ones: the window's chrome sits at alpha 0 until
// hover fades it in, and an invisible close button that still takes a press
// quit the app on a click the user never saw a control under. The animator
// writes the model alpha up front, so a button mid-fade-in is already
// hittable.
- (NSView *)hitTest:(NSPoint)point {
    if (!self.isEnabled || self.alphaValue < 0.01) {
        return nil;
    }
    return [super hitTest:point];
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
    // Re-check isEnabled, because the button can be disabled mid-press:
    // mouseDown: only gates the press starting.
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

// The image hides the color layer rather than replacing its contents, so a
// return to the symbol is the mask it still holds.
- (void)setImage:(NSImage *)image {
    if (_image == image) {
        return;
    }
    _image = image;
    [CATransaction begin];
    [CATransaction setDisableActions:YES]; // instant swap, like the symbol's
    _colorLayer.hidden = (image != nil);
    [self updateImageLayer];
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
