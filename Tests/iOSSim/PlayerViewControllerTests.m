// The now-playing card over a duck-typed model. The model's screenState
// (PlayerScreenRules.h, tested in VibeTests) is set here, its events are
// sent, and the card's pages are read back.

#import "IOSSimTestCase.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "Formatters.h"
#import "PlayerViewController.h"
#import "PlayerViewController+Delivery.h"
#import "OutputRouteView.h"
#import "PlaybackController.h"
#import "Playlist.h"
#import "TrackPageCell.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

@interface PlayerViewControllerTests : IOSSimTestCase
@end

@implementation PlayerViewControllerTests {
    FakePlayback *_playback;
    PlayerViewController *_card;
    UICollectionView *_pages;
}

- (void)setUp {
    [super setUp];
    AppSettings.sharedInstance.showRemainingTime = NO;
    _playback = [[FakePlayback alloc] init];
    NSArray<AudioTrack *> *tracks = @[
        [self trackNamed:@"one.mp3" title:@"One" artist:@"Band" duration:120],
        [self trackNamed:@"two.mp3" title:@"Two" artist:@"Band" duration:200],
        [self trackNamed:@"Three_Demo.mp3" title:nil artist:nil duration:90],
    ];
    [_playback.playlist replaceAllWithTracks:tracks startingAtIndex:1];
    _playback.screenState = VibePlayerScreenStateTrack;
    _playback.displayedTrack = _playback.playlist.currentTrack;
    _playback.duration = 200;
    _playback.position = 30;
}

- (void)tearDown {
    _card = nil;
    _pages = nil;
    [super tearDown];
}

- (void)showCard {
    _card = [[PlayerViewController alloc] initWithPlayback:_playback.asPlayback];
    self.window.rootViewController = _card;
    [self.window layoutIfNeeded];
    _card.sceneActive = YES;
    _card.presented = YES;
    for (UIView *subview in _card.view.subviews) {
        if ([subview isKindOfClass:UICollectionView.class]) {
            _pages = (UICollectionView *)subview;
        }
    }
    XCTAssertNotNil(_pages);
    XCTAssertTrue([self eventually:^BOOL { return [self pageAt:self->_playback.currentIndex] != nil; }],
                  @"the current page never appeared");
}

- (TrackPageCell *)pageAt:(NSUInteger)index {
    [_pages layoutIfNeeded];
    return (TrackPageCell *)[_pages cellForItemAtIndexPath:[NSIndexPath indexPathForItem:(NSInteger)index
                                                                              inSection:0]];
}

- (TrackPageCell *)current {
    return [self pageAt:_playback.currentIndex];
}

static NSString *Time(NSTimeInterval seconds) {
    return [Formatters.sharedInstance durationStringFromTimeInterval:seconds];
}

#pragma mark - Screen states

- (void)testAPlayingTrackShowsItsPlayhead {
    _playback.isPlaying = YES;
    [self showCard];
    [_playback notify:@selector(playbackDidTick:)];
    XCTAssertEqualObjects(self.current.elapsedLabel.text, Time(30));
    XCTAssertEqualObjects(self.current.remainingTimeControl.text, Time(200));
    XCTAssertEqualWithAccuracy(self.current.waveformView.progress, 30.0 / 200.0, 1e-6);

    AppSettings.sharedInstance.showRemainingTime = YES;
    [_playback notify:@selector(playbackDidTick:)];
    XCTAssertEqualObjects(self.current.remainingTimeControl.text, [@"-" stringByAppendingString:Time(170)]);
}

// Loading and Parked render the track at rest: the player may still describe
// the outgoing one.
- (void)testLoadingAndParkedRestAtTheStartWithTheTracksOwnDuration {
    [self showCard];
    for (NSNumber *state in @[@(VibePlayerScreenStateLoading), @(VibePlayerScreenStateParked)]) {
        _playback.screenState = (VibePlayerScreenState)state.integerValue;
        _playback.position = 55;
        _playback.duration = 999;
        [_playback notify:@selector(playbackDidTick:)];
        XCTAssertEqualObjects(self.current.elapsedLabel.text, Time(0), @"%@", state);
        XCTAssertEqualObjects(self.current.remainingTimeControl.text, Time(200), @"%@", state);
        XCTAssertEqual(self.current.waveformView.progress, 0, @"%@", state);
    }
}

// A scrub parked mid-open holds its target rather than snapping back.
- (void)testASeekInFlightHoldsTheTargetWhileLoading {
    [self showCard];
    _playback.screenState = VibePlayerScreenStateLoading;
    _playback.seekInFlight = YES;
    _playback.pendingSeekProgress = 0.6f;
    [_playback notify:@selector(playbackDidTick:)];
    XCTAssertEqualWithAccuracy(self.current.waveformView.progress, 0.6, 1e-6);
}

- (void)testAnErrorTakesTheCurrentPagesArtistLineInRed {
    [self showCard];
    _playback.screenState = VibePlayerScreenStateError;
    _playback.errorText = @"Could not play";
    [_playback notify:@selector(playbackDidRenderCurrentTrack:)];
    UILabel *error = VibeLabelWithText(self.current, @"Could not play");
    XCTAssertNotNil(error);
    XCTAssertEqualObjects(error.textColor, UIColor.systemRedColor);
    XCTAssertNotNil(VibeLabelWithText(self.current, @"Two"), @"the title stays");
    TrackPageCell *neighbor = [self pageAt:0];
    if (neighbor) {
        XCTAssertNil(VibeLabelWithText(neighbor, @"Could not play"), @"only the current page");
    }
}

// Only the empty state hides the transport, the action bar and the route.
- (void)testOnlyTheEmptyStateFadesTheChrome {
    [self showCard];
    XCTAssertEqual(self.current.transportView.alpha, 1);
    _playback.screenState = VibePlayerScreenStateEmpty;
    [_playback notify:@selector(playbackDidChangePlayState:)];
    XCTAssertEqual(self.current.transportView.alpha, 0);
    XCTAssertEqual(self.current.routeView.alpha, 0);
    _playback.screenState = VibePlayerScreenStateError;
    [_playback notify:@selector(playbackDidChangePlayState:)];
    XCTAssertEqual(self.current.transportView.alpha, 1);
}

- (void)testThePlayButtonFollowsThePlayState {
    [self showCard];
    XCTAssertEqualObjects(self.current.playPauseButton.accessibilityLabel, STR_TRANSPORT_PLAY);
    _playback.isPlaying = YES;
    [_playback notify:@selector(playbackDidChangePlayState:)];
    XCTAssertEqualObjects(self.current.playPauseButton.accessibilityLabel, STR_TRANSPORT_PAUSE);
}

- (void)testTheLastPageArrivesWithNextDimmed {
    [_playback.playlist replaceAllWithTracks:_playback.playlist.tracks startingAtIndex:2];
    _playback.displayedTrack = _playback.playlist.currentTrack;
    [self showCard];
    XCTAssertFalse(self.current.nextButton.enabled);
    _playback.playlist.repeatMode = VibeRepeatModeAll;
    [_playback notify:@selector(playbackDidChangePlayOrder:)];
    XCTAssertTrue(self.current.nextButton.enabled, @"under Repeat All no page is last");
}

// The root guarantee: the filename's single line is the title, in its color.
- (void)testAFilenamePageIsOneLineInTheTitlesColor {
    [_playback.playlist replaceAllWithTracks:_playback.playlist.tracks startingAtIndex:2];
    [self showCard];
    AudioTrack *bare = _playback.playlist.currentTrack;
    UILabel *line = VibeLabelWithText(self.current, bare.displayTitle);
    XCTAssertNotNil(line);
    XCTAssertEqualObjects(line.textColor, UIColor.labelColor);
    XCTAssertNil(VibeLabelWithText(self.current, @"Band"));
}

// album_art's color rides the art's install, so it belongs to its page.
- (void)testTheArtworkColorArrivesWithThePagesArt {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
    UIImage *green = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0.1 green:0.8 blue:0.2 alpha:1] setFill];
        UIRectFill(CGRectMake(0, 0, 64, 64));
    }];
    FakeTrackMetadata *metadata = (FakeTrackMetadata *)_playback.playlist.currentTrack.metadata;
    metadata.cachedArt = green;
    [self showCard];
    UIColor *color = self.current.waveformView.artworkThemeColor;
    XCTAssertNotNil(color);
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    XCTAssertGreaterThan(g, r);
    XCTAssertGreaterThan(g, b);
}

#pragma mark - Loading

- (void)testASlowOpenLoadsTheCurrentPageOnly {
    [self showCard];
    _playback.currentOpenSlow = YES;
    [_playback notify:@selector(playbackDidBeginLoading:)];
    XCTAssertTrue(self.current.waveformView.playbackLoading);
    TrackPageCell *neighbor = [self pageAt:0];
    if (neighbor) {
        XCTAssertFalse(neighbor.waveformView.playbackLoading);
    }
    _playback.currentOpenSlow = NO;
    [_playback notify:@selector(playbackDidFinishLoading:)];
    XCTAssertFalse(self.current.waveformView.playbackLoading);
}

#pragma mark - Deliveries

// A neighbor's scrubber is a preview: its seek and its readout are dropped.
- (void)testAScrubFromAnotherPageIsDropped {
    [self showCard];
    WaveformScrubberView *other = [[WaveformScrubberView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    [_playback clearCalls];
    NSString *elapsed = self.current.elapsedLabel.text;
    [_card waveformScrubberView:other didScrubToProgress:0.9];
    [_card waveformScrubberView:other didSeek:0.9f];
    XCTAssertEqualObjects(self.current.elapsedLabel.text, elapsed);
    XCTAssertFalse([_playback.calls containsObject:@"seekToProgress:"]);

    WaveformScrubberView *bound = self.current.waveformView;
    [_card waveformScrubberView:bound didScrubToProgress:0.5];
    XCTAssertEqualObjects(self.current.elapsedLabel.text, Time(100));
    [_card waveformScrubberView:bound didSeek:0.5f];
    XCTAssertEqualObjects(_playback.calls, @[@"seekToProgress:"]);
}

// TRAP: a hold is released by the view that took it, whichever page is bound.
- (void)testAPagerHoldIsReleasedByTheViewThatTookIt {
    [self showCard];
    WaveformScrubberView *outgoing = self.current.waveformView;
    WaveformScrubberView *other = [[WaveformScrubberView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    [_card waveformScrubberView:outgoing didChangeScrubbing:YES];
    XCTAssertFalse(_pages.scrollEnabled);
    [_card waveformScrubberView:other didChangeScrubbing:YES];
    [_card waveformScrubberView:outgoing didChangeScrubbing:NO];
    XCTAssertFalse(_pages.scrollEnabled, @"another holder still holds");
    [_card waveformScrubberView:other didChangeScrubbing:NO];
    XCTAssertTrue(_pages.scrollEnabled);
}

// One zoom for the pager: a release on one page lands on every page.
- (void)testAZoomReleaseFansOutToEveryVisiblePage {
    [self showCard];
    [_card waveformScrubberView:self.current.waveformView didChangeVisibleFraction:0.2];
    for (TrackPageCell *cell in _pages.visibleCells) {
        XCTAssertEqualWithAccuracy(cell.waveformView.visibleFraction, 0.2, 1e-9);
    }
}

@end
