//
// Created by Christopher Micali on 1/3/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>
// AudioWaveform.h brings C++ types in, so import this header from .mm files
// only.
#import "AudioWaveform.h"

NS_ASSUME_NONNULL_BEGIN

// One shared fallback for the backing scale before a real answer exists, as
// for a view not yet in a window or a layer whose contentsScale is still
// unset. 2 means Retina, which is overwhelmingly the common case.
static const CGFloat kVibeDefaultBackingScale = 2;

// The rendering layer's two scale sources. The view asks its window, the
// authority on what the scale should be, and renderers ask a layer they have
// already stamped, guarding the unset-0 case. Both live here, so that the
// fallback cannot drift between sites.
static inline CGFloat VibeBackingScaleForWindow(NSWindow * _Nullable window) {
    return window ? window.backingScaleFactor : kVibeDefaultBackingScale;
}
static inline CGFloat VibeBackingScaleForLayer(CALayer * _Nullable layer) {
    CGFloat scale = layer.contentsScale;
    return scale > 0 ? scale : kVibeDefaultBackingScale;
}

@interface AudioWaveformRenderer : NSObject

@property (assign) BOOL isDark;

// The last played bar index that updateProgress: painted. Layer-array
// renderers — SonicCirrusWaveformRenderer, which owns the bar-layer machinery
// — use it to repaint only the bars between the old and new progress boundary
// rather than every bar. Set it to -1 to force a full repaint, as after the
// played and unplayed colors change in updateColors:.
@property (assign) NSInteger lastProgressBoundary;

@property (strong) CALayer* parentLayer;

+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

// The vertical band, in view coordinates, a click must land in to count as a
// seek. AudioWaveformView queries it on mouseDown, and it is computed from the
// given bounds alone: a pure function rather than per-draw mutable state, so
// each renderer has exactly one band definition. The base is the middle 50% of
// the height, and renderers with a known drawn extent override it.
- (NSRect)seekHitBandForBounds:(NSRect)bounds;

- (void)updateWaveform:(NSRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

// The Convert to FLAC sweep: collapse the bars in the x-fraction span
// [from, to) to the midline and let the shared morph ease them back. The base
// does nothing; the families forward to their morph engine.
- (void)dipBarsFromFraction:(double)from toFraction:(double)to;

// The hover scrubbing affordance: light the waveform's own column at view x to
// full brightness. No separate playhead is drawn, because the waveform is the
// affordance. A negative x clears it. Renderers keep the x, so that a resize
// or a morph rebuild can reposition the highlight; the base implementation
// stores it and does nothing else.
- (void)setHoverHighlightX:(CGFloat)x;
@property (readonly) CGFloat hoverHighlightX; // < 0 when not hovering

@end

NS_ASSUME_NONNULL_END
