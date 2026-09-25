//
// The Now Playing republish position rule: natural playback advance must not
// count as dirty, because the system extrapolates elapsed time itself from
// the last publish; only a jump the extrapolation cannot explain — a seek, a
// pitch rescale — forces a republish.
//

#import <XCTest/XCTest.h>

#import "NowPlayingRules.h"
#import "NowPlayingController.h"
#import "AudioTrack.h"
#import <MediaPlayer/MediaPlayer.h>

@interface NowPlayingRulesTests : XCTestCase
@property NowPlayingController *publisher;
@property NSMutableArray<NSDictionary *> *publications;
@property NSMutableArray<NSArray *> *availability;
@property NSTimeInterval now;
@end

@implementation NowPlayingRulesTests

// Published at t=1000, position 30s. All cases judge a candidate 10 seconds
// of wall-clock later.
static const CFAbsoluteTime kPublishedAt = 1000.0;
static const CFAbsoluteTime kNow = 1010.0;
static const NSTimeInterval kPublishedPosition = 30.0;

static BOOL Dirty(double publishedRate, BOOL wasPlaying, NSTimeInterval position) {
    return VibeNowPlayingPositionIsDirty(kPublishedPosition, kPublishedAt, publishedRate, wasPlaying,
                                         position, kNow, kVibeNowPlayingRepublishTolerance);
}

- (void)testNaturalAdvanceWhilePlayingIsNotDirty {
    // 10 wall-clock seconds at rate 1: the system predicts 40s on its own.
    XCTAssertFalse(Dirty(1.0, YES, 40.0));
    XCTAssertFalse(Dirty(1.0, YES, 40.9));   // inside the 1s tolerance
    XCTAssertFalse(Dirty(1.0, YES, 39.1));
}

- (void)testHoldWhilePausedIsNotDirty {
    // Paused extrapolates at 0 whatever rate was published with the pause.
    XCTAssertFalse(Dirty(1.0, NO, 30.0));
    XCTAssertFalse(Dirty(2.0, NO, 30.5));
}

- (void)testSeekWhilePlayingIsDirty {
    XCTAssertTrue(Dirty(1.0, YES, 100.0));   // forward jump
    XCTAssertTrue(Dirty(1.0, YES, 5.0));     // backward jump
}

- (void)testSeekWhilePausedIsDirty {
    // Paused predicts a held position, so any real movement is a jump.
    XCTAssertTrue(Dirty(1.0, NO, 40.0));
}

- (void)testPublishedRateScalesThePrediction {
    // Published while playing at rate 2: prediction is 30 + 10*2 = 50.
    XCTAssertFalse(Dirty(2.0, YES, 50.0));
    XCTAssertTrue(Dirty(2.0, YES, 40.0));    // rate-1 advance no longer explains it
}

- (void)testToleranceBoundary {
    // Exactly at the tolerance is still natural advance; beyond it is a jump.
    XCTAssertFalse(Dirty(1.0, YES, 41.0));
    XCTAssertTrue(Dirty(1.0, YES, 41.001));
}


- (void)setUp {
    [super setUp];
    self.now = 1000;
    self.publications = NSMutableArray.array;
    self.availability = NSMutableArray.array;
    __weak __typeof__(self) weakSelf = self;
    self.publisher = [[NowPlayingController alloc] initWithClock:^{ return weakSelf.now; }
            publish:^(NSDictionary *info, NowPlayingPlaybackState state) {
        [weakSelf.publications addObject:@{@"info": info ?: @{}, @"state": @(state)}];
    } commandAvailability:^(BOOL next, BOOL previous) {
        [weakSelf.availability addObject:@[@(next), @(previous)]];
    }];
}

- (NSDictionary *)publishedInfo { return self.publications.lastObject[@"info"]; }

- (void)publish:(AudioTrack *)track state:(NowPlayingPlaybackState)state position:(double)position rate:(double)rate {
    [self.publisher updateWithTrack:track placeholderArt:nil position:position duration:120 state:state rate:rate hasNext:NO hasPrevious:NO];
}

- (void)testLaunchAndRestoredPauseDoNotClaimNowPlayingButCommandsStillUpdate {
    AudioTrack *track = [AudioTrack withURL:[NSURL fileURLWithPath:@"/tests/restored.wav"]];
    [self publish:nil state:NowPlayingPlaybackStateStopped position:0 rate:1];
    [self publish:track state:NowPlayingPlaybackStatePaused position:30 rate:1];
    XCTAssertEqual(self.publications.count, 0u);
    XCTAssertEqualObjects(self.availability, (@[@[@NO, @NO]]));
    [self publish:track state:NowPlayingPlaybackStatePlaying position:30 rate:1];
    XCTAssertEqual(self.publications.count, 1u);
    [self publish:track state:NowPlayingPlaybackStatePaused position:30 rate:1];
    XCTAssertEqualObjects(self.publishedInfo[MPNowPlayingInfoPropertyPlaybackRate], @0);
}

- (void)testClearPublishesOnceAndLaterPausedTrackCanPublish {
    AudioTrack *track = [AudioTrack withURL:[NSURL fileURLWithPath:@"/tests/a.wav"]];
    [self publish:nil state:NowPlayingPlaybackStatePlaying position:0 rate:1];
    XCTAssertEqual(self.publications.count, 0u);
    [self publish:track state:NowPlayingPlaybackStatePlaying position:0 rate:1];
    [self publish:nil state:NowPlayingPlaybackStateStopped position:0 rate:1];
    [self publish:nil state:NowPlayingPlaybackStateStopped position:0 rate:1];
    XCTAssertEqual(self.publications.count, 2u);
    XCTAssertEqualObjects(self.publications.lastObject, (@{@"info": @{}, @"state": @(NowPlayingPlaybackStateStopped)}));
    [self publish:track state:NowPlayingPlaybackStatePaused position:10 rate:1];
    XCTAssertEqual(self.publications.count, 3u);
}

- (void)testNaturalTicksSkipPublicationButSeekRateStateAndDurationChangesPublish {
    AudioTrack *track = [AudioTrack withURL:[NSURL fileURLWithPath:@"/tests/a.wav"]];
    [self publish:track state:NowPlayingPlaybackStatePlaying position:30 rate:2];
    self.now += 10;
    [self publish:track state:NowPlayingPlaybackStatePlaying position:50 rate:2];
    XCTAssertEqual(self.publications.count, 1u);
    [self publish:track state:NowPlayingPlaybackStatePlaying position:70 rate:2];
    [self publish:track state:NowPlayingPlaybackStatePlaying position:70 rate:1];
    [self publish:track state:NowPlayingPlaybackStatePaused position:70 rate:1];
    self.now += 100;
    [self publish:track state:NowPlayingPlaybackStatePaused position:70 rate:1];
    XCTAssertEqual(self.publications.count, 4u);
    [self publish:track state:NowPlayingPlaybackStatePaused position:10 rate:1];
    [self.publisher updateWithTrack:track placeholderArt:nil position:10 duration:0 state:NowPlayingPlaybackStatePaused rate:1 hasNext:YES hasPrevious:NO];
    XCTAssertEqual(self.publications.count, 6u);
    XCTAssertNil(self.publishedInfo[MPMediaItemPropertyPlaybackDuration]);
    XCTAssertEqualObjects(self.availability.lastObject, (@[@YES, @NO]));
}

- (void)testCommandOnlyChangeDoesNotRepublishAndNewURLDoes {
    AudioTrack *track = [AudioTrack withURL:[NSURL fileURLWithPath:@"/tests/a.wav"]];
    [self publish:track state:NowPlayingPlaybackStatePlaying position:-10 rate:1];
    XCTAssertEqualObjects(self.publishedInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime], @0);
    [self.publisher updateWithTrack:track placeholderArt:nil position:-10 duration:120 state:NowPlayingPlaybackStatePlaying rate:1 hasNext:YES hasPrevious:YES];
    XCTAssertEqual(self.publications.count, 1u);
    [self publish:[AudioTrack withURL:[NSURL fileURLWithPath:@"/elsewhere/a.wav"]]
            state:NowPlayingPlaybackStatePlaying position:0 rate:1];
    XCTAssertEqual(self.publications.count, 2u);
}

@end
