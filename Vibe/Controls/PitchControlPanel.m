//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "PitchControlPanel.h"
#import "Fonts.h"

const CGFloat kPitchPanelWidth = 96;

// Matches MainWindow's contentView cornerRadius so the panel's right edge
// follows the window shape.
static const CGFloat kPanelCornerRadius = 26;

static const CGFloat kTopPadding    = 14;
static const CGFloat kTitleHeight   = 14;
static const CGFloat kReadoutHeight = 16;
static const CGFloat kBottomPadding = 16;

// Collapsed (playlist-hidden) layout: no header, the fader gets everything.
static const CGFloat kFaderTopCompact    = 12;
static const CGFloat kBottomPaddingCompact = 12;

// The header (PITCH + readout) fades and the fader slides as a continuous
// function of panel height across this band, so the animated window resize
// carries the panel transition with it — no discrete jump at a threshold.
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
        _titleLabel = [NSTextField labelWithString:@"PITCH"];
        _titleLabel.font = [Fonts font:10 bold:YES];
        _titleLabel.textColor = [NSColor colorWithWhite:0.55 alpha:1];
        _titleLabel.alignment = NSTextAlignmentCenter;
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

- (void)layoutPanel {
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    // 0 = collapsed (header hidden, full-length fader), 1 = expanded.
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
}

- (void)drawRect:(NSRect)dirtyRect {
    // Round only the right corners, with a path that stays strictly inside
    // bounds. Never draw outside bounds here: the backing layer doesn't mask,
    // and (at least via CALayer renderInContext, seen on macOS 26) drawing
    // past the left edge bleeds a dark strip over the main content.
    NSRect b = self.bounds;
    CGFloat r = kPanelCornerRadius;
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

    // Hairline seam against the main content, like a joined deck panel.
    [[NSColor colorWithWhite:0 alpha:0.8] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 1, self.bounds.size.height), NSCompositingOperationSourceOver);
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
    NSString *text;
    if (pitch == 0) {
        text = @"0.0%";
    }
    else {
        // U+2212 minus sign, wider than a hyphen — matches the fader scale.
        text = [NSString stringWithFormat:@"%@%.1f%%", pitch > 0 ? @"+" : @"−", fabsf(pitch)];
    }
    _readoutField.stringValue = text;
    _readoutField.textColor = (pitch == 0)
            ? [NSColor colorWithRed:0.22 green:0.95 blue:0.40 alpha:1]
            : [NSColor colorWithWhite:0.85 alpha:1];
}

#pragma mark - PitchFaderViewDelegate

- (void)pitchFaderView:(PitchFaderView *)faderView didChangePitch:(float)pitch {
    [self updateReadout];
    [self.delegate pitchFaderView:faderView didChangePitch:pitch];
}

- (void)pitchFaderViewDidEndAdjusting:(PitchFaderView *)faderView {
    [self.delegate pitchFaderViewDidEndAdjusting:faderView];
}

@end
