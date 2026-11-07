//
//  PlaylistDropZoneView.m
//  Vibe
//

#import <QuartzCore/QuartzCore.h> // CATransition for the state fade
#import "PlaylistDropZoneView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "VibeDropWellsView.h"
#import "VibeStrings.h"

#pragma mark - Layout

// The rest well sits where vibe-libs' drag-over wells do.
static const CGFloat kWellInset = 20;        // well edge from the pane edge
static const CGFloat kWellCornerRadius = 10;
static const CGFloat kWellStrokeWidth = 2;
static const CGFloat kWellDashLength = 6;    // 6 on / 6 off, round caps
static const CGFloat kWellLabelInset = 12;   // label text from the well border

// The rest state: two stacked lines.
static const CGFloat kRestLineGap = 8;
// The Open shortcut's keycap chip on the second line.
static const CGFloat kKeycapPaddingH = 6;
static const CGFloat kKeycapPaddingV = 2;
static const CGFloat kKeycapCornerRadius = 4;
static const CGFloat kKeycapGap = 5;         // after "or press"

// The swap between rest and drag-over: a fast fade, deliberately not springy.
static const CFTimeInterval kStateFadeDuration = 0.12;

// The wells' identifiers, which the drop resolves to an action.
static NSString *const kReplaceWell = @"replace";
static NSString *const kAddWell = @"add";

#pragma mark - Palette

// Fixed colors, not appearance-driven: the pane's frost reads as the same
// mid-gray in both appearances. The keycap chip is the one exception.
static NSColor *HexColor(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
}

// A child canvas for the rest well, above the wells view; the parent keeps
// all state and drawing.
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

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

@end

@implementation PlaylistDropZoneView {
    // The drag-over wells, their blur over the rows, and their light.
    VibeDropWellsView *_wellsView;
    PlaylistDropZoneCanvas *_canvas;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _playlistEmpty = YES;
        self.wantsLayer = YES;
        // The compact layout squashes the pane to zero height, and views do not
        // clip by default since 10.14, so the drawing would spill over the
        // header.
        self.clipsToBounds = YES;

        _wellsView = [[VibeDropWellsView alloc] initWithFrame:self.bounds];
        _wellsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // This view fades its own layer, the rest well's swap with them.
        _wellsView.fadesStateChanges = NO;
        VibeDropWellsStyle *style = [[VibeDropWellsStyle alloc] init];
        style.strokeColor = HexColor(0x62646E);
        style.hoverStrokeColor = HexColor(0x9FA4B4);
        style.hoverFillColor = [NSColor colorWithWhite:1 alpha:0.05];
        style.contentColor = HexColor(0x75777F);
        style.hoverContentColor = HexColor(0xC6C8D0);
        style.font = [Fonts font:14];
        _wellsView.style = style;
        [self addSubview:_wellsView];
        [self updateWells];

        _canvas = [[PlaylistDropZoneCanvas alloc] initWithFrame:self.bounds];
        _canvas.zone = self;
        _canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_canvas];
    }
    return self;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    _canvas.needsDisplay = YES;
}

- (void)setPlaylistEmpty:(BOOL)playlistEmpty {
    if (_playlistEmpty == playlistEmpty) {
        return;
    }
    _playlistEmpty = playlistEmpty;
    [self updateWells];
    _canvas.needsDisplay = YES;
}

- (void)setOpenShortcut:(NSString *)openShortcut {
    if ([_openShortcut isEqualToString:openShortcut] || _openShortcut == openShortcut) {
        return;
    }
    _openShortcut = [openShortcut copy];
    _canvas.needsDisplay = YES;
}

// Replace against add is meaningless with no rows: an empty playlist shows
// one full-width add well, with no blur, since there are no rows to read
// against.
- (void)updateWells {
    VibeDropWell *add = [VibeDropWell wellWithIdentifier:kAddWell
                                                   title:STR_LABEL_PLAYLIST_DROP_ADD
                                              symbolName:@"plus"];
    VibeDropWell *replace = [VibeDropWell wellWithIdentifier:kReplaceWell
                                                       title:STR_LABEL_PLAYLIST_DROP_REPLACE
                                                  symbolName:@"arrow.triangle.2.circlepath"];
    _wellsView.wells = _playlistEmpty ? @[add] : @[replace, add];
    _wellsView.showsBlur = !_playlistEmpty;
}

#pragma mark - Geometry

// The compact layout collapses the pane to near-zero height.
- (BOOL)isEffectivelyVisible {
    return self.window && !self.hiddenOrHasHiddenAncestor &&
           NSHeight(self.bounds) > 2 * kWellInset + 2 * kWellCornerRadius;
}

- (NSRect)fullWellRect {
    return NSInsetRect(self.bounds, kWellInset, kWellInset);
}

static PlaylistDropWellAction ActionOfWell(NSString *identifier) {
    if ([identifier isEqualToString:kAddWell]) {
        return PlaylistDropWellActionAdd;
    }
    return [identifier isEqualToString:kReplaceWell] ? PlaylistDropWellActionReplace : PlaylistDropWellActionNone;
}

#pragma mark - Drag-over tracking

- (void)fileDragUpdatedAtWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return;
    }
    if (!_wellsView.dragActive) {
        [self addStateFade]; // entering drag-over; hover moves redraw plainly
        _canvas.needsDisplay = YES;
    }
    [_wellsView fileDragUpdatedAtWindowPoint:point];
}

- (void)fileDragEnded {
    if (!_wellsView.dragActive) {
        return;
    }
    [self addStateFade];
    [_wellsView fileDragEnded];
    _canvas.needsDisplay = YES;
}

- (PlaylistDropWellAction)dropActionForWindowPoint:(NSPoint)point {
    if (![self isEffectivelyVisible]) {
        return PlaylistDropWellActionNone;
    }
    return ActionOfWell([_wellsView wellIdentifierAtWindowPoint:point]);
}

- (void)addStateFade {
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = kStateFadeDuration;
    [self.layer addAnimation:fade forKey:@"stateFade"];
}

#pragma mark - Click → open panel

// Only the empty-playlist rest well is interactive: the margin stays
// hit-transparent for the window's background drag, and a populated playlist's
// table is never shadowed.
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    if (_playlistEmpty && !_wellsView.dragActive && [self isEffectivelyVisible] &&
        NSPointInRect(local, [self fullWellRect])) {
        return self;
    }
    return nil;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

// A click on an inactive window should open the picker, not merely activate.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

// Claimed, not forwarded to super: only a claimed down routes the mouseUp here.
- (void)mouseDown:(NSEvent *)event {
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint local = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(local, [self fullWellRect])) {
        [NSApp sendAction:@selector(openDocument:) to:nil from:self];
    }
}

#pragma mark - Accessibility

// Same gate as hitTest:, so VoiceOver cannot press a well the squashed pane
// gives no visual presence.
- (BOOL)isAccessibilityElement {
    return _playlistEmpty && [self isEffectivelyVisible];
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
    return STR_A11Y_PLAYLIST_OPEN;
}

- (BOOL)accessibilityPerformPress {
    [NSApp sendAction:@selector(openDocument:) to:nil from:self];
    return YES;
}

#pragma mark - Drawing (canvas content)

- (void)drawCanvas {
    // The clip alone would still show slivers of off-center content
    // mid-resize. The drag-over wells are the wells view's.
    if (![self isEffectivelyVisible] || _wellsView.dragActive || !_playlistEmpty) {
        return;
    }
    [self drawRestWell];
}

// One path, so the dash pattern runs evenly through the corners.
static void strokeWellBorder(NSRect wellRect, NSColor *strokeColor) {
    NSRect r = NSInsetRect(wellRect, kWellStrokeWidth / 2, kWellStrokeWidth / 2);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:kWellCornerRadius
                                                         yRadius:kWellCornerRadius];
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

// Not drawAtPoint:, which cannot truncate a long translation.
static void drawTextCenteredAt(NSAttributedString *text, CGFloat centerX, CGFloat y, CGFloat maxWidth) {
    CGFloat width = MIN(ceil(text.size.width), maxWidth);
    [text drawWithRect:NSMakeRect(centerX - width / 2, y, width, ceil(text.size.height))
               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
               context:nil];
}

- (void)drawRestWell {
    NSRect well = [self fullWellRect];
    strokeWellBorder(well, HexColor(0x62646E));

    NSAttributedString *line1 = [[NSAttributedString alloc]
            initWithString:STR_LABEL_PLAYLIST_DRAG_HINT
                attributes:textAttributes([Fonts font:14], HexColor(0x85878F))];
    NSSize line1Size = line1.size;
    CGFloat midX = NSMidX(well);
    // With Open unassigned there is no second line to offer.
    if (!_openShortcut) {
        drawTextCenteredAt(line1, midX, NSMidY(well) - line1Size.height / 2,
                           NSWidth(well) - 2 * kWellLabelInset);
        return;
    }
    NSAttributedString *orPress = [[NSAttributedString alloc]
            initWithString:STR_LABEL_PLAYLIST_OR_PRESS
                attributes:textAttributes([Fonts font:13], HexColor(0x64666F))];
    NSAttributedString *keycapText = [[NSAttributedString alloc]
            initWithString:_openShortcut
                attributes:textAttributes([Fonts font:12], HexColor(0x85878F))];

    NSSize orPressSize = orPress.size;
    NSSize keycapTextSize = keycapText.size;
    NSSize keycapSize = NSMakeSize(ceil(keycapTextSize.width) + 2 * kKeycapPaddingH,
                                   ceil(keycapTextSize.height) + 2 * kKeycapPaddingV);

    CGFloat line2Height = MAX(orPressSize.height, keycapSize.height);
    CGFloat totalHeight = line1Size.height + kRestLineGap + line2Height;
    // The view is not flipped, so line 1 sits above line 2.
    CGFloat line2Y = NSMidY(well) - totalHeight / 2;
    CGFloat line1Y = line2Y + line2Height + kRestLineGap;
    drawTextCenteredAt(line1, midX, line1Y, NSWidth(well) - 2 * kWellLabelInset);

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
    // Appearance-aware: a white-alpha chip vanishes on the light frost.
    CGFloat capWhite = self.isDark ? 1 : 0;
    [[NSColor colorWithWhite:capWhite alpha:0.06] setFill];
    [keycap fill];
    keycap.lineWidth = 1;
    [[NSColor colorWithWhite:capWhite alpha:0.10] setStroke];
    [keycap stroke];
    [keycapText drawAtPoint:NSMakePoint(NSMidX(keycapRect) - keycapTextSize.width / 2,
                                        NSMidY(keycapRect) - keycapTextSize.height / 2)];
}

@end
