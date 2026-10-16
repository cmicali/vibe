//
//  LoadingIndicatorTests.m
//  VibeTests
//
//  The loading control's layer tree and its compositor animations, and the
//  row gutter's host for it. No window server: the layers are never rendered,
//  so these read the model tree the compositor would be handed.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "LoadingIndicator.h"
#import "LoadingIndicatorView.h"

static BOOL ColorIs(CGColorRef color, NSColor *base, CGFloat alpha) {
    return CGColorEqualToColor(color, [base colorWithAlphaComponent:alpha].CGColor);
}

@interface LoadingIndicatorTests : XCTestCase
@end

@implementation LoadingIndicatorTests {
    CALayer *_host;
}

- (void)setUp {
    [super setUp];
    _host = [CALayer layer];
    _host.bounds = CGRectMake(0, 0, 200, 20);
}

- (LoadingIndicator *)indicator:(VibeLoadingIndicatorStyle)style {
    return [[LoadingIndicator alloc] initInLayer:_host style:style isDark:YES contentsScale:2];
}

- (CALayer *)track {
    return _host.sublayers.firstObject;
}

#pragma mark - Row style

- (void)testTheRowStyleIsATrackThatPulsesUntilAPointOfFillExists {
    LoadingIndicator *row = [self indicator:VibeLoadingIndicatorStyleRow];
    XCTAssertEqual(_host.sublayers.count, 1u, @"no shimmer in a gutter");
    CGRect bounds = CGRectMake(0, 0, 16, 12);
    [row layoutInBounds:bounds];
    XCTAssertNotNil([self.track animationForKey:@"pulse"]);
    XCTAssertEqualWithAccuracy(self.track.frame.size.height, 3, 1e-9);
    XCTAssertEqualWithAccuracy(CGRectGetMidY(self.track.frame), 6, 1e-9);

    [row setProgress:0 inBounds:bounds];
    XCTAssertNotNil([self.track animationForKey:@"pulse"], @"zero keeps pulsing");
    [row setProgress:0.05f inBounds:bounds];
    XCTAssertEqual(_host.sublayers.count, 1u, @"0.8pt is not a fill");
    XCTAssertNotNil([self.track animationForKey:@"pulse"]);

    [row setProgress:0.5f inBounds:bounds];
    XCTAssertEqual(_host.sublayers.count, 2u);
    XCTAssertNil([self.track animationForKey:@"pulse"], @"a real fill retires the pulse");
    CALayer *fill = _host.sublayers.lastObject;
    XCTAssertEqualWithAccuracy(fill.frame.size.width, 8, 1e-9);
    XCTAssertEqualWithAccuracy(fill.frame.origin.x, 0, 1e-9);

    [row setProgress:-1 inBounds:bounds];
    XCTAssertEqual(_host.sublayers.count, 1u, @"negative removes the fill");
    XCTAssertNotNil([self.track animationForKey:@"pulse"]);
}

- (void)testTheFillNeverRunsPastTheBounds {
    LoadingIndicator *row = [self indicator:VibeLoadingIndicatorStyleRow];
    [row setProgress:3 inBounds:CGRectMake(0, 0, 16, 12)];
    XCTAssertEqualWithAccuracy(_host.sublayers.lastObject.frame.size.width, 16, 1e-9);
}

- (void)testRemovingFromTheHostLeavesNothing {
    LoadingIndicator *row = [self indicator:VibeLoadingIndicatorStyleRow];
    [row setProgress:0.5f inBounds:CGRectMake(0, 0, 16, 12)];
    [row removeFromHost];
    XCTAssertEqual(_host.sublayers.count, 0u);
}

#pragma mark - Waveform style

- (void)testTheWaveformStyleSweepsInsideAClipThatHonorsTheOrigin {
    LoadingIndicator *line = [self indicator:VibeLoadingIndicatorStyleWaveform];
    XCTAssertEqual(_host.sublayers.count, 2u, @"track and shimmer clip");
    CALayer *clip = _host.sublayers[1];
    XCTAssertTrue(clip.masksToBounds, @"the band must not escape its span");

    [line layoutInBounds:CGRectMake(40, 0, 100, 20)];
    XCTAssertEqualWithAccuracy(self.track.frame.origin.x, 40, 1e-9);
    XCTAssertEqualWithAccuracy(self.track.frame.size.width, 100, 1e-9);
    XCTAssertEqualWithAccuracy(clip.frame.origin.x, 40, 1e-9);
    XCTAssertNil([self.track animationForKey:@"pulse"], @"the line's motion is the sweep");
    CABasicAnimation *sweep = (CABasicAnimation *)[clip.sublayers.firstObject animationForKey:@"sweep"];
    XCTAssertNotNil(sweep);
    XCTAssertEqualObjects(sweep.fromValue, @(-20));
    XCTAssertEqualObjects(sweep.toValue, @(120));
}

- (void)testTheSweepCoversOnlyTheUnfilledRemainderAndSitsAboveTheFill {
    LoadingIndicator *line = [self indicator:VibeLoadingIndicatorStyleWaveform];
    CGRect bounds = CGRectMake(0, 0, 200, 20);
    [line layoutInBounds:bounds];
    [line setProgress:0.25f inBounds:bounds];
    XCTAssertEqual(_host.sublayers.count, 3u);
    CALayer *fill = _host.sublayers[1];
    CALayer *clip = _host.sublayers[2];
    XCTAssertTrue([fill isKindOfClass:CAGradientLayer.class], @"fill sits below the clip");
    XCTAssertTrue(clip.masksToBounds);
    XCTAssertEqualWithAccuracy(clip.frame.origin.x, 50, 1e-9);
    XCTAssertEqualWithAccuracy(clip.frame.size.width, 150, 1e-9);
}

- (void)testAReinstalledSweepKeepsItsCarriedPhase {
    LoadingIndicator *line = [self indicator:VibeLoadingIndicatorStyleWaveform];
    [line layoutInBounds:CGRectMake(0, 0, 200, 20)];
    CALayer *band = _host.sublayers[1].sublayers.firstObject;

    // Stands in for a sweep a previous reinstall already offset.
    CABasicAnimation *carried = [[band animationForKey:@"sweep"] copy];
    carried.timeOffset = 0.5;
    [band addAnimation:carried forKey:@"sweep"];

    [line layoutInBounds:CGRectMake(0, 0, 200, 20)];
    XCTAssertEqualWithAccuracy([band animationForKey:@"sweep"].timeOffset, 0.5, 1e-9,
                               @"unchanged endpoints must not reinstall");

    [line layoutInBounds:CGRectMake(0, 0, 300, 20)];
    CABasicAnimation *resized = (CABasicAnimation *)[band animationForKey:@"sweep"];
    XCTAssertEqualObjects(resized.toValue, @(300 + 52.5));
    XCTAssertGreaterThanOrEqual(resized.timeOffset, 0.5, @"the phase rides over the reinstall");
}

- (void)testEndingTheSweepKeepsOnlyAFill {
    LoadingIndicator *line = [self indicator:VibeLoadingIndicatorStyleWaveform];
    [line layoutInBounds:_host.bounds];
    XCTAssertFalse([line endSweepKeepingFill]);
    XCTAssertEqual(_host.sublayers.count, 0u);

    LoadingIndicator *filled = [self indicator:VibeLoadingIndicatorStyleWaveform];
    [filled setProgress:0.5f inBounds:_host.bounds];
    XCTAssertTrue([filled endSweepKeepingFill]);
    XCTAssertEqual(_host.sublayers.count, 1u);
    XCTAssertTrue([_host.sublayers.firstObject isKindOfClass:CAGradientLayer.class]);
}

#pragma mark - Palette

- (void)testThePaletteFollowsTheAppearanceUnlessOverridden {
    LoadingIndicator *row = [self indicator:VibeLoadingIndicatorStyleRow];
    CGFloat alpha = VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 0).trackAlpha;
    XCTAssertTrue(ColorIs(self.track.backgroundColor, NSColor.whiteColor, alpha));
    [row updateColorsForDark:NO];
    XCTAssertTrue(ColorIs(self.track.backgroundColor, NSColor.blackColor, alpha));
    row.colorOverride = NSColor.redColor;
    XCTAssertTrue(ColorIs(self.track.backgroundColor, NSColor.redColor, alpha));
    row.colorOverride = nil;
    XCTAssertTrue(ColorIs(self.track.backgroundColor, NSColor.blackColor, alpha));
}

#pragma mark - LoadingIndicatorView

- (void)testTheRowViewHoldsLayersOnlyWhileActive {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    XCTAssertFalse(view.active);
    XCTAssertEqual(view.layer.sublayers.count, 0u);

    view.active = YES;
    XCTAssertEqual(view.layer.sublayers.count, 1u);
    XCTAssertNotNil([view.layer.sublayers.firstObject animationForKey:@"pulse"]);
    view.progress = 0.5f;
    XCTAssertEqual(view.layer.sublayers.count, 2u);

    view.active = NO;
    XCTAssertEqual(view.layer.sublayers.count, 0u);
    XCTAssertLessThan(view.progress, 0, @"a later activation starts indeterminate");
}

- (void)testProgressSetBeforeActivationIsApplied {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    view.progress = 0.5f;
    view.active = YES;
    XCTAssertEqual(view.layer.sublayers.count, 2u);
    XCTAssertEqualWithAccuracy(view.layer.sublayers.lastObject.frame.size.width, 8, 1e-9);
}

- (void)testLeavingTheWindowDropsTheAnimation {
    NSWindow *window = VibeOffscreenWindow(NSMakeSize(100, 40));
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    [window.contentView addSubview:view];
    view.active = YES;
    XCTAssertEqual(view.layer.sublayers.count, 1u);
    [view removeFromSuperview];
    XCTAssertFalse(view.active);
    XCTAssertEqual(view.layer.sublayers.count, 0u);
}

- (void)testTheRowViewForwardsItsColor {
    LoadingIndicatorView *view = [[LoadingIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    view.barColor = NSColor.whiteColor;
    view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    view.active = YES;
    CGFloat alpha = VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 0).trackAlpha;
    XCTAssertTrue(ColorIs(view.layer.sublayers.firstObject.backgroundColor, NSColor.whiteColor, alpha),
                  @"the override wins over a light appearance");
}

@end
