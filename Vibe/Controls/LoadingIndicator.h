//
//  LoadingIndicator.h
//  Vibe
//
//  The loading control, owned by both waveform views and — through
//  LoadingIndicatorView — both platforms' row number gutters. It is pure
//  CALayer work with no view, no window and no trait collection, which is why
//  it can be one object rather than one per platform — it was two, and they
//  drifted: the mac grew the eased fill and the clipped sweep while the iOS
//  copy kept an older shimmer with a separate un-eased bar bolted on.
//
//  IT IS ONE CONTROL ACROSS TWO STYLES AND BOTH MODES, not a shimmer with a
//  progress bar added: a faint full-width track, a solid filled head over
//  [0, fraction] whose last few points fade out, and the shimmer band sweeping
//  ONLY the unfilled remainder. Indeterminate is simply the case where nothing
//  is filled, so the sweep spans the whole width. That is why every part of it
//  is placed by layoutInBounds:animatedOver: and nowhere else, and why a
//  negative fraction reverts cleanly. The style changes metrics, not
//  structure — LoadingIndicatorMath.h.
//
//  Main thread only, like the views that own it.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#import "LoadingIndicatorMath.h"
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

@interface LoadingIndicator : NSObject

// Builds the layer set and adds it to hostLayer, in indeterminate mode.
- (instancetype)initInLayer:(CALayer *)hostLayer
                      style:(VibeLoadingIndicatorStyle)style
                     isDark:(BOOL)isDark
              contentsScale:(CGFloat)contentsScale;

// Pulls every layer back out of the host.
- (void)removeFromHost;

// Ends the indeterminate half — the track and the sweeping band — while
// KEEPING any determinate fill, and answers whether that fill is still there.
// NO means nothing is left and the owner should drop the object.
//
// This is what waveform data arriving means on the iOS scrubber: a disk-cached
// waveform can land while the provider is still materializing the audio, so
// the fill riding over the drawn waveform is the only remaining sign of the
// download. It comes down later with its monitor, via setProgress: with a
// negative fraction. It has no row equivalent — a row's owner toggles the
// whole control.
- (BOOL)endSweepKeepingFill;

// Places the whole control for these bounds. Pass 0 for a resize or a state
// change; setProgress: passes its own ease.
- (void)layoutInBounds:(CGRect)bounds;

// Determinate download progress: the track fills from the left as the
// provider materializes the file. A negative fraction removes the fill and
// hands the whole width back to the shimmer. Providers report about once a
// second and irregularly, so the fill EASES to each value over roughly the
// last interval rather than snapping — Core Animation retargets from the
// presentation value, so a sample landing early redirects the motion instead
// of jumping, and the fill never runs past what was reported, leaving a
// stalled download parked rather than creeping ahead of the truth.
- (void)setProgress:(float)fraction inBounds:(CGRect)bounds;

// Overrides the appearance-derived black/white base. The mac playlist forces
// white in the number gutter, as it does for the EQ bars beside it. nil
// returns to the appearance default. The waveform sites never set it.
@property (nonatomic, strong, nullable) VibeColor *colorOverride;

// Re-asserts the palette after a light/dark flip, and the backing scale after
// a display change.
- (void)updateColorsForDark:(BOOL)isDark;
- (void)updateContentsScale:(CGFloat)contentsScale;

@end

NS_ASSUME_NONNULL_END
