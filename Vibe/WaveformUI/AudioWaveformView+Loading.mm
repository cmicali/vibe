//
//  AudioWaveformView+Loading.mm
//  Vibe
//

#import "AudioWaveformView+Loading.h"
#import "AudioWaveformViewInternal.h"
#import "NSView+DarkMode.h"

@implementation AudioWaveformView (Loading)

- (void)showLoadingIndicator {
    if (_loadingLayer) {
        return;
    }
    [self hideEmptyPlaceholder];
    // Collapse any previous track's waveform, so the shimmer stands alone.
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    _loadingProgress = -1;
    _lastLoadingProgressAt = 0;

    // The control's body: one midline track, spanning the whole width. The
    // filled head and the shimmer are both read against it, which is what
    // makes the determinate and indeterminate modes one control rather than
    // two — indeterminate is simply nothing filled yet.
    CALayer *track = [CALayer layer];
    track.contentsScale = VibeBackingScaleForWindow(self.window);
    track.backgroundColor = [self inertMidlineColor];
    [self.layer addSublayer:track];
    _loadingTrackLayer = track;

    CALayer *clip = [CALayer layer];
    clip.contentsScale = VibeBackingScaleForWindow(self.window);
    clip.masksToBounds = YES;
    [self.layer addSublayer:clip];
    _loadingShimmerClip = clip;

    CAGradientLayer *shimmer = [CAGradientLayer layer];
    shimmer.contentsScale = VibeBackingScaleForWindow(self.window);
    shimmer.startPoint = CGPointMake(0, 0.5);
    shimmer.endPoint = CGPointMake(1, 0.5);
    shimmer.colors = [self shimmerColors];
    [clip addSublayer:shimmer];
    _loadingLayer = shimmer;

    // The frame and the sweep both depend on the current bounds, so a helper
    // keeps them in sync when the window resizes, or the small-large layout
    // toggles, mid-load.
    [self layoutLoadingLayer];
}

// Follows the appearance, as the renderer palettes do, because a fixed white
// band is near-invisible on a light background. showLoadingIndicator and
// updateAppearance share it, so that a light-dark flip mid-load recolors the
// live shimmer.
- (NSArray *)shimmerColors {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return @[
            (id)[base colorWithAlphaComponent:0].CGColor,
            (id)[base colorWithAlphaComponent:kUnplayedWaveformAlpha].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

// The inert midline, shared by the loading indicator's unfilled track and
// the empty state's static line — the same element, so the same colour. It
// lands on the unplayed waveform's own baseline, the midline the short bars
// sit on, so the two read as one surface when the waveform replaces it.
- (CGColorRef)inertMidlineColor {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return [base colorWithAlphaComponent:0.275].CGColor;
}

// The filled head, fading out over its last few points so it meets the
// shimmer as a soft front rather than a hard cut.
- (NSArray *)loadingFillColors {
    NSColor *base = self.isDark ? [NSColor whiteColor] : [NSColor blackColor];
    return @[
            (id)[base colorWithAlphaComponent:0.85].CGColor,
            (id)[base colorWithAlphaComponent:0.85].CGColor,
            (id)[base colorWithAlphaComponent:0].CGColor,
    ];
}

// Positions the shimmer band and installs, or reinstalls, its sweep for the
// current bounds.
- (void)layoutLoadingLayer {
    [self layoutLoadingLayerAnimatedOver:0];
}

// duration > 0 eases the parts that track the download's progress; the rest is
// always instant. Resize and state changes pass 0.
- (void)layoutLoadingLayerAnimatedOver:(CFTimeInterval)duration {
    if (!_loadingLayer) {
        return;
    }
    CGFloat width = self.bounds.size.width;
    CGFloat midY = self.bounds.size.height / 2;
    // The shimmer sweeps the *unfilled* remainder only: it is the "still
    // working on this part" half of one control, and the fill is the "this
    // part is done" half. Indeterminate fills nothing, so the sweep spans the
    // whole width exactly as it always has.
    CGFloat fillEnd = _loadingProgress > 0 ? width * MIN(1.0f, _loadingProgress) : 0;
    CGFloat remainder = MAX(width - fillEnd, 0);
    CGFloat bandWidth = MIN(MAX(width * 0.35, 40), MAX(remainder, 1));

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
    if (_loadingProgressLayer && fillEnd > 0) {
        // A soft front, but only as long as there is remainder to fade into:
        // at completion a fixed fade would read as the bar stopping short of
        // the edge rather than as a soft edge.
        static const CGFloat kFrontFadePoints = 14;
        CGFloat fade = MIN(kFrontFadePoints, remainder);
        _loadingProgressLayer.locations = @[ @0, @(MAX(0.0, (fillEnd - fade) / fillEnd)), @1 ];
        _loadingProgressLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2, fillEnd, kMidlineHeight);
    }
    _loadingShimmerClip.frame = CGRectMake(fillEnd, midY - kMidlineHeight / 2, remainder, kMidlineHeight);
    [CATransaction commit];

    // The band's own position is driven by the sweep animation, so its
    // geometry is always set action-free: an implicit animation here would
    // fight that and stall the sweep.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _loadingLayer.frame = CGRectMake(0, 0, bandWidth, kMidlineHeight);
    // Near completion there is no room left to sweep, so the band fades out
    // rather than jittering in a sliver.
    _loadingLayer.opacity = (float)MIN(1.0, remainder / MAX(width * 0.08, 1));
    _loadingTrackLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2, width, kMidlineHeight);
    [CATransaction commit];

    // Reinstall the sweep only when its endpoints actually change. Live resize
    // lands here every frame, and an unconditional remove-and-re-add restarts
    // the 1.2s sweep each time, freezing it at the left edge.
    NSNumber *fromValue = @(-bandWidth / 2);
    NSNumber *toValue = @(remainder + bandWidth / 2);
    CABasicAnimation *current = (CABasicAnimation *)[_loadingLayer animationForKey:@"sweep"];
    if ([current isKindOfClass:CABasicAnimation.class] &&
        [current.fromValue isEqual:fromValue] && [current.toValue isEqual:toValue]) {
        return;
    }
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
    sweep.fromValue = fromValue;
    sweep.toValue = toValue;
    sweep.duration = 1.2;
    sweep.repeatCount = HUGE_VALF;
    sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (current) {
        // Carry the running sweep's phase over, so the retargeted band keeps
        // moving from its current spot rather than snapping to the left edge.
        // The phase is elapsed time plus the previous carry-over: animationForKey:
        // returns a copy that preserves timeOffset, so dropping it here would lose
        // the phase on every reinstall after the first. beginTime is 0 until the
        // first transaction commit stamps it; treat elapsed as 0 then.
        CFTimeInterval now = [_loadingLayer convertTime:CACurrentMediaTime() fromLayer:nil];
        CFTimeInterval elapsed = current.beginTime > 0 ? MAX(now - current.beginTime, 0) : 0;
        sweep.timeOffset = fmod(elapsed + current.timeOffset, sweep.duration);
    }
    [_loadingLayer addAnimation:sweep forKey:@"sweep"];
}

- (void)hideLoadingIndicator {
    [_loadingLayer removeAllAnimations];
    [_loadingLayer removeFromSuperlayer];
    _loadingLayer = nil;
    [_loadingProgressLayer removeFromSuperlayer];
    _loadingProgressLayer = nil;
    [_loadingShimmerClip removeFromSuperlayer];
    _loadingShimmerClip = nil;
    [_loadingTrackLayer removeFromSuperlayer];
    _loadingTrackLayer = nil;
    _loadingProgress = -1;
    _lastLoadingProgressAt = 0;
}

// Determinate download progress under the shimmer, fed by
// DownloadProgressMonitor: the midline fills from the left as the provider
// materializes the file. A negative fraction hides it (back to
// indeterminate); the shimmer keeps sweeping either way, since a stalled
// provider reports no movement.
// The next ease's length: deliberately shorter than the gap between samples,
// so the fill arrives promptly and then holds at the reported value instead
// of still gliding when the next one lands. Half the last gap, capped —
// providers report around 1 Hz, so this settles in well under half a second
// and rests for the remainder.
- (CFTimeInterval)loadingProgressAnimationDuration {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFTimeInterval gap = _lastLoadingProgressAt > 0 ? now - _lastLoadingProgressAt : 0;
    _lastLoadingProgressAt = now;
    if (gap <= 0) {
        return 0.25; // first sample: no cadence to go on yet
    }
    return MIN(MAX(gap * 0.5, 0.12), 0.45);
}

- (void)setLoadingProgress:(float)fraction {
    if (!_loadingLayer) {
        return;
    }
    _loadingProgress = fraction;
    CGFloat width = self.bounds.size.width;
    CGFloat fillWidth = fraction > 0 ? width * MIN(1.0f, fraction) : 0;
    if (fraction < 0 || fillWidth < 1) {
        [_loadingProgressLayer removeFromSuperlayer];
        _loadingProgressLayer = nil;
        [self layoutLoadingLayer]; // hand the whole width back to the shimmer
        return;
    }
    if (!_loadingProgressLayer) {
        CAGradientLayer *fill = [CAGradientLayer layer];
        fill.contentsScale = VibeBackingScaleForWindow(self.window);
        fill.startPoint = CGPointMake(0, 0.5);
        fill.endPoint = CGPointMake(1, 0.5);
        // Left-anchored: setting the frame then moves only the width, so the
        // eased growth runs from the left edge instead of from the centre.
        fill.anchorPoint = CGPointMake(0, 0.5);
        fill.colors = [self loadingFillColors];
        // Above the track, below the shimmer, so the sweep still reads as it
        // leaves the front.
        [self.layer insertSublayer:fill below:_loadingShimmerClip];
        _loadingProgressLayer = fill;
    }
    // Providers report about once a second and irregularly, so a snap to each
    // value reads as a stalled bar that lurches. Ease to the reported value
    // over roughly the last interval instead: Core Animation retargets from
    // the presentation value, so a sample that lands early redirects the
    // motion rather than jumping. It never runs past what was reported, so a
    // stalled download parks rather than creeping ahead of the truth. The fill
    // is laid out there and nowhere else, so a resize mid-download moves it
    // with the rest of the control rather than at the next sample.
    [self layoutLoadingLayerAnimatedOver:[self loadingProgressAnimationDuration]];
}

- (void)showEmptyPlaceholder {
    if (_placeholderLayer) {
        return;
    }
    [self hideLoadingIndicator];
    [self resetWaveformContentState];
    if (_currentWaveformRenderer) {
        [self drawWaveform];
    }

    CALayer *line = [CALayer layer];
    line.contentsScale = VibeBackingScaleForWindow(self.window);
    [self.layer addSublayer:line];
    _placeholderLayer = line;

    [self updatePlaceholderColor];
    [self layoutPlaceholderLayer];
}

// The same midline the loading indicator uses, full-width and static: the
// empty state is that control at rest, so it shares the height and colour.
- (void)layoutPlaceholderLayer {
    if (!_placeholderLayer) {
        return;
    }
    CGFloat midY = self.bounds.size.height / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _placeholderLayer.frame = CGRectMake(0, midY - kMidlineHeight / 2,
                                         self.bounds.size.width, kMidlineHeight);
    [CATransaction commit];
}

- (void)updatePlaceholderColor {
    _placeholderLayer.backgroundColor = [self inertMidlineColor];
}

- (void)hideEmptyPlaceholder {
    [_placeholderLayer removeFromSuperlayer];
    _placeholderLayer = nil;
}

// The appearance-dependent colours of all three loading layers, re-asserted
// when the window flips between light and dark. Split from the view's own
// updateAppearance so the layer set and its colours stay in one file.
- (void)updateLoadingColors {
    if (_loadingLayer) {
        _loadingLayer.colors = [self shimmerColors];
    }
    _loadingTrackLayer.backgroundColor = [self inertMidlineColor];
    _loadingProgressLayer.colors = [self loadingFillColors];
}

@end
