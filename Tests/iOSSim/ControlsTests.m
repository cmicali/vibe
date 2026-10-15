// The shared controls on UIKit: only what differs from the mac. The rules
// under them are VibeTests' (EqualizerActivityRulesTests,
// LoadingIndicatorMathTests). Here the UIKit hooks feed them: didMoveToWindow,
// hidden, alpha and the trait registrations.

#import "IOSSimTestCase.h"

#import "EqualizerIndicatorView.h"
#import "LoadingIndicatorView.h"

@interface ControlsTests : IOSSimTestCase
@end

@implementation ControlsTests

static BOOL ColorsEqual(CGColorRef a, UIColor *b) {
    return CGColorEqualToColor(a, b.CGColor);
}

#pragma mark - EqualizerIndicatorView

- (EqualizerIndicatorView *)equalizerWithSource:(CountingLevelSource *)source {
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:CGRectMake(20, 200, 16, 14)];
    view.levelSource = source;
    view.audioOutputActive = YES;
    view.presentationVisible = YES;
    return view;
}

// Window attachment is UIKit's didMoveToWindow. Demand follows it both ways.
- (void)testDemandStartsInAWindowAndEndsOutOfIt {
    CountingLevelSource *source = [[CountingLevelSource alloc] init];
    EqualizerIndicatorView *view = [self equalizerWithSource:source];
    [view layoutIfNeeded];
    XCTAssertEqual(source.consumers, 0, @"detached views poll nothing");
    [self.window addSubview:view];
    [view layoutIfNeeded];
    XCTAssertEqual(source.consumers, 1);
    [view removeFromSuperview];
    XCTAssertEqual(source.consumers, 0);
}

// UIView.hidden is the iOS shell's way to drop a row's marker.
- (void)testHidingTheViewBalancesDemand {
    CountingLevelSource *source = [[CountingLevelSource alloc] init];
    EqualizerIndicatorView *view = [self equalizerWithSource:source];
    [self.window addSubview:view];
    [view layoutIfNeeded];
    XCTAssertEqual(source.consumers, 1);
    view.hidden = YES;
    XCTAssertEqual(source.consumers, 0);
    view.hidden = NO;
    XCTAssertEqual(source.consumers, 1);
    view.presentationVisible = NO;
    XCTAssertEqual(source.consumers, 0);
    view.presentationVisible = YES;
    view.audioOutputActive = NO;
    XCTAssertEqual(source.consumers, 0);
    [view removeFromSuperview];
}

- (void)testASourceSwapReleasesTheOldOneFirst {
    CountingLevelSource *first = [[CountingLevelSource alloc] init];
    CountingLevelSource *second = [[CountingLevelSource alloc] init];
    EqualizerIndicatorView *view = [self equalizerWithSource:first];
    [self.window addSubview:view];
    [view layoutIfNeeded];
    view.levelSource = second;
    XCTAssertEqual(first.consumers, 0);
    XCTAssertEqual(second.consumers, 1);
    view.levelSource = nil;
    XCTAssertEqual(second.consumers, 0, @"a nil source is inactive");
    [view removeFromSuperview];
}

- (void)testEmptyGeometryRunsNothing {
    CountingLevelSource *source = [[CountingLevelSource alloc] init];
    EqualizerIndicatorView *view = [self equalizerWithSource:source];
    view.frame = CGRectZero;
    [self.window addSubview:view];
    [view layoutIfNeeded];
    XCTAssertEqual(source.consumers, 0);
    [view removeFromSuperview];
}

// The iOS spelling of the light dim.
- (void)testPausedDimsTheAlphaOnly {
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 16, 14)];
    XCTAssertEqualWithAccuracy(view.alpha, 0.8, 1e-6);
    view.audioOutputActive = YES;
    XCTAssertEqualWithAccuracy(view.alpha, 1.0, 1e-6);
    view.audioOutputActive = NO;
    XCTAssertEqualWithAccuracy(view.alpha, 0.8, 1e-6);
}

// The trait registration is the iOS twin of the mac's appearance callback.
- (void)testTheBarsFollowTheTraitsAndAnOverride {
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:CGRectMake(0, 300, 16, 14)];
    [self.window addSubview:view];
    view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [view layoutIfNeeded];
    [self spin];
    NSArray<CALayer *> *bars = view.layer.sublayers;
    XCTAssertEqual(bars.count, 5u);
    XCTAssertTrue(ColorsEqual(bars.firstObject.backgroundColor, UIColor.whiteColor));
    view.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    [view layoutIfNeeded];
    [self spin];
    XCTAssertTrue(ColorsEqual(bars.firstObject.backgroundColor, UIColor.blackColor));
    view.barColor = UIColor.redColor;
    XCTAssertTrue(ColorsEqual(bars.lastObject.backgroundColor, UIColor.redColor));
    [view removeFromSuperview];
}

#pragma mark - LoadingIndicatorView

- (void)testActiveBuildsLayersAndInactiveTearsThemDown {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:CGRectMake(0, 0, 16, 4)];
    XCTAssertFalse(view.isActive);
    XCTAssertEqual(view.layer.sublayers.count, 0u);
    view.active = YES;
    XCTAssertGreaterThan(view.layer.sublayers.count, 0u);
    view.active = NO;
    XCTAssertEqual(view.layer.sublayers.count, 0u);
    XCTAssertLessThan(view.progress, 0, @"inactive forgets its fraction");
}

// Scroll-out is leaving the window, and the view drops itself.
- (void)testLeavingTheWindowDeactivates {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:CGRectMake(0, 300, 16, 4)];
    [self.window addSubview:view];
    view.active = YES;
    view.progress = 0.5f;
    [view removeFromSuperview];
    XCTAssertFalse(view.isActive);
    XCTAssertEqual(view.layer.sublayers.count, 0u);
}

// Activated detached, the bar takes the fallback scale; joining a window
// takes the screen's.
- (void)testJoiningAWindowTakesTheScreensScale {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:CGRectMake(0, 300, 16, 4)];
    view.active = YES;
    [self.window addSubview:view];
    [view layoutIfNeeded];
    CGFloat scale = self.window.windowScene.screen.scale;
    BOOL matched = NO;
    for (CALayer *layer in view.layer.sublayers) {
        matched = matched || layer.contentsScale == scale;
    }
    XCTAssertTrue(matched, @"no layer at the screen's scale %f", scale);
    [view removeFromSuperview];
}

@end
