//
//  EqualizerIndicatorView.h
//  Vibe
//
//  The playing-row indicator: five vertically centered pill bars, the app
//  icon's waveform, that grow and shrink independently. Five retained CALayers
//  represent them. Snapshot updates retarget only materially changed vertical
//  transforms; no path is rebuilt or rasterized on each displayed frame.
//
//  SHARED, because the bars ARE the app's playing marker and both platforms
//  must draw the same ones — the mac playlist table's number column and the
//  iOS library row's. Everything that gives the indicator its character is
//  QuartzCore and identical on both: the pill layers, the collapsed-to-dots
//  idle pose, the snapshot poller capped at 30 Hz, and explicit scalar
//  animations for material level changes. Only the superclass, layout
//  and appearance hooks, and alpha property differ.
//

#import "EqualizerLevelSource.h"
#import "PlatformTypes.h"

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// The bar color follows the view's own appearance — white in dark mode, black
// in light — and re-resolves on an appearance change. A snapshot taken while
// the view was detached would resolve against the app or system appearance
// rather than the window's forced one.
#if TARGET_OS_OSX
@interface EqualizerIndicatorView : NSView
#else
@interface EqualizerIndicatorView : UIView
#endif

// These two facts are deliberately separate. Audio output means the graph has
// a playing source node or a tracked outgoing fade; presentation visibility
// means the platform has established that this row and its surface are
// materially exposed. Both default to NO, and both must be YES before the view
// asks for level production or creates its snapshot poller.
@property (nonatomic) BOOL audioOutputActive;
@property (nonatomic) BOOL presentationVisible;

// The derived state after source, attachment, and nonempty geometry have also
// been checked. Useful for live diagnostics without exposing debug-only API in
// a shipping header.
@property (nonatomic, readonly, getter=isAudioReactive) BOOL audioReactive;

// Overrides the appearance-derived bar color. nil returns to the white or
// black default.
@property (nonatomic, strong, nullable) VibeColor *barColor;

// Both platforms set this to the model that owns their player. A missing source
// is inactive, never a request for synthetic fallback animation.
//
// Weak: the source is the app's playback model and outlives every row.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;

@end

NS_ASSUME_NONNULL_END
