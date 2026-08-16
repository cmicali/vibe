//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row indicator: five vertically centered pill bars, the app
//  icon's waveform, that grow and shrink independently. They are plain
//  CALayers driven by repeating keyframe animations, composited on the render
//  server, so the app spends no CPU per frame. An animated-GIF NSImageView, by
//  contrast, re-decodes frames on the CPU every tick, even when clipped
//  offscreen.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The bar color follows the view's own effectiveAppearance — white in dark
// mode, black in light — and re-resolves on an appearance change. A snapshot
// taken while the cell was detached from the table would resolve against the
// app or system appearance rather than the window's forced appearance.
@interface EqualizerIndicatorView : NSView

// YES makes the bars bounce, for a playing track. NO holds them in a static
// pose, for a paused one.
@property (nonatomic) BOOL animating;

// Overrides the appearance-derived bar color with the playlist's
// artwork-derived accent. nil returns to the white or black appearance default.
@property (nonatomic, strong, nullable) NSColor *barColor;

@end

NS_ASSUME_NONNULL_END
