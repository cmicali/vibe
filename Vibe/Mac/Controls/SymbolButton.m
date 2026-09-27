//
//  SymbolButton.m
//  Vibe
//

#import "SymbolButton.h"
#import "PlatformColor.h"

static const CFTimeInterval kFadeDuration = 0.1;

// A fallback only: every call site sets its own size.
static const CGFloat kDefaultSymbolPointSize = 15;

// The factory state strengths. A picked color's alpha and a custom image's
// opacity both scale by these ratios, so every state keeps one relationship.
static const CGFloat kRestingAlpha = 0.55;
static const CGFloat kHoverAlpha = 0.8;
static const CGFloat kDisabledAlpha = 0.19;
static const CGFloat kPressedFraction = 0.5;

// So a custom image fits the box a glyph fills.
static const CGFloat kGlyphFractionOfPointSize = 0.8;

@implementation SymbolButton {
    CALayer *_colorLayer;  // flat wash of the current state color
    CALayer *_maskLayer;   // the symbol, as the alpha mask carving that wash
    CALayer *_imageLayer;  // the custom image, when one replaces the symbol
    // What _maskLayer was rasterized for, so layout skips redundant passes.
    NSString *_renderedSymbolName;
    CGFloat _renderedPointSize;
    NSFontWeight _renderedWeight;
    CGFloat _renderedScale;
    BOOL _hovering;
    BOOL _mouseDown;   // a press that began inside
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        _symbolPointSize = kDefaultSymbolPointSize;
        _symbolWeight = NSFontWeightRegular;
        // CALayer cannot tint its contents, so the symbol is a mask over an
        // animatable color layer.
        _colorLayer = [CALayer layer];
        _maskLayer = [CALayer layer];
        _colorLayer.mask = _maskLayer;
        [self.layer addSublayer:_colorLayer];
        _imageLayer = [CALayer layer];
        _imageLayer.contentsGravity = kCAGravityResizeAspect;
        _imageLayer.hidden = YES;
        [self.layer addSublayer:_imageLayer];
        _symbolNormalColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kRestingAlpha];
        _symbolHighlightColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kHoverAlpha];
        _symbolDisabledColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:kDisabledAlpha];
        // EnabledDuringMouseDrag: dragging off and back is a mid-drag exit.
        [self addTrackingArea:[[NSTrackingArea alloc]
                initWithRect:self.bounds
                     options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                             NSTrackingMouseEnteredAndExited | NSTrackingEnabledDuringMouseDrag
                       owner:self userInfo:nil]];
        [self applyColorAnimated:NO];
    }
    return self;
}

// Or a click would also drag the window: NSControl, unlike NSButton, is
// non-opaque.
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

// A player is reached for while another app is frontmost.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

#pragma mark - Layer geometry

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.needsLayout = YES; // the backing scale is known only now
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

// A mask samples only alpha, so the symbol's black needs no tinting.
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
    rep.size = size; // so the draw below fills the pixel grid
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

// Integral: a half-point offset softens the edges.
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
    // Full strength at hover, the factory ratios elsewhere.
    float opacity;
    if (!self.isEnabled) {
        color = _symbolDisabledColor;
        opacity = kDisabledAlpha / kHoverAlpha;
    } else if (_mouseDown && _hovering) {
        color = VibeColorWithScaledAlpha(_symbolHighlightColor, kPressedFraction);
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
    _symbolNormalColor = color;
    _symbolHighlightColor = VibeColorWithScaledAlpha(color, kHoverAlpha / kRestingAlpha);
    _symbolDisabledColor = VibeColorWithScaledAlpha(color, kDisabledAlpha / kRestingAlpha);
    [self applyColorAnimated:NO];
}

#pragma mark - Mouse handling (momentary push)

// Disabled and invisible buttons are click-through: the chrome rests at alpha
// 0, and an invisible close button must not quit the app. The animator writes
// the model alpha up front, so a button fading in is already hittable.
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
    _hovering = YES;
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
    _hovering = NSPointInRect(point, self.bounds);
    [self applyColorAnimated:YES];
    // It can be disabled mid-press.
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

// Hides the color layer rather than replacing its mask, which a return to the
// symbol reuses.
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
