//
//  CupertinoWaveformRenderer.mm
//  Vibe
//

#import "CupertinoWaveformRenderer.h"
#import "VibeStrings.h"
#import "PlatformColor.h"

#pragma mark - Cupertino

// A hairline on a 1x display, two device pixels on Retina, with the other
// three points of Basic's pitch a gap.
static const CGFloat kCupertinoBarWidth = 1;

@implementation CupertinoWaveformRenderer

+ (NSString *)styleIdentifier {
    return @"cupertino";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_CUPERTINO;
}

- (CGFloat)barWidthForWidth:(CGFloat)width barCount:(NSUInteger)count {
    return kCupertinoBarWidth;
}

// ±level rather than the peak envelope: every bar is centered on the midline
// and its height is the column's energy, the level Sonic Cirrus draws.
- (void)fillEnvelope:(float *)out barCount:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    float fullScaleRMS = VibeWaveformFullScaleRMSForWaveform(waveform, self.normalizesLevels);
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count; i++) {
        float level = VibeWaveformBarLevel(
                VibeWaveformEnergyColumnForBar(waveform, i, count).getMeanSquare(),
                fullScaleRMS, gainDB);
        out[i * 2] = -level;
        out[i * 2 + 1] = level;
    }
}

// A bar mirrored about the midline gets a fade mirrored the same way —
// Basic's grounded ramp would dim one half of every bar — full at the
// midline, Detailed's bottom level at both ends, over Basic's full-view axis.
- (NSArray<VibeColor *> *)gradientColorsForColor:(VibeColor *)color isDark:(BOOL)isDark {
    if (self.theme.flatFill) {
        return @[color, color];
    }
    const CGFloat kEndAlpha = 0.45;
    return @[
            VibeColorWithScaledAlpha(color, kEndAlpha),
            color,
            VibeColorWithScaledAlpha(color, kEndAlpha),
    ];
}

@end

#pragma mark - Cupertino Basic

// Apple Music's scrubber is about 7pt; this one is deliberately a little
// taller. Hovering grows the pill, Apple Music's own affordance, and the
// growth is what says "this is the control" — the column below only says
// where the seek would land.
static const CGFloat kPillHeight = 9;
static const CGFloat kPillHoverHeight = 16;
static const CGFloat kPillHoverGrowDuration = 0.18;

// The tracked-seek column inside the pill, matching Detailed's affordance in
// weight; the capsule mask rounds it away at the ends for free.
static const CGFloat kHoverColumnWidth = 1.5;

// The pill alone is a small target in the waveform's strip, so the seek band
// is the hovered pill plus slider-like slop either side; outside it a drag
// stays the window's, as with every style.
static const CGFloat kSeekBandHeight = 28;

@implementation CupertinoBasicWaveformRenderer {
    CALayer *_track;       // the capsule: unplayed color, masks the two below
    CALayer *_fill;        // played color over [0, progress]; its leading cap
                           // is the track's mask, its playhead edge is square
    CALayer *_hoverColumn;
    CGRect _bounds;
    CGFloat _progress;
}

+ (NSString *)styleIdentifier {
    return @"cupertino_basic";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_CUPERTINO_BASIC;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {
        _bounds = bounds;
        CGFloat scale = parentLayer.contentsScale;
        _track = [CALayer layer];
        _track.masksToBounds = YES;
        _track.contentsScale = scale;
        _fill = [CALayer layer];
        _fill.anchorPoint = CGPointZero;
        _fill.contentsScale = scale;
        _hoverColumn = [CALayer layer];
        _hoverColumn.anchorPoint = CGPointZero;
        _hoverColumn.contentsScale = scale;
        _hoverColumn.hidden = YES;
        [_track addSublayer:_fill];
        [_track addSublayer:_hoverColumn];
        [parentLayer addSublayer:_track];
        [self updateColors:isDark];
        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)dealloc {
    [_track removeFromSuperlayer];
}

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.backgroundColor = self.theme.unplayedColor.CGColor;
    _fill.backgroundColor = self.theme.playedColor.CGColor;
    _hoverColumn.backgroundColor = self.theme.hoverColor.CGColor;
    [CATransaction commit];
}

- (CGFloat)pillHeight {
    CGFloat height = self.hoverHighlightX >= 0 ? kPillHoverHeight : kPillHeight;
    return MIN(height, _bounds.size.height);
}

// Places all three layers for the current bounds, hover state and progress.
// Callers own the transaction: layout passes disable actions, the hover flip
// leaves them on so the growth animates.
- (void)layoutPill {
    if (_bounds.size.width <= 0 || _bounds.size.height <= 0) {
        return;
    }
    CGFloat height = [self pillHeight];
    // Whole points, so the pill's edges sit on device pixels at any backing
    // scale — which is also why backingScaleDidChange needs no rebuild here.
    CGFloat y = round(CGRectGetMidY(_bounds) - height / 2);
    _track.frame = CGRectMake(CGRectGetMinX(_bounds), y, _bounds.size.width, height);
    _track.cornerRadius = height / 2;
    _fill.frame = CGRectMake(0, 0, _progress * _bounds.size.width, height);
    [self layoutHoverColumn];
}

- (void)layoutHoverColumn {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat x = self.hoverHighlightX;
    if (x < 0 || _bounds.size.width <= 0) {
        _hoverColumn.hidden = YES;
    } else {
        _hoverColumn.frame = VibeSnappedColumnRect(x - CGRectGetMinX(_bounds),
                                                   kHoverColumnWidth, _bounds.size.width,
                                                   _track.bounds.size.height,
                                                   VibeBackingScaleForLayer(self.parentLayer));
        _hoverColumn.hidden = NO;
    }
    [CATransaction commit];
}

- (void)setHoverHighlightX:(CGFloat)x {
    BOOL wasHovering = self.hoverHighlightX >= 0;
    [super setHoverHighlightX:x];
    if ((x >= 0) != wasHovering) {
        // The hover flip grows or settles the pill; the frame and radius
        // animate through the transaction's implicit actions.
        [CATransaction begin];
        [CATransaction setAnimationDuration:kPillHoverGrowDuration];
        [self layoutPill];
        [CATransaction commit];
    } else {
        // Same hover state, new x: only the column moves, action-free.
        [self layoutHoverColumn];
    }
}

- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    CGFloat height = MIN(kSeekBandHeight, bounds.size.height);
    return CGRectMake(bounds.origin.x, CGRectGetMidY(bounds) - height / 2,
                      bounds.size.width, height);
}

// The samples are never read — the pill is the same picture for every track —
// but their ABSENCE is the empty and loading states, where the bar styles
// collapse to the midline and a full-width track would instead read as a
// loaded file at 0:00 and frame the loading shimmer. Hidden is this style's
// collapse; a late delivery simply unhides it.
- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    _bounds = bounds;
    _progress = MAX(0.0, MIN(1.0, progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.hidden = (waveform == nullptr);
    [self layoutPill];
    [CATransaction commit];
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *)waveform {
    _progress = MAX(0.0, MIN(1.0, progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fill.frame = CGRectMake(0, 0, _progress * _bounds.size.width, _track.bounds.size.height);
    [CATransaction commit];
}

@end
