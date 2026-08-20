//
//  LoadingIndicator.m
//  Vibe
//
//  See the header for what the control is. This file is the geometry, the
//  sweep and the palette — ported from the mac view's loading category, which
//  is where both traps below were found. The style-dependent numbers live in
//  LoadingIndicatorMath.h; nothing here branches on style directly.
//

#import "LoadingIndicator.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif

// The band's own travel, independent of how much of the width it may cross.
static const CFTimeInterval kSweepDuration = 1.2;

@implementation LoadingIndicator {
    CALayer         *_track;          // the full-width inert track
    CALayer         *_shimmerClip;    // exactly the span the band may occupy
    CAGradientLayer *_shimmer;        // the sweeping band
    CAGradientLayer *_fill;           // the determinate head; nil while indeterminate
    __weak CALayer  *_host;
    VibeLoadingIndicatorStyle _style;
    CGFloat         _contentsScale;
    BOOL            _isDark;
    float           _progress;        // <0 while indeterminate
    CFAbsoluteTime  _lastProgressAt;
}

- (instancetype)initInLayer:(CALayer *)hostLayer
                      style:(VibeLoadingIndicatorStyle)style
                     isDark:(BOOL)isDark
              contentsScale:(CGFloat)contentsScale {
    self = [super init];
    if (self) {
        _host = hostLayer;
        _style = style;
        _isDark = isDark;
        _contentsScale = contentsScale;
        _progress = -1;
        _lastProgressAt = 0;

        // The control's body: one track, spanning the whole width. The filled
        // head and the shimmer are both read against it, which is what makes
        // the determinate and indeterminate modes one control rather than
        // two — indeterminate is simply nothing filled yet.
        _track = [CALayer layer];
        _track.contentsScale = contentsScale;
        _track.backgroundColor = [self inertTrackColor];
        [hostLayer addSublayer:_track];

        // The row style builds no shimmer at all — its indeterminate is the
        // plain faint pill. Every later touch of these layers is a message to
        // nil there, which is the same nil-tolerance endSweepKeepingFill
        // already relies on.
        if (VibeLoadingIndicatorMetricsForStyle(style, 0).hasShimmer) {
            _shimmerClip = [CALayer layer];
            _shimmerClip.contentsScale = contentsScale;
            _shimmerClip.masksToBounds = YES;
            [hostLayer addSublayer:_shimmerClip];

            _shimmer = [CAGradientLayer layer];
            _shimmer.contentsScale = contentsScale;
            _shimmer.startPoint = CGPointMake(0, 0.5);
            _shimmer.endPoint = CGPointMake(1, 0.5);
            _shimmer.colors = [self shimmerColors];
            [_shimmerClip addSublayer:_shimmer];
        }
    }
    return self;
}

- (BOOL)endSweepKeepingFill {
    [_shimmer removeAllAnimations];
    [_shimmer removeFromSuperlayer];
    [_shimmerClip removeFromSuperlayer];
    [_track removeFromSuperlayer];
    _shimmer = nil;
    _shimmerClip = nil;
    _track = nil;
    return _fill != nil;
}

- (void)removeFromHost {
    [_shimmer removeAllAnimations];
    [_shimmer removeFromSuperlayer];
    [_shimmerClip removeFromSuperlayer];
    [_track removeFromSuperlayer];
    [_fill removeFromSuperlayer];
    _shimmer = nil;
    _shimmerClip = nil;
    _track = nil;
    _fill = nil;
}

#pragma mark - Palette

- (VibeLoadingIndicatorMetrics)paletteMetrics {
    // Alphas do not depend on width; 0 is fine for a palette read.
    return VibeLoadingIndicatorMetricsForStyle(_style, 0);
}

- (VibeColor *)baseColor {
    if (_colorOverride) {
        return _colorOverride;
    }
    // Follows the appearance, as the renderer palettes do, because a fixed
    // white band is near-invisible on a light background.
#if TARGET_OS_OSX
    return _isDark ? [NSColor whiteColor] : [NSColor blackColor];
#else
    return _isDark ? [UIColor whiteColor] : [UIColor blackColor];
#endif
}

- (NSArray *)shimmerColors {
    VibeColor *base = [self baseColor];
    CGFloat peak = [self paletteMetrics].shimmerAlpha;
    return @[
            (id)[base colorWithAlphaComponent:0].CGColor,
            (id)[base colorWithAlphaComponent:peak].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

- (NSArray *)fillColors {
    VibeColor *base = [self baseColor];
    CGFloat alpha = [self paletteMetrics].fillAlpha;
    return @[
            (id)[base colorWithAlphaComponent:alpha].CGColor,
            (id)[base colorWithAlphaComponent:alpha].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

- (CGColorRef)inertTrackColor {
    return [[self baseColor] colorWithAlphaComponent:[self paletteMetrics].trackAlpha].CGColor;
}

- (void)applyPalette {
    _shimmer.colors = [self shimmerColors];
    _track.backgroundColor = [self inertTrackColor];
    _fill.colors = [self fillColors];
}

- (void)setColorOverride:(VibeColor *)colorOverride {
    _colorOverride = colorOverride;
    [self applyPalette];
}

- (void)updateColorsForDark:(BOOL)isDark {
    _isDark = isDark;
    [self applyPalette];
}

- (void)updateContentsScale:(CGFloat)contentsScale {
    _contentsScale = contentsScale;
    _track.contentsScale = contentsScale;
    _shimmerClip.contentsScale = contentsScale;
    _shimmer.contentsScale = contentsScale;
    _fill.contentsScale = contentsScale;
}

#pragma mark - Geometry

- (void)layoutInBounds:(CGRect)bounds {
    [self layoutInBounds:bounds animatedOver:0];
}

// duration > 0 eases the parts that track the download's progress; the rest is
// always instant. Resize and state changes pass 0.
//
// Every layer here may legitimately be nil: endSweepKeepingFill leaves only
// the fill behind, and messages to nil no-op, so this places whatever is left.
- (void)layoutInBounds:(CGRect)bounds animatedOver:(CFTimeInterval)duration {
    CGFloat width = bounds.size.width;
    CGFloat midY = bounds.size.height / 2;
    VibeLoadingIndicatorMetrics metrics = VibeLoadingIndicatorMetricsForStyle(_style, width);
    // The shimmer sweeps the *unfilled* remainder only: it is the "still
    // working on this part" half of one control, and the fill is the "this
    // part is done" half. Indeterminate fills nothing, so the sweep spans the
    // whole width exactly as it always has.
    CGFloat fillEnd = _progress > 0 ? width * MIN(1.0f, _progress) : 0;
    CGFloat remainder = MAX(width - fillEnd, 0);
    CGFloat bandWidth = MIN(metrics.bandWidth, MAX(remainder, 1));

    // The clip is exactly the span the shimmer may occupy, so the band can
    // still slide in and out at the ends without escaping the line. Its left
    // edge is the fill's front, so the two share one transaction: they ease
    // together on a progress sample and snap together on a resize.
    [CATransaction begin];
    if (duration > 0) {
        [CATransaction setAnimationDuration:duration];
        [CATransaction setAnimationTimingFunction:
                [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    }
    else {
        [CATransaction setDisableActions:YES];
    }
    if (_fill && fillEnd > 0) {
        // A soft front, but only as long as there is remainder to fade into:
        // at completion a fixed fade would read as the bar stopping short of
        // the edge rather than as a soft edge.
        CGFloat fade = MIN(metrics.frontFadePoints, remainder);
        _fill.locations = @[ @0, @(MAX(0.0, (fillEnd - fade) / fillEnd)), @1 ];
        _fill.frame = CGRectMake(0, midY - metrics.height / 2, fillEnd, metrics.height);
        _fill.cornerRadius = metrics.cornerRadius;
    }
    _shimmerClip.frame = CGRectMake(fillEnd, midY - metrics.height / 2,
                                    remainder, metrics.height);
    _shimmerClip.cornerRadius = metrics.cornerRadius;
    [CATransaction commit];

    // The band's own position is driven by the sweep animation, so its
    // geometry is always set action-free: an implicit animation here would
    // fight that and stall the sweep.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shimmer.frame = CGRectMake(0, 0, bandWidth, metrics.height);
    // Near completion there is no room left to sweep, so the band fades out
    // rather than jittering in a sliver.
    _shimmer.opacity = (float)MIN(1.0, remainder / MAX(width * 0.08, 1));
    _track.frame = CGRectMake(0, midY - metrics.height / 2, width, metrics.height);
    _track.cornerRadius = metrics.cornerRadius;
    [CATransaction commit];

    [self installSweepAcrossRemainder:remainder bandWidth:bandWidth];
}

// TRAP: reinstall the sweep only when its endpoints actually change. Live
// resize lands here every frame, and an unconditional remove-and-re-add
// restarts the 1.2s sweep each time, freezing the band at the left edge.
- (void)installSweepAcrossRemainder:(CGFloat)remainder bandWidth:(CGFloat)bandWidth {
    NSNumber *fromValue = @(-bandWidth / 2);
    NSNumber *toValue = @(remainder + bandWidth / 2);
    CABasicAnimation *current = (CABasicAnimation *)[_shimmer animationForKey:@"sweep"];
    if ([current isKindOfClass:CABasicAnimation.class] &&
        [current.fromValue isEqual:fromValue] && [current.toValue isEqual:toValue]) {
        return;
    }
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweep.fromValue = fromValue;
    sweep.toValue = toValue;
    sweep.duration = kSweepDuration;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (current) {
        // TRAP: carry the running sweep's phase over, or the retargeted band
        // snaps back to the left edge. The phase is elapsed time plus the
        // previous carry-over — animationForKey: returns a copy that preserves
        // timeOffset, so dropping it would lose the phase on every reinstall
        // after the first. beginTime is 0 until the first transaction commit
        // stamps it; treat elapsed as 0 then.
        CFTimeInterval now = [_shimmer convertTime:CACurrentMediaTime() fromLayer:nil];
        CFTimeInterval elapsed = current.beginTime > 0 ? MAX(now - current.beginTime, 0) : 0;
        sweep.timeOffset = fmod(elapsed + current.timeOffset, sweep.duration);
    }
    [_shimmer addAnimation:sweep forKey:@"sweep"];
}

#pragma mark - Determinate progress

// The next ease's length: deliberately shorter than the gap between samples,
// so the fill arrives promptly and then holds at the reported value instead of
// still gliding when the next one lands. Half the last gap, capped — providers
// report around 1 Hz, so this settles in well under half a second and rests
// for the remainder.
- (CFTimeInterval)nextEaseDuration {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval gap = _lastProgressAt > 0 ? now - _lastProgressAt : 0;
    _lastProgressAt = now;
    if (gap <= 0) {
        return 0.25; // first sample: no cadence to go on yet
    }
    return MIN(MAX(gap * 0.5, 0.12), 0.45);
}

- (void)setProgress:(float)fraction inBounds:(CGRect)bounds {
    if (!_host) {
        return;
    }
    _progress = fraction;
    CGFloat fillWidth = fraction > 0 ? bounds.size.width * MIN(1.0f, fraction) : 0;
    if (fraction < 0 || fillWidth < 1) {
        [_fill removeFromSuperlayer];
        _fill = nil;
        _lastProgressAt = 0;
        [self layoutInBounds:bounds]; // hand the whole width back to the shimmer
        return;
    }
    if (!_fill) {
        CAGradientLayer *fill = [CAGradientLayer layer];
        fill.contentsScale = _contentsScale;
        fill.startPoint = CGPointMake(0, 0.5);
        fill.endPoint = CGPointMake(1, 0.5);
        // Left-anchored: setting the frame then moves only the width, so the
        // eased growth runs from the left edge instead of from the centre.
        fill.anchorPoint = CGPointMake(0, 0.5);
        fill.colors = [self fillColors];
        // Above the track, below the shimmer, so the sweep still reads as it
        // leaves the front. With the sweep already ended there is nothing to
        // sit below.
        if (_shimmerClip) {
            [_host insertSublayer:fill below:_shimmerClip];
        }
        else {
            [_host addSublayer:fill];
        }
        _fill = fill;
    }
    // The fill is laid out there and nowhere else, so a resize mid-download
    // moves it with the rest of the control rather than at the next sample.
    [self layoutInBounds:bounds animatedOver:[self nextEaseDuration]];
}

@end
