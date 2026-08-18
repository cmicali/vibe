//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row indicator: five vertically centered pill bars, the app
//  icon's waveform, that grow and shrink independently. They are plain
//  CALayers driven either by a levelSource's real band levels or, with none, by
//  repeating keyframe animations composited on the render server. An
//  animated-GIF image view, by contrast, re-decodes frames on the CPU every
//  tick, even when clipped offscreen.
//
//  SHARED, because the bars ARE the app's playing marker and both platforms
//  must draw the same ones — the mac playlist table's number column and the
//  iOS library row's. Everything that gives the indicator its character is
//  QuartzCore and identical on both: the pill layers, the collapsed-to-dots
//  paused pose, the per-bar keyframe tables, and the deliberately mismatched
//  durations that keep the combined pattern from visibly repeating. Only the superclass, the
//  layout and appearance hooks and the alpha property differ, which is the
//  whole of the #if in the implementation.
//

#import "PlatformTypes.h"

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// Where the bars get real audio, when they have it. One method, so this shared
// control gains no dependency on Audio/ — the source is whatever holds a
// player, and on iOS that is PlaybackController.
@protocol EqualizerLevelSource <NSObject>

// Fills `out` with `count` levels in 0..1. NO means there is nothing to show
// right now and `out` is untouched, which the indicator reads as "settle", not
// as silence.
- (BOOL)copyEqualizerLevels:(float *)out count:(NSUInteger)count;

// Whether this indicator is consuming levels at all, so a source can keep the
// analysis it feeds them from switched off when nothing will read it. Sent only
// on a change and exactly balanced — one NO per YES, the last of them from
// dealloc — so a source may simply count its consumers.
//
// It is demand, not visibility: the indicator says what it needs, and only the
// source knows what producing it costs. A source with nothing to switch off can
// implement this as a no-op.
- (void)equalizerLevelsWanted:(BOOL)wanted;

@end

// The bar color follows the view's own appearance — white in dark mode, black
// in light — and re-resolves on an appearance change. A snapshot taken while
// the view was detached would resolve against the app or system appearance
// rather than the window's forced one.
#if TARGET_OS_OSX
@interface EqualizerIndicatorView : NSView
#else
@interface EqualizerIndicatorView : UIView
#endif

// YES makes the bars bounce, for a playing track. NO collapses them to a row
// of dots — each bar squashed to its own width — for a paused one.
@property (nonatomic) BOOL animating;

// Overrides the appearance-derived bar color with the playlist's
// artwork-derived accent. nil returns to the white or black default.
@property (nonatomic, strong, nullable) VibeColor *barColor;

// Set this and the bars follow the audio instead of the canned keyframes,
// sampling per displayed frame while animating. Both platforms set it — iOS
// from PlaybackController, macOS from MainPlayerController — and nil keeps the
// keyframes, which is any row built before the model reaches it.
//
// Weak: the source is the app's playback model and outlives every row.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;

@end

NS_ASSUME_NONNULL_END
