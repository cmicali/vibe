//
//  PitchControlPanel.m
//  Vibe
//

#import "PitchControlPanel.h"
#import "PitchFaderView.h"
#import "Fonts.h"

const CGFloat kPitchPanelWidth = 96;

static const CGFloat kTopPadding    = 14;
static const CGFloat kTitleHeight   = 14;
static const CGFloat kReadoutHeight = 16;
static const CGFloat kBottomPadding = 16;

// Playlist collapsed: no header, and the fader gets everything.
static const CGFloat kFaderTopCompact    = 12;
static const CGFloat kBottomPaddingCompact = 12;

// Across this band the header fades and the fader slides continuously with
// the height, so the animated resize carries the transition with no jump.
static const CGFloat kHeaderFadeStartHeight = 200;
static const CGFloat kHeaderFadeEndHeight   = 340;

@interface PitchControlPanel () <PitchFaderViewDelegate>
@end

@implementation PitchControlPanel {
    PitchFaderView *_faderView;
    NSTextField    *_titleLabel;
    NSTextField    *_readoutField;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [Fonts font:10 bold:YES];
        _titleLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1];
        _titleLabel.alignment = NSTextAlignmentCenter;
        // Long translations ellipsize in 96pt.
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.maximumNumberOfLines = 1;
        [self addSubview:_titleLabel];

        _readoutField = [NSTextField labelWithString:@""];
        _readoutField.font = [Fonts fontForNumbers:12 bold:YES];
        _readoutField.alignment = NSTextAlignmentCenter;
        [self addSubview:_readoutField];

        _faderView = [[PitchFaderView alloc] initWithFrame:NSZeroRect];
        _faderView.delegate = self;
        [self addSubview:_faderView];

        [self layoutPanel];
        [self updateReadout];
    }
    return self;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutPanel];
}

// The header is a click target, so the panel drags the window itself from
// everywhere else. Non-opaque, so the default would drag from the header too.
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

// A label is neither editable nor selectable, so its mouseDown falls through
// to the panel.
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, [self headerRect])) {
        [self.delegate pitchControlPanelDidClickHeader:self];
        return;
    }
    [self.window performWindowDragWithEvent:event];
}

// The title and the readout. Empty while the header is faded out for a
// collapsed playlist, so a faded header is neither a target nor a cursor rect.
- (NSRect)headerRect {
    if (_titleLabel.alphaValue <= 0) {
        return NSZeroRect;
    }
    return NSUnionRect(_titleLabel.frame, _readoutField.frame);
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:[self headerRect] cursor:NSCursor.pointingHandCursor];
}

- (void)layoutPanel {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    // 0 collapsed, 1 expanded.
    CGFloat t = (height - kHeaderFadeStartHeight) / (kHeaderFadeEndHeight - kHeaderFadeStartHeight);
    t = MAX(0, MIN(1, t));

    _titleLabel.frame = NSMakeRect(0, height - kTopPadding - kTitleHeight, width, kTitleHeight);
    _readoutField.frame = NSMakeRect(0, height - kTopPadding - kTitleHeight - kReadoutHeight - 2,
                                     width, kReadoutHeight);
    _titleLabel.alphaValue = t;
    _readoutField.alphaValue = t;

    CGFloat headerSpace = kTopPadding + kTitleHeight + kReadoutHeight + 10;
    CGFloat faderTop = kFaderTopCompact + t * (headerSpace - kFaderTopCompact);
    CGFloat faderBottom = kBottomPaddingCompact + t * (kBottomPadding - kBottomPaddingCompact);
    _faderView.frame = NSMakeRect(4, faderBottom, width - 8, height - faderTop - faderBottom);
    [self.window invalidateCursorRectsForView:self];
}

- (void)drawRect:(NSRect)dirtyRect {
    // Right corners only, strictly inside the bounds: the backing layer does
    // not mask, and drawing past the left edge bleeds a dark strip over the
    // body.
    NSRect b = self.bounds;
    CGFloat r = _cornerRadius;
    NSBezierPath *background = [NSBezierPath bezierPath];
    [background moveToPoint:NSMakePoint(NSMinX(b), NSMinY(b))];
    [background lineToPoint:NSMakePoint(NSMaxX(b) - r, NSMinY(b))];
    [background appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(b), NSMinY(b))
                                         toPoint:NSMakePoint(NSMaxX(b), NSMinY(b) + r)
                                          radius:r];
    [background lineToPoint:NSMakePoint(NSMaxX(b), NSMaxY(b) - r)];
    [background appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(b), NSMaxY(b))
                                         toPoint:NSMakePoint(NSMaxX(b) - r, NSMaxY(b))
                                          radius:r];
    [background lineToPoint:NSMakePoint(NSMinX(b), NSMaxY(b))];
    [background closePath];
    [[NSColor colorWithWhite:0.075 alpha:0.97] setFill];
    [background fill];

    // A hairline seam against the main content, like a joined deck panel.
    [[NSColor colorWithWhite:0 alpha:0.8] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 1, self.bounds.size.height), NSCompositingOperationSourceOver);
}

- (NSString *)title {
    return _titleLabel.stringValue;
}

- (void)setTitle:(NSString *)title {
    _titleLabel.stringValue = title;
}

- (NSString *)faderAccessibilityLabel {
    return _faderView.accessibilityLabel;
}

- (void)setFaderAccessibilityLabel:(NSString *)faderAccessibilityLabel {
    _faderView.accessibilityLabel = faderAccessibilityLabel;
}

- (void)setPitchFormatter:(NSString *(^)(double))pitchFormatter {
    _pitchFormatter = [pitchFormatter copy];
    _faderView.accessibilityValueFormatter = _pitchFormatter;
    [self updateReadout];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.needsDisplay = YES;
}

- (float)maxPitch {
    return _faderView.maxPitch;
}

- (void)setMaxPitch:(float)maxPitch {
    _faderView.maxPitch = maxPitch;
    [self updateReadout];
}

- (float)pitch {
    return _faderView.pitch;
}

- (void)setPitch:(float)pitch {
    _faderView.pitch = pitch;
    [self updateReadout];
}

- (void)updateReadout {
    float pitch = _faderView.pitch;
    // The formatter owns the sign, the decimal separator and the % placement.
    _readoutField.stringValue = _pitchFormatter ? _pitchFormatter(pitch) : @"";
    _readoutField.textColor = (pitch == 0)
            ? VibeQuartzLockGreen(1)
            : [NSColor colorWithWhite:0.85 alpha:1];
}

#pragma mark - PitchFaderViewDelegate

- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch {
    [self updateReadout];
    [self.delegate pitchControlPanel:self didChangePitch:pitch];
}

- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView {
    [self.delegate pitchControlPanelDidEndAdjusting:self];
}

@end
