//
// Created by Christopher Micali on 7/29/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <QuartzCore/QuartzCore.h> // CATransition for the state fade
#import "PlaylistDropZoneView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"

#pragma mark - Layout

static const CGFloat kWellInset = 20;        // well edge from the pane edge
static const CGFloat kWellCornerRadius = 10;
static const CGFloat kWellStrokeWidth = 2;
static const CGFloat kWellDashLength = 6;    // 6 on / 6 off, round caps
static const CGFloat kWellGap = 16;          // between the two drag-over wells

// Rest state: two stacked lines.
static const CGFloat kRestLineGap = 8;
// The ⌘O keycap chip on the second line.
static const CGFloat kKeycapPaddingH = 6;
static const CGFloat kKeycapPaddingV = 2;
static const CGFloat kKeycapCornerRadius = 4;
static const CGFloat kKeycapGap = 5;         // after "or press"

// Drag-over wells: SF Symbol above the label.
static const CGFloat kDropIconPointSize = 26;
static const CGFloat kDropIconLabelGap = 10;

// Rest ↔ drag-over swap: a fast fade, deliberately not springy.
static const CFTimeInterval kStateFadeDuration = 0.12;

#pragma mark - Palette

// Fixed colors (not appearance-driven): the design is anchored to the playlist
// pane's frost, which reads as the same mid-gray in both appearances. The one
// exception is the keycap chip (see drawRestWellInRect:).
static NSColor *HexColor(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
}

// The wells and hint text live on a child canvas so they composite ABOVE the
// blur (a view's own drawRect content renders underneath its subviews). All
// state and drawing logic stay in the parent; the canvas just forwards.
@class PlaylistDropZoneView;

@interface PlaylistDropZoneCanvas : NSView
@property (nonatomic, weak) PlaylistDropZoneView *zone;
@end

@interface PlaylistDropZoneView ()
- (void)drawCanvas;
@end

@implementation PlaylistDropZoneCanvas

- (void)drawRect:(NSRect)dirtyRect {
    [self.zone drawCanvas];
}

// The parent owns all mouse handling.
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end

@implementation PlaylistDropZoneView {
    BOOL _dragActive;
    PlaylistDropWellAction _hoveredWell; // None while over neither well
    NSVisualEffectView *_blurView;       // over the rows during drag-over
    PlaylistDropZoneCanvas *_canvas;
    // Tinted SF Symbol images, keyed "name/rgb" — rebuilt colors are cheap but
    // drag-over redraws arrive at mouse-move rate.
    NSMutableDictionary<NSString *, NSImage *> *_symbolCache;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _symbolCache = [NSMutableDictionary new];
        _playlistEmpty = YES;
        // Layer-backed for the CATransition fade between states.
        self.wantsLayer = YES;
        // The collapsed (small) window layout squashes the pane to zero
        // height; without clipping, drawing would spill over the header
        // (views stopped clipping to bounds in 10.14).
        self.clipsToBounds = YES;

        // Readability blur for the wells over a populated playlist's rows.
        // Within-window: it blurs the table rendered beneath this view.
        _blurView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        _blurView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        _blurView.material = NSVisualEffectMaterialHUDWindow;
        _blurView.state = NSVisualEffectStateActive;
        _blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _blurView.hidden = YES;
        [self addSubview:_blurView];

        _canvas = [[PlaylistDropZoneCanvas alloc] initWithFrame:self.bounds];
        _canvas.zone = self;
        _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_canvas];
    }
    return self;
}

// The keycap chip is appearance-dependent (see drawRestWellInRect:).
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    _canvas.needsDisplay = YES;
}

- (void)setPlaylistEmpty:(BOOL)playlistEmpty {
    if (_playlistEmpty == playlistEmpty) {
        return;
    }
    _playlistEmpty = playlistEmpty;
    [self updateBlur];
    _canvas.needsDisplay = YES;
}

- (void)updateBlur {
    _blurView.hidden = !(_dragActive && !_playlistEmpty);
}

#pragma mark - Geometry

// The pane collapses to (near) zero height in the small window layout; the
// wells only participate when there is actually room to show them.
- (BOOL)isEffectivelyVisible {
    return self.window && !self.hiddenOrHasHiddenAncestor &&
           NSHeight(self.bounds) > 2 * kWellInset + 2 * kWellCornerRadius;
}

// The single well (rest hint, and the full-width add well while the playlist
// is empty).
- (NSRect)fullWellRect {
    return NSInsetRect(self.bounds, kWellInset, kWellInset);
}

- (NSRect)wellRectForAction:(PlaylistDropWellAction)action {
    NSRect inset = [self fullWellRect];
    if (_playlistEmpty) {
        // One full-width well; only Add exists.
        return action == PlaylistDropWellActionAdd ? inset : NSZeroRect;
    }
    CGFloat width = floor((NSWidth(inset) - kWellGap) / 2);
    if (action == PlaylistDropWellActionReplace) {
        return NSMakeRect(NSMinX(inset), NSMinY(inset), width, NSHeight(inset));
    }
    // Right-anchored so the rounding slack lands in the gap, not at the edge.
    return NSMakeRect(NSMaxX(inset) - width, NSMinY(inset), width, NSHeight(inset));
}

- (PlaylistDropWellAction)wellActionAtPoint:(NSPoint)point {
    if (NSPointInRect(point, [self wellRectForAction:PlaylistDropWellActionAdd])) {
        return PlaylistDropWellActionAdd;
    }
    if (NSPointInRect(point, [self wellRectForAction:PlaylistDropWellActionReplace])) {
        return PlaylistDropWellActionReplace;
    }
    return PlaylistDropWellActionNone;
}

#pragma mark - Drag-over tracking

- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return;
    }
    PlaylistDropWellAction hovered = [self wellActionAtPoint:[self convertPoint:point fromView:nil]];
    if (_dragActive && hovered == _hoveredWell) {
        return;
    }
    if (!_dragActive) {
        [self addStateFade]; // entering drag-over; hover moves redraw plainly
    }
    _dragActive = YES;
    _hoveredWell = hovered;
    [self updateBlur];
    _canvas.needsDisplay = YES;
}

- (void)fileDragEnded {
    if (!_dragActive) {
        return;
    }
    _dragActive = NO;
    _hoveredWell = PlaylistDropWellActionNone;
    [self addStateFade];
    [self updateBlur];
    _canvas.needsDisplay = YES;
}

- (PlaylistDropWellAction)dropActionForWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return PlaylistDropWellActionNone;
    }
    return [self wellActionAtPoint:[self convertPoint:point fromView:nil]];
}

- (void)addStateFade {
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kStateFadeDuration;
    [self.layer addAnimation:fade forKey:@"stateFade"];
}

#pragma mark - Click → open panel

// Only the empty-playlist rest-state well is interactive; the 20px margin
// stays hit-transparent so the window's background drag keeps working there.
// Over a populated playlist the zone must never shadow the table.
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (_playlistEmpty && !_dragActive && [self isEffectivelyVisible] &&
        NSPointInRect(local, [self fullWellRect])) {
        return self;
    }
    return nil;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

// A click on an inactive window should open the picker, not just activate.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

// Claim the down (don't forward to super): NSView's default implementation
// sends it up the responder chain, and only a claimed down routes the
// matching mouseUp here.
- (void)mouseDown:(NSEvent *)event {
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(local, [self fullWellRect])) {
        // Same action as ⌘O: routed up the responder chain to AppDelegate.
        [NSApp sendAction:@selector(openDocument:) to:nil from:self];
    }
}

#pragma mark - Accessibility

- (BOOL)isAccessibilityElement {
    return _playlistEmpty && ![self isHidden];
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
    return @"Open songs or folders";
}

- (BOOL)accessibilityPerformPress {
    [NSApp sendAction:@selector(openDocument:) to:nil from:self];
    return YES;
}

#pragma mark - Drawing (canvas content)

- (void)drawCanvas {
    // Collapsed pane: no room for a well — draw nothing (the clip alone
    // would still show slivers of off-center content while mid-resize).
    if (![self isEffectivelyVisible]) {
        return;
    }
    if (_dragActive) {
        if (!_playlistEmpty) {
            [self drawDropWell:PlaylistDropWellActionReplace
                        symbol:@"arrow.triangle.2.circlepath"
                         label:@"Drop to replace playlist"];
        }
        [self drawDropWell:PlaylistDropWellActionAdd
                    symbol:@"plus"
                     label:@"Drop to add to playlist"];
    }
    else if (_playlistEmpty) {
        [self drawRestWell];
    }
    // Populated playlist at rest: nothing — the rows own the pane.
}

// Dashed rounded-rect border, stroked as ONE path so the dash pattern runs
// evenly through the corners (four independent edges would restart the
// pattern at each corner).
static void strokeWellBorder(NSRect wellRect, NSColor *strokeColor, NSColor *fillColor) {
    NSRect r = NSInsetRect(wellRect, kWellStrokeWidth / 2, kWellStrokeWidth / 2);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:kWellCornerRadius
                                                         yRadius:kWellCornerRadius];
    if (fillColor) {
        [fillColor setFill];
        [path fill];
    }
    path.lineWidth = kWellStrokeWidth;
    path.lineCapStyle = NSLineCapStyleRound;
    CGFloat dash[2] = { kWellDashLength, kWellDashLength };
    [path setLineDash:dash count:2 phase:0];
    [strokeColor setStroke];
    [path stroke];
}

static NSDictionary *textAttributes(NSFont *font, NSColor *color) {
    return @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
}

- (void)drawRestWell {
    NSRect well = [self fullWellRect];
    strokeWellBorder(well, HexColor(0x62646E), nil);

    NSAttributedString *line1 = [[NSAttributedString alloc]
            initWithString:@"Drag songs or folders here"
                attributes:textAttributes([Fonts font:14], HexColor(0x85878F))];
    NSAttributedString *orPress = [[NSAttributedString alloc]
            initWithString:@"or press"
                attributes:textAttributes([Fonts font:13], HexColor(0x64666F))];
    NSAttributedString *keycapText = [[NSAttributedString alloc]
            initWithString:@"⌘O"
                attributes:textAttributes([Fonts font:12], HexColor(0x85878F))];

    NSSize line1Size = line1.size;
    NSSize orPressSize = orPress.size;
    NSSize keycapTextSize = keycapText.size;
    NSSize keycapSize = NSMakeSize(ceil(keycapTextSize.width) + 2 * kKeycapPaddingH,
                                   ceil(keycapTextSize.height) + 2 * kKeycapPaddingV);

    CGFloat line2Height = MAX(orPressSize.height, keycapSize.height);
    CGFloat totalHeight = line1Size.height + kRestLineGap + line2Height;
    CGFloat midX = NSMidX(well);
    // Non-flipped view: line 1 sits above line 2.
    CGFloat line2Y = NSMidY(well) - totalHeight / 2;
    CGFloat line1Y = line2Y + line2Height + kRestLineGap;

    [line1 drawAtPoint:NSMakePoint(midX - line1Size.width / 2, line1Y)];

    CGFloat line2Width = orPressSize.width + kKeycapGap + keycapSize.width;
    CGFloat line2X = midX - line2Width / 2;
    [orPress drawAtPoint:NSMakePoint(line2X,
                                     line2Y + (line2Height - orPressSize.height) / 2)];

    NSRect keycapRect = NSMakeRect(line2X + orPressSize.width + kKeycapGap,
                                   line2Y + (line2Height - keycapSize.height) / 2,
                                   keycapSize.width, keycapSize.height);
    NSBezierPath *keycap = [NSBezierPath
            bezierPathWithRoundedRect:NSInsetRect(keycapRect, 0.5, 0.5)
                              xRadius:kKeycapCornerRadius
                              yRadius:kKeycapCornerRadius];
    // The only appearance-aware color here: the white-alpha chip that reads
    // as a keycap on the dark frost disappears entirely on the light one.
    CGFloat capWhite = self.isDark ? 1 : 0;
    [[NSColor colorWithWhite:capWhite alpha:0.06] setFill];
    [keycap fill];
    keycap.lineWidth = 1;
    [[NSColor colorWithWhite:capWhite alpha:0.10] setStroke];
    [keycap stroke];
    [keycapText drawAtPoint:NSMakePoint(NSMidX(keycapRect) - keycapTextSize.width / 2,
                                        NSMidY(keycapRect) - keycapTextSize.height / 2)];
}

- (void)drawDropWell:(PlaylistDropWellAction)action
              symbol:(NSString *)symbolName
               label:(NSString *)label {
    BOOL hovered = (_hoveredWell == action);
    NSRect well = [self wellRectForAction:action];
    strokeWellBorder(well,
                     hovered ? HexColor(0x9FA4B4) : HexColor(0x62646E),
                     hovered ? [NSColor colorWithWhite:1 alpha:0.05] : nil);

    NSColor *contentColor = hovered ? HexColor(0xC6C8D0) : HexColor(0x75777F);
    NSImage *icon = [self symbolImage:symbolName color:contentColor];
    NSAttributedString *text = [[NSAttributedString alloc]
            initWithString:label
                attributes:textAttributes([Fonts font:14], contentColor)];

    NSSize iconSize = icon.size;
    NSSize textSize = text.size;
    CGFloat totalHeight = iconSize.height + kDropIconLabelGap + textSize.height;
    CGFloat textY = NSMidY(well) - totalHeight / 2;
    CGFloat iconY = textY + textSize.height + kDropIconLabelGap;

    [icon drawInRect:NSMakeRect(NSMidX(well) - iconSize.width / 2, iconY,
                                iconSize.width, iconSize.height)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
    [text drawAtPoint:NSMakePoint(NSMidX(well) - textSize.width / 2, textY)];
}

- (NSImage *)symbolImage:(NSString *)name color:(NSColor *)color {
    NSString *key = [NSString stringWithFormat:@"%@/%@", name, color];
    NSImage *image = _symbolCache[key];
    if (!image) {
        NSImageSymbolConfiguration *config =
                [NSImageSymbolConfiguration configurationWithPointSize:kDropIconPointSize
                                                                weight:NSFontWeightMedium];
        config = [config configurationByApplyingConfiguration:
                [NSImageSymbolConfiguration configurationWithPaletteColors:@[ color ]]];
        image = [[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
                imageWithSymbolConfiguration:config];
        _symbolCache[key] = image;
    }
    return image;
}

@end
