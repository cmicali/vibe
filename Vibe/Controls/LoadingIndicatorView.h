//
//  LoadingIndicatorView.h
//  Vibe
//
//  The row gutter's host for LoadingIndicator's row style: the small loading
//  bar a playlist or library row shows while a provider transfer is really
//  running for its file. SHARED for the same reason EqualizerIndicatorView is
//  — the bar is the app's transferring marker and both platforms draw the
//  same one in the same 16pt number gutter. Only the superclass, the layout
//  and appearance hooks differ.
//
//  Much cheaper than the equalizer, and the reason belongs here: the sweep is
//  one repeating CABasicAnimation on one layer. There is no display link, no
//  timer, no app-side per-frame callback and no path rebuild — the whole
//  thing runs on the compositor. What it still must not do is hold a live
//  animation for a row nobody can see, so active goes NO on cell reuse, on
//  hiding, and on detachment from a window; the row wiring owns that.
//

#import "PlatformTypes.h"

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

#if TARGET_OS_OSX
@interface LoadingIndicatorView : NSView
#else
@interface LoadingIndicatorView : UIView
#endif

// NO tears the control down entirely: no layers, no animation, nothing
// retained. Defaults to NO.
@property (nonatomic, getter=isActive) BOOL active;

// <0 is indeterminate — the shimmer owns the whole width. >=0 fills. A
// control that has never been given a fraction is indeterminate.
@property (nonatomic) float progress;

// Overrides the appearance-derived colour, as EqualizerIndicatorView.barColor
// does. The mac playlist forces white in the number gutter.
@property (nonatomic, strong, nullable) VibeColor *barColor;

@end

NS_ASSUME_NONNULL_END
