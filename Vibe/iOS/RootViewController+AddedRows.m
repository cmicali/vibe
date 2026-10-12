//
//  RootViewController+AddedRows.m
//  Vibe (iOS)
//

#import "RootViewControllerInternal.h"

// An Add in the Files tab changes nothing on its own screen, so its rows say
// what happened: they lift when asked for, fly into the Playlist tab when the
// tracks land, and set back down when nothing did (all already there, or a
// folder with no songs directly inside). Append settlements or a superseding
// open release the rows. check_consistency reports stranded lifts (liftedRowTimes).
static const NSTimeInterval kRowLiftDuration = 0.25;
static const NSTimeInterval kRowFlightDuration = 0.7;
static const NSTimeInterval kRowFlightStagger = 0.07;
static const CGFloat kLiftedRowScale = 1.03;
static const CGFloat kLandedRowScale = 0.1;

@implementation RootViewController (AddedRows)

- (void)liftAddedRows:(NSArray<UIView *> *)rows {
    if (rows.count == 0) {
        return;
    }
    if (!_liftedRowBatches) {
        _liftedRowBatches = [NSMutableArray array];
        _liftedRowBatchTimes = [NSMutableArray array];
    }
    [_liftedRowBatches addObject:rows];
    [_liftedRowBatchTimes addObject:@(CACurrentMediaTime())];
    for (UIView *row in rows) {
        row.frame = [self.view convertRect:row.frame fromView:nil];
        row.userInteractionEnabled = NO;
        row.layer.shadowOpacity = 0.25f;
        row.layer.shadowRadius = 12;
        row.layer.shadowOffset = CGSizeMake(0, 4);
        // Without a path the shadow is re-derived from the snapshot's pixels
        // on every frame of the flight.
        row.layer.shadowPath = [UIBezierPath bezierPathWithRect:row.bounds].CGPath;
        [self.view addSubview:row];
    }
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:kRowLiftDuration delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            for (UIView *row in rows) {
                row.transform = CGAffineTransformMakeScale(kLiftedRowScale, kLiftedRowScale);
            }
        } completion:nil];
    }
}

- (NSArray<NSNumber *> *)liftedRowTimes {
    return [_liftedRowBatchTimes copy] ?: @[];
}

- (void)settleEveryLiftedRowUnlanded {
    for (NSArray<UIView *> *rows in [_liftedRowBatches copy]) {
        [self settleLiftedRows:rows landed:NO];
    }
}

- (void)settleLiftedRows:(NSArray<UIView *> *)rows landed:(BOOL)landed {
    NSUInteger index = [_liftedRowBatches indexOfObjectIdenticalTo:rows];
    if (index == NSNotFound) {
        return;   // already settled
    }
    CFTimeInterval liftedAt = _liftedRowBatchTimes[index].doubleValue;
    [_liftedRowBatches removeObjectAtIndex:index];
    [_liftedRowBatchTimes removeObjectAtIndex:index];
    CGPoint target = CGPointZero;
    if (!landed || UIAccessibilityIsReduceMotionEnabled() || ![self getPlaylistTabCenter:&target]) {
        [UIView animateWithDuration:0.2 animations:^{
            for (UIView *row in rows) {
                row.transform = CGAffineTransformIdentity;
                row.alpha = 0;
            }
        } completion:^(BOOL finished) {
            [rows makeObjectsPerformSelector:@selector(removeFromSuperview)];
        }];
        if (landed) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
        return;
    }
    // A local Add lands within a frame or two: the flight waits out the lift,
    // or it would cut the lift short and start with a jump.
    NSTimeInterval wait = MAX(0, liftedAt + kRowLiftDuration - CACurrentMediaTime());
    // A UIKit animation, not a CAAnimation added to the layer. An
    // iPhone caps an app's own CAAnimations at 60 Hz unless its Info.plist
    // opts out, while UIKit's run at the display's rate, so on a 120 Hz
    // phone the hand-built flight stuttered beside the swipe it followed.
    UIViewKeyframeAnimationOptions options = UIViewKeyframeAnimationOptionCalculationModeCubic
            | (UIViewKeyframeAnimationOptions)UIViewAnimationOptionCurveEaseInOut;
    CGFloat midScale = (kLiftedRowScale + kLandedRowScale) / 2;
    [rows enumerateObjectsUsingBlock:^(UIView *row, NSUInteger i, BOOL *stop) {
        // Across, then down into the tab: the midpoint of the curve whose
        // control point is the tab's column at the row's height.
        CGPoint start = row.center;
        CGPoint mid = CGPointMake(0.25 * start.x + 0.75 * target.x, 0.75 * start.y + 0.25 * target.y);
        [UIView animateKeyframesWithDuration:kRowFlightDuration
                                       delay:wait + (NSTimeInterval)i * kRowFlightStagger
                                     options:options
                                  animations:^{
            [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.5 animations:^{
                row.center = mid;
                row.transform = CGAffineTransformMakeScale(midScale, midScale);
            }];
            [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{
                row.center = target;
                row.transform = CGAffineTransformMakeScale(kLandedRowScale, kLandedRowScale);
            }];
            [UIView addKeyframeWithRelativeStartTime:0.7 relativeDuration:0.3 animations:^{
                row.alpha = 0;
            }];
        } completion:^(BOOL finished) {
            [row removeFromSuperview];
            if (i == 0) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            }
        }];
    }];
}

@end
