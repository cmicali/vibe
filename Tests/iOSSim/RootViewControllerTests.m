// vibe-libs' tab shell (ui/TabShell). Its tests are Vibe's, because they need
// a hosted app. The root's card fold, driven through the delegate calls the
// strip and the card make: expanded, animating and dragging resolve to the
// tabs hidden or shown, the backdrop snapshot present or gone, the strip
// wanted, and the delegate told as the card's expanded state changes.

#import "IOSSimTestCase.h"

#import "AudioTrack.h"
#import "VibeMiniPlayerView.h"
#import "PlaybackController.h"
#import "PlaybackShellHost.h"
#import "PlayerViewController.h"
#import "VibePlaylist.h"
#import "RootViewController.h"

// Stands in as the root's delegate: notes cardExpanded at each exposure call,
// and forwards every call to the host.
@interface ExposureRecorder : NSObject
@property (nonatomic, weak) id host;
@property (nonatomic) NSUInteger calls;
@property (nonatomic) BOOL lastSawExpanded;
@end

@implementation ExposureRecorder
- (void)rootViewControllerDidChangeExposure:(RootViewController *)root {
    self.calls += 1;
    self.lastSawExpanded = root.cardExpanded;
    [self.host rootViewControllerDidChangeExposure:root];
}
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.host respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return self.host;
}
@end

@interface RootViewControllerTests : IOSSimTestCase
@end

@implementation RootViewControllerTests {
    FakePlayback *_playback;
    PlaybackShellHost *_host;
    RootViewController *_root;
    ExposureRecorder *_recorder;
}

- (void)setUp {
    [super setUp];
    _playback = [[FakePlayback alloc] init];
    [_playback.playlist replaceAllWithTracks:@[
        [self trackNamed:@"one.mp3" title:@"One" artist:@"Band" duration:120],
        [self trackNamed:@"two.mp3" title:@"Two" artist:@"Band" duration:200],
    ] startingAtIndex:0];
    _playback.screenState = VibePlayerScreenStateTrack;
    _playback.displayedTrack = _playback.playlist.currentTrack;
    _host = [[PlaybackShellHost alloc] initWithPlayback:_playback.asPlayback];
    _root = _host.root;
    self.window.rootViewController = _root;
    [self.window layoutIfNeeded];
    _root.sceneActive = YES;
    VibeSpinFor(0);
}

- (void)tearDown {
    _root.delegate = (id<RootViewControllerDelegate>)_host;
    _recorder = nil;
    _root = nil;
    _host = nil;
    [super tearDown];
}

- (UITabBarController *)tabs {
    for (UIViewController *child in _root.childViewControllers) {
        if ([child isKindOfClass:UITabBarController.class]) {
            return (UITabBarController *)child;
        }
    }
    return nil;
}

- (PlayerViewController *)card {
    for (UIViewController *child in _root.childViewControllers) {
        if ([child isKindOfClass:PlayerViewController.class]) {
            return (PlayerViewController *)child;
        }
    }
    return nil;
}

// Whatever stands in the root's view beside the tabs and the card.
- (UIView *)snapshot {
    for (UIView *view in _root.view.subviews) {
        if (view != self.tabs.view && view != self.card.view) {
            return view;
        }
    }
    return nil;
}

- (void)expand {
    [(id<VibeMiniPlayerViewDelegate>)_root miniPlayerViewDidRequestExpand:(VibeMiniPlayerView *)[UIView new]];
}

- (void)pan:(CGFloat)translation velocity:(CGFloat)velocity state:(UIGestureRecognizerState)state {
    [(id<PlayerViewControllerDelegate>)_host playerViewController:self.card
                                            didPanWithTranslation:translation
                                                         velocity:velocity
                                                            state:state];
}

- (BOOL)settled {
    return self.snapshot == nil && !self.card.view.layer.animationKeys.count;
}

- (void)expandAndSettle {
    [self expand];
    XCTAssertTrue([self eventually:^BOOL { return self.settled && self.tabs.view.hidden; }],
                  @"the card never came to rest up");
}

#pragma mark - At rest

- (void)testAtRestBelowTheTabsAreShownAndTheCardHidden {
    XCTAssertNotNil(self.tabs);
    XCTAssertFalse(self.tabs.view.hidden);
    XCTAssertTrue(self.card.view.hidden);
    XCTAssertFalse(self.card.isPresented);
    XCTAssertNil(self.snapshot);
}

// A card at rest covers the tabs, so they are hidden and sample nothing.
- (void)testExpandedAtRestHidesTheTabsAndDropsTheSnapshot {
    [self expandAndSettle];
    XCTAssertFalse(self.card.view.hidden);
    XCTAssertTrue(self.card.isPresented);
    XCTAssertTrue(CGAffineTransformIsIdentity(self.card.view.transform));
}

// Moving, a snapshot stands in for the tabs and the tabs are shown under it.
- (void)testWhileTheCardMovesTheSnapshotStandsInAndTheTabsAreShown {
    // A view never committed to the screen snapshots nothing.
    [CATransaction flush];
    [self eventually:^BOOL { return [self.tabs.view snapshotViewAfterScreenUpdates:NO] != nil; }];
    [self expand];
    if (UIAccessibilityIsReduceMotionEnabled()) {
        return;  // unanimated: no moving phase to see
    }
    XCTAssertNotNil(self.snapshot);
    XCTAssertFalse(self.tabs.view.hidden);
    XCTAssertTrue([self eventually:^BOOL { return self.settled; }]);
    XCTAssertTrue(self.tabs.view.hidden);
}

- (void)testAnEmptyPlaylistNeverExpands {
    [_playback.playlist clear];
    [self expand];
    VibeSpinFor(kVibeTestNegativeWindow);
    XCTAssertTrue(self.card.view.hidden);
    XCTAssertFalse(self.card.isPresented);
}

#pragma mark - The interactive minimize

- (void)testADragShowsTheTabsUnderASnapshotAndAShortOneSpringsBack {
    [self expandAndSettle];
    [self pan:40 velocity:0 state:UIGestureRecognizerStateBegan];
    XCTAssertNotNil(self.snapshot);
    XCTAssertFalse(self.tabs.view.hidden);
    XCTAssertEqual(self.card.view.transform.ty, 40);
    [self pan:60 velocity:0 state:UIGestureRecognizerStateChanged];
    XCTAssertEqual(self.card.view.transform.ty, 60);
    [self pan:60 velocity:0 state:UIGestureRecognizerStateEnded];
    XCTAssertTrue([self eventually:^BOOL { return self.settled && self.tabs.view.hidden; }]);
    XCTAssertTrue(self.card.isPresented, @"a short drag keeps the card up");
    XCTAssertTrue(CGAffineTransformIsIdentity(self.card.view.transform));
}

- (void)testACancelledDragSpringsBack {
    [self expandAndSettle];
    [self pan:200 velocity:0 state:UIGestureRecognizerStateBegan];
    [self pan:200 velocity:0 state:UIGestureRecognizerStateCancelled];
    XCTAssertTrue([self eventually:^BOOL { return self.settled && self.tabs.view.hidden; }]);
    XCTAssertTrue(self.card.isPresented);
}

- (void)testAFlickMinimizesAndTheTabsComeBack {
    [self expandAndSettle];
    [self pan:30 velocity:0 state:UIGestureRecognizerStateBegan];
    [self pan:30 velocity:5000 state:UIGestureRecognizerStateEnded];
    XCTAssertFalse(self.card.isPresented, @"presented drops as the minimize starts");
    XCTAssertTrue([self eventually:^BOOL { return self.settled && self.card.view.hidden; }]);
    XCTAssertFalse(self.tabs.view.hidden);
}

- (void)testTheGrabberMinimizes {
    [self expandAndSettle];
    [(id<PlayerViewControllerDelegate>)_host playerViewControllerDidRequestMinimize:self.card];
    XCTAssertTrue([self eventually:^BOOL { return self.settled && self.card.view.hidden; }]);
    XCTAssertFalse(self.tabs.view.hidden);
}

- (void)testADragOnAMinimizedCardIsIgnored {
    [self pan:100 velocity:0 state:UIGestureRecognizerStateBegan];
    XCTAssertNil(self.snapshot);
    XCTAssertTrue(self.card.view.hidden);
}

#pragma mark - The delegate

- (void)recordExposure {
    _recorder = [[ExposureRecorder alloc] init];
    _recorder.host = _host;
    _root.delegate = (id<RootViewControllerDelegate>)_recorder;
}

// The drag's snapshot is still up when the minimize starts, so the delegate
// must hear from the minimize itself, not only when the spring ends.
- (void)testADragThatMinimizesTellsTheDelegateAtOnce {
    [self expandAndSettle];
    CGFloat height = _root.view.bounds.size.height;
    [self pan:height * 0.5 velocity:0 state:UIGestureRecognizerStateBegan];
    [self pan:height * 0.5 velocity:0 state:UIGestureRecognizerStateChanged];
    [self recordExposure];
    [self pan:height * 0.5 velocity:0 state:UIGestureRecognizerStateEnded];
    XCTAssertFalse(_root.cardExpanded);
    XCTAssertGreaterThan(_recorder.calls, 0u, @"heard before the spring ends");
    XCTAssertFalse(_recorder.lastSawExpanded);
}

// An interrupted move keeps its snapshot too, so the expand that interrupts
// it tells the delegate itself.
- (void)testAnExpandThatInterruptsAMinimizeTellsTheDelegateAtOnce {
    [self expandAndSettle];
    [(id<PlayerViewControllerDelegate>)_host playerViewControllerDidRequestMinimize:self.card];
    [self recordExposure];
    [self expand];
    XCTAssertTrue(_root.cardExpanded);
    XCTAssertGreaterThan(_recorder.calls, 0u, @"heard before the spring ends");
    XCTAssertTrue(_recorder.lastSawExpanded);
}

#pragma mark - The strip

// The strip is the card in one line, so it is wanted for the same states.
- (void)testTheStripIsWantedExactlyWhenTheScreenDescribesATrack {
    XCTAssertNotNil(self.tabs.bottomAccessory);
    _playback.screenState = VibePlayerScreenStateError;
    [_playback notify:@selector(playbackDidRenderCurrentTrack:)];
    XCTAssertNil(self.tabs.bottomAccessory);
    _playback.screenState = VibePlayerScreenStateParked;
    [_playback notify:@selector(playbackDidRenderCurrentTrack:)];
    XCTAssertNotNil(self.tabs.bottomAccessory);
}

- (void)testTheStripsButtonsReachTheModel {
    [_playback clearCalls];
    [(id<VibeMiniPlayerViewDelegate>)_root miniPlayerViewDidTapPlayPause:(VibeMiniPlayerView *)[UIView new]];
    [(id<VibeMiniPlayerViewDelegate>)_root miniPlayerViewDidTapNext:(VibeMiniPlayerView *)[UIView new]];
    XCTAssertEqualObjects(_playback.calls, (@[@"playPause", @"next"]));
}

@end
