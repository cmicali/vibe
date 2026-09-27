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
//  Much cheaper than the equalizer: the row style's only motion, the pulse, is
//  one repeating CABasicAnimation on one layer, run by the compositor — no
//  display link, timer, per-frame callback or path rebuild. It still must not
//  hold a live animation for a row nobody can see, so active goes NO on cell
//  reuse and on hiding — the row wiring owns those — and the view drops it
//  itself on leaving its window, which is what scroll-out is; the table
//  re-configures a row it scrolls back in.
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

// <0 is indeterminate (the pulse); >=0 fills. A control never given a
// fraction is indeterminate.
@property (nonatomic) float progress;

// Overrides the appearance-derived colour, as EqualizerIndicatorView.barColor
// does. The mac playlist forces white in the number gutter.
@property (nonatomic, strong, nullable) VibeColor *barColor;

@end

NS_ASSUME_NONNULL_END
