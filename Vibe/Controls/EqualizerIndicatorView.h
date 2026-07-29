//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row indicator: five vertically-centered pill bars (the app
//  icon's waveform) that grow and shrink independently. Plain CALayers driven
//  by repeating keyframe animations — composited on the render server, zero
//  per-frame CPU in the app (an animated-GIF NSImageView re-decodes frames on
//  the CPU every tick, even when clipped offscreen).
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Bar color follows the view's own effectiveAppearance (white in dark, black
// in light) and re-resolves on appearance change — a snapshot taken while the
// cell was detached from the table would resolve against the app/system
// appearance instead of the window's forced appearance.
@interface EqualizerIndicatorView : NSView

// YES: bars bounce (track playing). NO: bars hold a static pose (paused).
@property (nonatomic) BOOL animating;

// Overrides the appearance-derived bar color (the playlist's artwork-derived
// accent). nil returns to the white/black appearance default.
@property (nonatomic, strong, nullable) NSColor *barColor;

@end

NS_ASSUME_NONNULL_END
