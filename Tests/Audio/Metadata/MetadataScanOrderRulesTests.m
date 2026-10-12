//
//  MetadataScanOrderRulesTests.m
//

#import <XCTest/XCTest.h>

#import "MetadataScanOrderRules.h"

@interface MetadataScanCandidateFake : NSObject <MetadataScanOrderCandidate>
@property (nonatomic) BOOL local;
@property (nonatomic) BOOL deferred;
@property (nonatomic) NSUInteger playlistIndex;
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) BOOL yieldedUnderHold;
@end

@implementation MetadataScanCandidateFake
@end

@interface MetadataScanOrderRulesTests : XCTestCase
@end

static NSUInteger (^RankIn(NSArray<NSURL *> *neighborhood))(id<MetadataScanOrderCandidate>) {
    return ^NSUInteger(id<MetadataScanOrderCandidate> candidate) {
        return VibeMetadataScanNeighborhoodRank(candidate.url, neighborhood);
    };
}

@implementation MetadataScanOrderRulesTests

- (MetadataScanCandidateFake *)candidateAtIndex:(NSUInteger)index
                                           url:(NSURL *)url
                                      deferred:(BOOL)deferred {
    MetadataScanCandidateFake *candidate = [[MetadataScanCandidateFake alloc] init];
    candidate.playlistIndex = index;
    candidate.url = url;
    candidate.deferred = deferred;
    return candidate;
}

- (void)testNeighborhoodRankBeatsPlaylistIndex {
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 0, 7, NO, NO, NSNotFound, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 0, NO, NO, 0, 7));
    // Ranks 0, 1, 2 are next, second-next, previous.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 0, 9, NO, NO, 1, 2));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 1, 9, NO, NO, 2, 2));
}

- (void)testEqualRankFollowsPlaylistIndex {
    // Past the neighborhood: playlist order, never stage-1 completion order.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 3, NO, NO, NSNotFound, 4));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 4, NO, NO, NSNotFound, 3));
}

- (void)testDeferredSortsLastWhateverTheNeighborhoodSays {
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 99, NO, YES, 0, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, YES, 0, 0, NO, NO, NSNotFound, 99));
    // Two deferred entries keep rank-then-index order among themselves.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, YES, 0, 5, NO, YES, NSNotFound, 1));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, YES, NSNotFound, 1, NO, YES, NSNotFound, 2));
}

- (void)testLocalLeadsEveryOtherKey {
    // A local deferred retry costs nothing either, so it still beats an
    // untried download.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, NO, NSNotFound, 99, NO, NO, 0, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NO, 0, 0, YES, NO, NSNotFound, 99));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, YES, NSNotFound, 99, NO, NO, 0, 0));
    // Among local entries the remaining keys keep their order.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, NO, 0, 9, YES, NO, NSNotFound, 1));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, NO, NSNotFound, 1, YES, YES, 0, 0));
}

- (void)testATotalOrderOverAMixedPendingList {
    // The shape the picker sees after a track change mid-sweep: local rows
    // first, then neighborhood in rank order, then the tail by index, then
    // deferred retries.
    NSArray<NSArray<NSNumber *> *> *entries = @[
        @[@NO, @NO, @(NSNotFound), @6],   // tail
        @[@YES, @NO, @(NSNotFound), @8],  // local tail
        @[@NO, @YES, @(NSNotFound), @1],  // deferred
        @[@NO, @NO, @1, @4],              // second-next
        @[@NO, @NO, @(NSNotFound), @5],   // tail, earlier row
        @[@YES, @NO, @0, @3],             // local next
    ];
    NSArray *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        if (a == b) {
            return NSOrderedSame;
        }
        return VibeMetadataScanOrderedBefore(
                [a[0] boolValue], [a[1] boolValue],
                [a[2] unsignedIntegerValue], [a[3] unsignedIntegerValue],
                [b[0] boolValue], [b[1] boolValue],
                [b[2] unsignedIntegerValue], [b[3] unsignedIntegerValue])
                ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSArray *expected = @[
        @[@YES, @NO, @0, @3],
        @[@YES, @NO, @(NSNotFound), @8],
        @[@NO, @NO, @1, @4],
        @[@NO, @NO, @(NSNotFound), @5],
        @[@NO, @NO, @(NSNotFound), @6],
        @[@NO, @YES, @(NSNotFound), @1],
    ];
    XCTAssertEqualObjects(sorted, expected);
}

- (void)testExactPickerFindsTheBestRegardlessOfArrivalOrder {
    NSURL *next = [NSURL fileURLWithPath:@"/next.flac"];
    NSURL *tail = [NSURL fileURLWithPath:@"/tail.flac"];
    MetadataScanCandidateFake *earlyTail = [self candidateAtIndex:20 url:tail deferred:NO];
    MetadataScanCandidateFake *lateNext = [self candidateAtIndex:1 url:next deferred:NO];

    NSUInteger best = VibeBestMetadataScanCandidateIndex(@[earlyTail, lateNext], RankIn(@[next]), nil);

    XCTAssertEqual(best, 1u);
}

- (void)testExactPickerPrefersALocalTailOverTheNeighborhoodsDownload {
    NSURL *next = [NSURL fileURLWithPath:@"/next.flac"];
    NSURL *tail = [NSURL fileURLWithPath:@"/tail.flac"];
    MetadataScanCandidateFake *localTail = [self candidateAtIndex:20 url:tail deferred:NO];
    localTail.local = YES;
    MetadataScanCandidateFake *datalessNext = [self candidateAtIndex:1 url:next deferred:NO];

    NSUInteger best = VibeBestMetadataScanCandidateIndex(@[datalessNext, localTail], RankIn(@[next]), nil);

    XCTAssertEqual(best, 1u);
}

- (void)testDuplicateNeighborhoodURLKeepsItsFirstAndBestRank {
    NSURL *duplicate = [NSURL fileURLWithPath:@"/duplicate.flac"];
    NSURL *other = [NSURL fileURLWithPath:@"/other.flac"];
    MetadataScanCandidateFake *duplicateCandidate = [self candidateAtIndex:99
                                                                      url:duplicate
                                                                 deferred:NO];
    MetadataScanCandidateFake *otherCandidate = [self candidateAtIndex:0
                                                                  url:other
                                                             deferred:NO];

    NSUInteger best = VibeBestMetadataScanCandidateIndex(
            @[otherCandidate, duplicateCandidate],
            RankIn(@[duplicate, other, duplicate]), nil);

    XCTAssertEqual(best, 1u);
}

- (void)testSkippedCandidatesAreLeftOut {
    NSURL *next = [NSURL fileURLWithPath:@"/next.flac"];
    NSURL *tail = [NSURL fileURLWithPath:@"/tail.flac"];
    MetadataScanCandidateFake *tailCandidate = [self candidateAtIndex:20 url:tail deferred:NO];
    MetadataScanCandidateFake *nextCandidate = [self candidateAtIndex:1 url:next deferred:NO];
    NSArray *candidates = @[tailCandidate, nextCandidate];

    XCTAssertEqual(VibeBestMetadataScanCandidateIndex(candidates, RankIn(@[next]),
            ^BOOL(id<MetadataScanOrderCandidate> candidate) {
        return candidate == nextCandidate;
    }), 0u);
    XCTAssertEqual(VibeBestMetadataScanCandidateIndex(candidates, RankIn(@[next]),
            ^BOOL(id<MetadataScanOrderCandidate> candidate) {
        return YES;
    }), (NSUInteger)NSNotFound);
}

#pragma mark - The priority slot's own pick

- (MetadataScanCandidateFake *)priorityCandidateAtIndex:(NSUInteger)index
                                                    url:(NSURL *)url
                                               deferred:(BOOL)deferred
                                       yieldedUnderHold:(BOOL)yielded {
    MetadataScanCandidateFake *candidate = [self candidateAtIndex:index
                                                              url:url
                                                         deferred:deferred];
    candidate.yieldedUnderHold = yielded;
    return candidate;
}

- (void)testPriorityPickPrefersAnUntriedRecordOverADeferredRetry {
    NSURL *tried = [NSURL fileURLWithPath:@"/tried.flac"];
    NSURL *fresh = [NSURL fileURLWithPath:@"/fresh.flac"];
    NSArray *candidates = @[
        [self candidateAtIndex:0 url:tried deferred:YES],
        [self candidateAtIndex:5 url:fresh deferred:NO],
    ];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, NO);
    XCTAssertEqualObjects(best.url, fresh);
}

- (void)testPriorityPickBreaksTiesByPlaylistRowAndSortsOutsidersLast {
    NSURL *later = [NSURL fileURLWithPath:@"/later.flac"];
    NSURL *earlier = [NSURL fileURLWithPath:@"/earlier.flac"];
    NSURL *outside = [NSURL fileURLWithPath:@"/outside.flac"];
    NSArray *candidates = @[
        [self candidateAtIndex:9 url:later deferred:NO],
        [self candidateAtIndex:2 url:earlier deferred:NO],
        // A record minted outside the sweep (prioritizeTrack: on a track the
        // playlist never listed) carries NSNotFound and must sort last.
        [self candidateAtIndex:NSNotFound url:outside deferred:NO],
    ];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, NO);
    XCTAssertEqualObjects(best.url, earlier);
}

- (void)testAYieldedRecordWaitsWhileTheForegroundIsActiveAndNotAfter {
    NSURL *yielded = [NSURL fileURLWithPath:@"/yielded.flac"];
    NSArray *candidates = @[[self priorityCandidateAtIndex:0 url:yielded
                                                  deferred:NO
                                          yieldedUnderHold:YES]];
    // Re-picking under an active foreground would repeat the bounded probe and
    // yield when its answer lands; the first idle pick takes it.
    XCTAssertNil(VibeBestPriorityScanCandidate(candidates, YES));
    XCTAssertEqualObjects(
            VibeBestPriorityScanCandidate(candidates, NO).url, yielded);
}

- (void)testAYieldedRecordDoesNotBlockAFreshPriorityPick {
    NSURL *yielded = [NSURL fileURLWithPath:@"/yielded.flac"];
    NSURL *fresh = [NSURL fileURLWithPath:@"/fresh.flac"];
    NSArray *candidates = @[
        [self priorityCandidateAtIndex:0 url:yielded deferred:NO
                      yieldedUnderHold:YES],
        [self priorityCandidateAtIndex:1 url:fresh deferred:NO
                      yieldedUnderHold:NO],
    ];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, YES);
    XCTAssertEqualObjects(best.url, fresh);
}

@end
