//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row indicator: five vertically-centered pill bars (the app
//  icon's waveform) that grow and shrink independently. Replaces the old
//  animated GIFs (equi-white/equi-black): NSImageView re-decodes GIF frames
//  on the CPU for every animation tick (~5% of a core, and it keeps ticking
//  even when the view is clipped offscreen). These bars are plain CALayers
//  driven by repeating keyframe animations — composited on the render
//  server, zero per-frame CPU in the app.
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

@end

NS_ASSUME_NONNULL_END
