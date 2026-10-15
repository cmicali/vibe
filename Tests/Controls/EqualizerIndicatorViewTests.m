//
//  EqualizerIndicatorViewTests.m
//  VibeTests
//
//  The view's half of the equalizer guarantee: it polls only while every gate
//  holds, and each running poller declares exactly one balanced consumer.
//  The window is deferred and never ordered front, so no window server is
//  needed. The shell's count is MainPlayerControllerTests'.
//

#import <XCTest/XCTest.h>

#import "DrawnViewTestSupport.h"
#import "EqualizerIndicatorView.h"
#import "EqualizerIndicatorView+Debug.h"

// Records every declaration into a log the test may share across sources, so
// a swap's order is visible. An optional hook runs inside the NO callback.
@interface RecordingLevelSource : NSObject <EqualizerLevelSource>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<NSString *> *log;
@property (nonatomic) NSInteger consumers;
@property (nonatomic, copy) dispatch_block_t onWantedNo;
@end

@implementation RecordingLevelSource

- (BOOL)copyEqualizerLevels:(float *)outLevels count:(NSUInteger)count sequence:(uint64_t *)outSequence {
    return NO;
}

- (void)equalizerLevelsWanted:(BOOL)wanted {
    [self.log addObject:[NSString stringWithFormat:@"%@ %@", self.name, wanted ? @"YES" : @"NO"]];
    self.consumers += wanted ? 1 : -1;
    NSAssert(self.consumers >= 0, @"unbalanced NO");
    if (!wanted && self.onWantedNo) {
        dispatch_block_t hook = self.onWantedNo;
        self.onWantedNo = nil;
        hook();
    }
}

@end

@interface EqualizerIndicatorViewTests : XCTestCase
@end

@implementation EqualizerIndicatorViewTests {
    NSWindow *_window;
    NSMutableArray<NSString *> *_log;
    RecordingLevelSource *_source;
    uint64_t _baseLinks;
}

- (void)setUp {
    [super setUp];
    _window = VibeOffscreenWindow(NSMakeSize(100, 40));
    _log = [NSMutableArray array];
    _source = [self sourceNamed:@"A"];
    _baseLinks = [EqualizerIndicatorView vibeDebugActiveDisplayLinkCount];
}

- (RecordingLevelSource *)sourceNamed:(NSString *)name {
    RecordingLevelSource *source = [RecordingLevelSource new];
    source.name = name;
    source.log = _log;
    return source;
}

- (EqualizerIndicatorView *)attachedView {
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    [_window.contentView addSubview:view];
    return view;
}

- (EqualizerIndicatorView *)runningView {
    EqualizerIndicatorView *view = [self attachedView];
    view.levelSource = _source;
    view.presentationVisible = YES;
    view.audioOutputActive = YES;
    XCTAssertEqualObjects(_log, (@[@"A YES"]));
    XCTAssertEqual([self liveLinks], 1);
    return view;
}

- (int64_t)liveLinks {
    return (int64_t)[EqualizerIndicatorView vibeDebugActiveDisplayLinkCount] - (int64_t)_baseLinks;
}

- (void)resize:(EqualizerIndicatorView *)view to:(NSSize)size {
    [view setFrameSize:size];
    view.needsLayout = YES;
    [view layoutSubtreeIfNeeded];
}

#pragma mark - Gates

- (void)testNothingIsDeclaredUntilTheLastGateHolds {
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
    view.levelSource = _source;
    view.presentationVisible = YES;
    view.audioOutputActive = YES;
    XCTAssertEqual(_log.count, 0u, @"detached");
    XCTAssertEqual([self liveLinks], 0);

    [_window.contentView addSubview:view];
    XCTAssertEqualObjects(_log, (@[@"A YES"]));
    XCTAssertEqual([self liveLinks], 1);
    XCTAssertEqual(_source.consumers, 1);
}

- (void)testANilSourceIsInactive {
    EqualizerIndicatorView *view = [self attachedView];
    view.presentationVisible = YES;
    view.audioOutputActive = YES;
    XCTAssertEqual([self liveLinks], 0, @"no synthetic animation without a source");
}

- (void)testEachGateDropStopsThePollerAndBalancesDemand {
    NSArray<NSString *> *gates = @[@"audio", @"visible", @"hidden", @"detach", @"empty", @"source"];
    for (NSString *gate in gates) {
        [_log removeAllObjects];
        _source.consumers = 0;
        EqualizerIndicatorView *view = [self runningView];

        if ([gate isEqual:@"audio"]) view.audioOutputActive = NO;
        if ([gate isEqual:@"visible"]) view.presentationVisible = NO;
        if ([gate isEqual:@"hidden"]) view.hidden = YES;
        if ([gate isEqual:@"detach"]) [view removeFromSuperview];
        if ([gate isEqual:@"empty"]) [self resize:view to:NSZeroSize];
        if ([gate isEqual:@"source"]) view.levelSource = nil;

        XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO"]), @"%@", gate);
        XCTAssertEqual([self liveLinks], 0, @"%@", gate);
        XCTAssertEqual(_source.consumers, 0, @"%@", gate);

        if ([gate isEqual:@"audio"]) view.audioOutputActive = YES;
        if ([gate isEqual:@"visible"]) view.presentationVisible = YES;
        if ([gate isEqual:@"hidden"]) view.hidden = NO;
        if ([gate isEqual:@"detach"]) [_window.contentView addSubview:view];
        if ([gate isEqual:@"empty"]) [self resize:view to:NSMakeSize(16, 12)];
        if ([gate isEqual:@"source"]) view.levelSource = _source;

        XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO", @"A YES"]), @"%@ restored", gate);
        XCTAssertEqual([self liveLinks], 1, @"%@ restored", gate);
        [view removeFromSuperview];
        XCTAssertEqual(_source.consumers, 0, @"%@", gate);
    }
}

- (void)testRepeatedGateWritesDeclareNothingMore {
    EqualizerIndicatorView *view = [self runningView];
    view.audioOutputActive = YES;
    view.presentationVisible = YES;
    view.levelSource = _source;
    view.hidden = NO;
    [self resize:view to:NSMakeSize(16, 12)];
    XCTAssertEqualObjects(_log, (@[@"A YES"]));
    XCTAssertEqual([self liveLinks], 1);

    view.audioOutputActive = NO;
    view.presentationVisible = NO;
    [view removeFromSuperview];
    XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO"]), @"a second stop must not send a second NO");
}

- (void)testARowTooNarrowForTheGapsNeverRuns {
    // Five bars and four 1.5pt gaps: 6pt wide is all gap and no bar.
    EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 6, 12)];
    [_window.contentView addSubview:view];
    view.levelSource = _source;
    view.presentationVisible = YES;
    view.audioOutputActive = YES;
    XCTAssertEqual(_log.count, 0u);
    XCTAssertEqual([self liveLinks], 0);

    [self resize:view to:NSMakeSize(16, 0)];
    XCTAssertEqual(_log.count, 0u, @"zero height is empty too");
}

#pragma mark - Source swap

- (void)testASwapReleasesTheOldSourceBeforeRequestingTheNewOne {
    EqualizerIndicatorView *view = [self runningView];
    RecordingLevelSource *other = [self sourceNamed:@"B"];
    view.levelSource = other;
    XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO", @"B YES"]));
    XCTAssertEqual(_source.consumers, 0);
    XCTAssertEqual(other.consumers, 1);
    XCTAssertEqual([self liveLinks], 1, @"the poller survives a swap");

    [view removeFromSuperview];
    XCTAssertEqual(other.consumers, 0);
}

- (void)testAReentrantRestartInsideTheReleaseLeavesOneConsumer {
    // A shell can answer the NO by turning audio straight back on.
    EqualizerIndicatorView *view = [self runningView];
    __weak EqualizerIndicatorView *weakView = view;
    _source.onWantedNo = ^{
        weakView.audioOutputActive = YES;
    };
    view.audioOutputActive = NO;
    XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO", @"A YES"]));
    XCTAssertEqual(_source.consumers, 1);
    XCTAssertEqual([self liveLinks], 1);
    [view removeFromSuperview];
    XCTAssertEqual(_source.consumers, 0);
    XCTAssertEqual([self liveLinks], 0);
}

#pragma mark - Lifetime

- (void)testDeallocationWhileRunningBalancesDemandAndStopsThePoller {
    @autoreleasepool {
        NSWindow *window = VibeOffscreenWindow(NSMakeSize(100, 40));
        EqualizerIndicatorView *view = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(0, 0, 16, 12)];
        [window.contentView addSubview:view];
        view.levelSource = _source;
        view.presentationVisible = YES;
        view.audioOutputActive = YES;
        XCTAssertEqual(_source.consumers, 1);
        window = nil;
        view = nil;
    }
    XCTAssertEqualObjects(_log, (@[@"A YES", @"A NO"]));
    XCTAssertEqual(_source.consumers, 0);
    XCTAssertEqual([self liveLinks], 0);
}

#pragma mark - Pose

- (void)testAStoppedRowSettlesToRoundDots {
    EqualizerIndicatorView *view = [self runningView];
    [view layoutSubtreeIfNeeded];
    view.presentationVisible = NO;
    NSArray<CALayer *> *bars = view.layer.sublayers;
    XCTAssertEqual(bars.count, 5u);
    for (CALayer *bar in bars) {
        CGFloat width = bar.bounds.size.width;
        XCTAssertEqualWithAccuracy(width, (16 - 4 * 1.5) / 5, 1e-9);
        XCTAssertEqualWithAccuracy(bar.cornerRadius, width / 2, 1e-9);
        // Scaled to its own width: a circle.
        XCTAssertEqualWithAccuracy(bar.transform.m22 * bar.bounds.size.height, width, 1e-9);
        XCTAssertNil([bar animationForKey:@"equalizerLevelScale"], @"invisible stops settle at once");
    }
}

- (void)testTheBarsFollowTheAppearanceUnlessOverridden {
    EqualizerIndicatorView *view = [self attachedView];
    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    view.barColor = nil;
    CGColorRef dark = view.layer.sublayers.firstObject.backgroundColor;
    XCTAssertTrue(CGColorEqualToColor(dark, NSColor.whiteColor.CGColor));

    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    view.barColor = nil;
    CGColorRef light = view.layer.sublayers.firstObject.backgroundColor;
    XCTAssertTrue(CGColorEqualToColor(light, NSColor.blackColor.CGColor));

    view.barColor = NSColor.redColor;
    for (CALayer *bar in view.layer.sublayers) {
        XCTAssertTrue(CGColorEqualToColor(bar.backgroundColor, NSColor.redColor.CGColor));
    }
}

@end
