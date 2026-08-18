//
//  PlaybackRequestCoordinatorTests.m
//
//  Deterministic event-order coverage for the queue-confined pending-open
//  control plane. AVAudioEngine deliberately stays out of this target.
//

#import <XCTest/XCTest.h>

#import "PlaybackRequestCoordinator.h"

@interface PlaybackRequestCoordinatorTests : XCTestCase
@end

@implementation PlaybackRequestCoordinatorTests

- (void)testRebindBeforeSlowDeliveryUsesTheLatestTrackAndIntent {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *rebound = [NSObject new];
    uint64_t identifier = [state beginWithTrack:first path:@"/same.flac"
                                         intent:VibePendingPlaybackIntentMake(0, NO)
                          submittedPlayIdentifier:1];

    VibePlaybackRequestRebind result = [state rebindTrack:rebound
                                                     path:@"/same.flac"
                                                    intent:VibePendingPlaybackIntentMake(12.5, YES)
                                     submittedPlayIdentifier:2];
    XCTAssertTrue(result.matched);
    XCTAssertTrue(result.trackChanged);
    XCTAssertTrue(result.pausedChanged);
    XCTAssertFalse(result.shouldNotifySlowLoad);
    XCTAssertTrue(result.shouldNotifyLoadingPaused);

    VibePlaybackRequest *slow = [state markSlowForRequest:identifier];
    XCTAssertEqual(slow.track, rebound);
    XCTAssertTrue(slow.intent.paused);
    XCTAssertEqualWithAccuracy(slow.intent.position, 12.5, 0.001);
}

- (void)testSlowRebindRequestsAReplacementLoadingDelivery {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *rebound = [NSObject new];
    uint64_t identifier = [state beginWithTrack:first path:@"/same.flac"
                                         intent:VibePendingPlaybackIntentMake(0, NO)
                          submittedPlayIdentifier:1];

    VibePlaybackRequest *slow = [state markSlowForRequest:identifier];
    XCTAssertEqual(slow.track, first);
    VibePlaybackRequestRebind result = [state rebindTrack:rebound
                                                     path:@"/same.flac"
                                                    intent:VibePendingPlaybackIntentMake(0, NO)
                                     submittedPlayIdentifier:2];
    XCTAssertTrue(result.trackChanged);
    XCTAssertTrue(result.shouldNotifySlowLoad);
    XCTAssertTrue(result.shouldNotifyLoadingPaused);
    XCTAssertEqual(slow.track, first);
    XCTAssertEqual(state.currentRequest.track, rebound);
    XCTAssertNil([state markSlowForRequest:identifier]);
}

- (void)testSlowSameRowReplayRequestsACurrentLoadingDelivery {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *track = [NSObject new];
    uint64_t identifier = [state beginWithTrack:track path:@"/same.flac"
                                         intent:VibePendingPlaybackIntentMake(0, NO)
                        submittedPlayIdentifier:1];
    XCTAssertNotNil([state markSlowForRequest:identifier]);

    VibePlaybackRequestRebind result = [state rebindTrack:track
                                                     path:@"/same.flac"
                                                   intent:VibePendingPlaybackIntentMake(0, NO)
                                  submittedPlayIdentifier:2];
    XCTAssertFalse(result.trackChanged);
    XCTAssertTrue(result.shouldNotifySlowLoad);
    XCTAssertEqual(state.currentRequest.identifier, identifier);
    XCTAssertEqual(state.currentRequest.submittedPlayIdentifier, 2u);
}

- (void)testRebindRefreshesPausedDeliveryForAReplacementTrack {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *rebound = [NSObject new];
    [state beginWithTrack:first path:@"/same.flac"
             intent:VibePendingPlaybackIntentMake(0, NO)
      submittedPlayIdentifier:1];

    VibePlaybackRequestRebind unchanged = [state rebindTrack:rebound
                                                        path:@"/same.flac"
                                                       intent:VibePendingPlaybackIntentMake(3, NO)
                                        submittedPlayIdentifier:2];
    XCTAssertTrue(unchanged.trackChanged);
    XCTAssertFalse(unchanged.pausedChanged);
    XCTAssertTrue(unchanged.shouldNotifyLoadingPaused);

    VibePlaybackRequestRebind paused = [state rebindTrack:first
                                                     path:@"/same.flac"
                                                    intent:VibePendingPlaybackIntentMake(3, YES)
                                     submittedPlayIdentifier:3];
    XCTAssertTrue(paused.trackChanged);
    XCTAssertTrue(paused.pausedChanged);
    XCTAssertTrue(paused.shouldNotifyLoadingPaused);
}

- (void)testStaleWorkersCannotMutateOrConsumeANewerRequest {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *second = [NSObject new];
    uint64_t oldIdentifier = [state beginWithTrack:first path:@"/first.flac"
                                            intent:VibePendingPlaybackIntentMake(0, NO)
                             submittedPlayIdentifier:1];
    uint64_t currentIdentifier = [state beginWithTrack:second path:@"/second.flac"
                                                intent:VibePendingPlaybackIntentMake(4, YES)
                                 submittedPlayIdentifier:2];

    XCTAssertNil([state markSlowForRequest:oldIdentifier]);
    XCTAssertNil([state consumeRequest:oldIdentifier]);
    XCTAssertEqual(state.currentRequest.track, second);
    XCTAssertEqualWithAccuracy(state.currentRequest.intent.position, 4, 0.001);
    XCTAssertTrue(state.currentRequest.intent.paused);
    XCTAssertEqual([state consumeRequest:currentIdentifier].track, second);
    XCTAssertNil(state.currentRequest);
}

// Either identity is enough, and neither alone is required — see the header.
- (void)testSeekIsAcceptedByEitherTheRowOrTheSubmittedPlay {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *rebound = [NSObject new];
    NSObject *stranger = [NSObject new];
    [state beginWithTrack:first path:@"/same.flac"
             intent:VibePendingPlaybackIntentMake(2, NO)
      submittedPlayIdentifier:1];

    XCTAssertTrue([state togglePause].intent.paused);
    XCTAssertTrue([state seekToPosition:42 ifCurrentTrackIs:first submittedPlayIdentifier:1]);
    [state rebindTrack:rebound path:@"/same.flac" intent:state.currentRequest.intent submittedPlayIdentifier:2];

    // Neither identity holds: a seek aimed at a row this request never had.
    XCTAssertFalse([state seekToPosition:99 ifCurrentTrackIs:stranger submittedPlayIdentifier:1]);
    XCTAssertFalse([state seekToPosition:99 ifCurrentTrackIs:nil submittedPlayIdentifier:0]);
    // The row still matches, even though the rebind moved the play identifier.
    // Same file, same target audio, so the seek must not be dropped.
    XCTAssertTrue([state seekToPosition:7 ifCurrentTrackIs:rebound submittedPlayIdentifier:1]);
    // The play identifier still matches, even though the row object moved. This
    // is the seek issued before its play ever reached the queue.
    XCTAssertTrue([state seekToPosition:9 ifCurrentTrackIs:first submittedPlayIdentifier:2]);
    // 0 means "caller could not determine it": the row alone decides.
    XCTAssertTrue([state seekToPosition:-3 ifCurrentTrackIs:rebound submittedPlayIdentifier:0]);
    XCTAssertFalse([state seekToPosition:11 ifCurrentTrackIs:first submittedPlayIdentifier:0]);

    XCTAssertTrue(state.currentRequest.intent.paused);
    XCTAssertEqual(state.currentRequest.intent.position, 0); // the -3 clamped
}

- (void)testRequestedPauseAndResumeAreIdempotentWhileLoading {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    [state beginWithTrack:[NSObject new] path:@"/same.flac"
                   intent:VibePendingPlaybackIntentMake(12.5, NO)
  submittedPlayIdentifier:1];

    VibePlaybackRequest *paused = [state setPausedIfChanged:YES];
    XCTAssertTrue(paused.intent.paused);
    XCTAssertEqualWithAccuracy(paused.intent.position, 12.5, 0.001);
    XCTAssertNil([state setPausedIfChanged:YES]);
    XCTAssertTrue(state.currentRequest.intent.paused);

    VibePlaybackRequest *resumed = [state setPausedIfChanged:NO];
    XCTAssertFalse(resumed.intent.paused);
    XCTAssertEqualWithAccuracy(resumed.intent.position, 12.5, 0.001);
    XCTAssertNil([state setPausedIfChanged:NO]);
    XCTAssertFalse(state.currentRequest.intent.paused);

    [state invalidate];
    XCTAssertNil([state setPausedIfChanged:YES]);
}

// The basis of every stale-delivery guard: an identifier is never handed out
// twice, so a worker blocked on a dead mount cannot consume a later open.
- (void)testIdentifiersNeverRepeatAcrossTheObjectsLifetime {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    uint64_t previous = 0;
    for (NSUInteger i = 0; i < 200; i++) {
        uint64_t identifier = [state beginWithTrack:[NSObject new] path:@"/same.flac"
                                             intent:VibePendingPlaybackIntentMake(0, NO)
                            submittedPlayIdentifier:i + 1];
        XCTAssertGreaterThan(identifier, previous);
        XCTAssertFalse([seen containsObject:@(identifier)]);
        [seen addObject:@(identifier)];
        previous = identifier;
        // Invalidate must not rewind the counter either: a request abandoned
        // by resetToStoppedStateOnQueue leaves a worker still holding its id.
        if (i % 3 == 0) {
            [state invalidate];
        }
        else if (i % 3 == 1) {
            [state consumeRequest:identifier];
        }
    }
    XCTAssertEqual(seen.count, 200u);
}

- (void)testDifferentPathDoesNotRebindTheCurrentRequest {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *second = [NSObject new];
    uint64_t firstIdentifier = [state beginWithTrack:first path:@"/first.flac"
                                               intent:VibePendingPlaybackIntentMake(0, NO)
                                submittedPlayIdentifier:1];

    VibePlaybackRequestRebind result = [state rebindTrack:second
                                                     path:@"/second.flac"
                                                   intent:VibePendingPlaybackIntentMake(0, NO)
                                    submittedPlayIdentifier:2];
    XCTAssertFalse(result.matched);
    XCTAssertEqual(state.currentRequest.identifier, firstIdentifier);
    XCTAssertEqual(state.currentRequest.track, first);

    uint64_t secondIdentifier = [state beginWithTrack:second path:@"/second.flac"
                                                intent:VibePendingPlaybackIntentMake(0, NO)
                                 submittedPlayIdentifier:2];
    XCTAssertGreaterThan(secondIdentifier, firstIdentifier);
    XCTAssertEqual(state.currentRequest.track, second);
}

- (void)testInvalidateRejectsEveryLateDelivery {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    uint64_t identifier = [state beginWithTrack:[NSObject new] path:@"/same.flac"
                                          intent:VibePendingPlaybackIntentMake(0, NO)
                           submittedPlayIdentifier:1];
    [state invalidate];

    XCTAssertNil([state markSlowForRequest:identifier]);
    XCTAssertNil([state consumeRequest:identifier]);
    XCTAssertNil(state.currentRequest);
}

- (void)testSameTrackRebindDoesNotNeedAnotherDelegateRefresh {
    PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
    NSObject *track = [NSObject new];
    [state beginWithTrack:track path:@"/same.flac"
             intent:VibePendingPlaybackIntentMake(4, YES)
      submittedPlayIdentifier:1];

    VibePlaybackRequestRebind result = [state rebindTrack:track
                                                     path:@"/same.flac"
                                                   intent:VibePendingPlaybackIntentMake(4, YES)
                                    submittedPlayIdentifier:2];
    XCTAssertTrue(result.matched);
    XCTAssertFalse(result.trackChanged);
    XCTAssertFalse(result.pausedChanged);
    XCTAssertFalse(result.shouldNotifySlowLoad);
    XCTAssertFalse(result.shouldNotifyLoadingPaused);
    XCTAssertEqual(state.currentRequest.submittedPlayIdentifier, 2u);
}

- (void)testSeededEventTracesPreserveRequestGuarantees {
    static const NSUInteger kTraces = 80;
    static const NSUInteger kEventsPerTrace = 1500;
    static const NSUInteger kTracks = 17;
    NSArray<NSObject *> *tracks = [self tracks:kTracks];
    NSArray<NSString *> *paths = @[@"/a.flac", @"/b.flac", @"/c.flac", @"/d.flac"];

    for (NSUInteger trace = 0; trace < kTraces; trace++) {
        PlaybackRequestCoordinator *state = [PlaybackRequestCoordinator new];
        uint64_t random = 0x9E3779B97F4A7C15ULL ^ trace;
        uint64_t currentIdentifier = 0;
        NSObject *currentTrack = nil;
        NSString *currentPath = nil;
        VibePendingPlaybackIntent currentIntent = VibePendingPlaybackIntentMake(0, NO);
        BOOL currentSlow = NO;
        uint64_t submittedPlayIdentifier = 0;
        uint64_t previousIdentifier = 0;

        for (NSUInteger event = 0; event < kEventsPerTrace; event++) {
            random = [self nextRandom:random];
            NSUInteger action = (NSUInteger)(random % 7);
            if (action == 0 || !currentIdentifier) {
                random = [self nextRandom:random];
                currentTrack = tracks[random % tracks.count];
                random = [self nextRandom:random];
                currentPath = paths[random % paths.count];
                random = [self nextRandom:random];
                currentIntent = VibePendingPlaybackIntentMake((NSTimeInterval)(random % 240), (random & 1) != 0);
                submittedPlayIdentifier++;
                currentIdentifier = [state beginWithTrack:currentTrack path:currentPath intent:currentIntent
                                     submittedPlayIdentifier:submittedPlayIdentifier];
                // Never reused, whatever mix of consume and invalidate ran
                // before: a blocked worker's id must not name a later open.
                XCTAssertGreaterThan(currentIdentifier, previousIdentifier,
                                     @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                previousIdentifier = currentIdentifier;
                currentSlow = NO;
            }
            else if (action == 1) {
                random = [self nextRandom:random];
                NSObject *rebound = tracks[random % tracks.count];
                random = [self nextRandom:random];
                VibePendingPlaybackIntent intent = VibePendingPlaybackIntentMake(
                        (NSTimeInterval)(random % 240), (random & 1) != 0);
                submittedPlayIdentifier++;
                VibePlaybackRequestRebind result = [state rebindTrack:rebound
                                                                   path:currentPath
                                                                 intent:intent
                                                  submittedPlayIdentifier:submittedPlayIdentifier];
                XCTAssertTrue(result.matched, @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(result.trackChanged, currentTrack != rebound,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(result.pausedChanged, currentIntent.paused != intent.paused,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(result.shouldNotifySlowLoad, currentSlow,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(result.shouldNotifyLoadingPaused,
                               currentTrack != rebound || currentIntent.paused != intent.paused,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                currentTrack = rebound;
                currentIntent = intent;
            }
            else if (action == 2) {
                VibePlaybackRequest *request = [state togglePause];
                currentIntent = VibePendingPlaybackIntentByTogglingPause(currentIntent);
                XCTAssertEqual(request.track, currentTrack,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
            }
            else if (action == 3) {
                random = [self nextRandom:random];
                NSObject *target = (random & 1) ? currentTrack : tracks[random % tracks.count];
                random = [self nextRandom:random];
                NSTimeInterval position = (NSTimeInterval)((NSInteger)(random % 480) - 120);
                // All three arms of the identifier check: the live play, a
                // stale one, and the 0 the caller passes when it cannot tell.
                random = [self nextRandom:random];
                uint64_t offered;
                switch (random % 3) {
                    case 0:  offered = submittedPlayIdentifier; break;
                    case 1:  offered = submittedPlayIdentifier + 1; break;
                    default: offered = 0; break;
                }
                BOOL accepted = (target == currentTrack)
                        || (offered && offered == submittedPlayIdentifier);
                XCTAssertEqual([state seekToPosition:position
                                     ifCurrentTrackIs:target
                             submittedPlayIdentifier:offered], accepted,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                if (accepted) {
                    currentIntent = VibePendingPlaybackIntentBySeeking(currentIntent, position);
                }
            }
            else if (action == 4) {
                BOOL shouldDeliver = !currentSlow;
                VibePlaybackRequest *slow = [state markSlowForRequest:currentIdentifier];
                XCTAssertEqual(slow != nil, shouldDeliver,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                currentSlow = YES;
            }
            else if (action == 5) {
                uint64_t staleIdentifier = currentIdentifier - 1;
                XCTAssertNil([state consumeRequest:staleIdentifier],
                             @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
            }
            else {
                XCTAssertEqual([state consumeRequest:currentIdentifier].track, currentTrack,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                currentIdentifier = 0;
                currentTrack = nil;
                currentPath = nil;
                currentIntent = VibePendingPlaybackIntentMake(0, NO);
                currentSlow = NO;
            }

            VibePlaybackRequest *request = state.currentRequest;
            XCTAssertEqual(request != nil, currentIdentifier != 0,
                           @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
            if (request) {
                XCTAssertEqual(request.identifier, currentIdentifier,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(request.submittedPlayIdentifier, submittedPlayIdentifier,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(request.track, currentTrack,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqualObjects(request.path, currentPath,
                                      @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqualWithAccuracy(request.intent.position, currentIntent.position, 0.001,
                                           @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(request.intent.paused, currentIntent.paused,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertEqual(request.isSlow, currentSlow,
                               @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
                XCTAssertTrue([state isLoadingPath:currentPath],
                              @"trace %lu event %lu", (unsigned long)trace, (unsigned long)event);
            }
        }
    }
}

- (NSArray<NSObject *> *)tracks:(NSUInteger)count {
    NSMutableArray<NSObject *> *tracks = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [tracks addObject:[NSObject new]];
    }
    return tracks;
}

- (uint64_t)nextRandom:(uint64_t)value {
    return value * 6364136223846793005ULL + 1442695040888963407ULL;
}

@end
