//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row equalizer bars. Replaces the old animated GIFs
//  (equi-white/equi-black): NSImageView re-decodes GIF frames on the CPU for
//  every animation tick (~5% of a core, and it keeps ticking even when the
//  view is clipped offscreen). These bars are plain CALayers driven by
//  repeating keyframe animations — composited on the render server, zero
//  per-frame CPU in the app.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface EqualizerIndicatorView : NSView

@property (nonatomic, strong) NSColor *color;

// YES: bars bounce (track playing). NO: bars hold a static pose (paused).
@property (nonatomic) BOOL animating;

@end

NS_ASSUME_NONNULL_END
