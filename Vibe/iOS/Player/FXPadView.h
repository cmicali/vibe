//
//  FXPadView.h
//  Vibe (iOS)
//
//  The card's FX pad: the FX capsule at rest, a square pad under a finger.
//  It draws and reports normalized positions from the press point only; what
//  the axes mean is the model's (PlaybackController.setFXPadPosition:engaged:
//  over AudioFXMath.h), and the geometry's rationale is Player/CLAUDE.md's.
//  OutputRouteView's twin: the cell places and styles it, the controller
//  wires its delegate.
//

#import <UIKit/UIKit.h>

@class FXPadView;

NS_ASSUME_NONNULL_BEGIN

@protocol FXPadViewDelegate <NSObject>
// The finger moved, or landed (`engaged` YES at 0,0) or lifted (`engaged`
// NO). Positions are normalized: x 0..1 left to right, y 0..1 bottom to top.
// The card holds the pager still for the duration exactly as it does for a
// scrub, and releases it on the lift — including the lift a recycled cell
// synthesizes (cancelInteraction).
- (void)fxPadView:(FXPadView *)view didChangePosition:(CGPoint)position engaged:(BOOL)engaged;
@end

@interface FXPadView : UIView

@property (nonatomic, weak) id<FXPadViewDelegate> delegate;

// The room the pad may grow into from the capsule's bottom-left corner: to
// the right and upward, in points. The cell restates it from its safe area on
// every layout; the pad's side is the smaller of the two and its own cap.
@property (nonatomic) CGSize padExtent;

// The touch that owns the pad, for the pager to yield to the way it yields to
// the scrubber's pan: the pager's pan requires it to fail.
@property (nonatomic, readonly) UIGestureRecognizer *pressRecognizer;

// Whether a finger holds the pad. Ordinary readonly state the debug channel
// reports.
@property (nonatomic, readonly, getter=isEngaged) BOOL engaged;

// Ends a hold as a lift would, delegate call included: a recycled cell must
// not leave effects engaged and the pager locked. A no-op when not engaged.
- (void)cancelInteraction;

@end

NS_ASSUME_NONNULL_END
