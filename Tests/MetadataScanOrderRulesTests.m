//
//  MetadataScanOrderRulesTests.m
//
//  The scan materialization lane's pick order: already-local files, then
//  deferred state, neighborhood rank, playlist index.
//  Because the lane is serial, this comparator is the whole of what decides
//  which file downloads next.
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
    // The next track (rank 0) goes ahead of an earlier row outside the
    // neighborhood, however small that row's index is.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 0, 7, NO, NO, NSNotFound, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 0, NO, NO, 0, 7));
    // Within the neighborhood the stated order holds: next, second-next,
    // previous.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 0, 9, NO, NO, 1, 2));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, 1, 9, NO, NO, 2, 2));
}

- (void)testEqualRankFollowsPlaylistIndex {
    // The tail — everything past the neighborhood — is stable playlist order,
    // never stage-1 completion order.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 3, NO, NO, NSNotFound, 4));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 4, NO, NO, NSNotFound, 3));
}

- (void)testDeferredSortsLastWhateverTheNeighborhoodSays {
    // A deferred retry has already failed once; even rank 0 cannot promote it
    // past a track that has not tried at all.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NO, NSNotFound, 99, NO, YES, 0, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, YES, 0, 0, NO, NO, NSNotFound, 99));
    // Two deferred entries keep rank-then-index order among themselves.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, YES, 0, 5, NO, YES, NSNotFound, 1));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, YES, NSNotFound, 1, NO, YES, NSNotFound, 2));
}

- (void)testLocalLeadsEveryOtherKey {
    // A local file's materialization is a no-op, so it beats the neighborhood's
    // best download — and a local deferred retry still beats an untried
    // download, because retrying it costs nothing either.
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

    id<MetadataScanOrderCandidate> best = VibeBestMetadataScanCandidate(
            @[earlyTail, lateNext], @[next]);

    XCTAssertEqual(best, lateNext);
}

- (void)testExactPickerPrefersALocalTailOverTheNeighborhoodsDownload {
    NSURL *next = [NSURL fileURLWithPath:@"/next.flac"];
    NSURL *tail = [NSURL fileURLWithPath:@"/tail.flac"];
    MetadataScanCandidateFake *localTail = [self candidateAtIndex:20 url:tail deferred:NO];
    localTail.local = YES;
    MetadataScanCandidateFake *datalessNext = [self candidateAtIndex:1 url:next deferred:NO];

    id<MetadataScanOrderCandidate> best = VibeBestMetadataScanCandidate(
            @[datalessNext, localTail], @[next]);

    XCTAssertEqual(best, localTail);
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

    id<MetadataScanOrderCandidate> best = VibeBestMetadataScanCandidate(
            @[otherCandidate, duplicateCandidate],
            @[duplicate, other, duplicate]);

    XCTAssertEqual(best, duplicateCandidate);
}

#pragma mark - The priority slot's own pick

// Phase 1's regression guard: the priority-slot picker was inline loader code
// with no host-less coverage while its predecessors broke three times. The
// decision now lives here, where every branch is pinned.

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

- (void)testPriorityPickIgnoresEveryUnprioritizedRecord {
    NSURL *ordinary = [NSURL fileURLWithPath:@"/a.flac"];
    NSArray *candidates = @[[self candidateAtIndex:0 url:ordinary deferred:NO]];
    XCTAssertNil(VibeBestPriorityScanCandidate(candidates,
            [NSSet setWithObject:[NSURL fileURLWithPath:@"/b.flac"]], NO));
    XCTAssertNil(VibeBestPriorityScanCandidate(candidates, [NSSet set], NO));
}

- (void)testPriorityPickPrefersAnUntriedRecordOverADeferredRetry {
    NSURL *tried = [NSURL fileURLWithPath:@"/tried.flac"];
    NSURL *fresh = [NSURL fileURLWithPath:@"/fresh.flac"];
    NSArray *candidates = @[
        [self candidateAtIndex:0 url:tried deferred:YES],
        [self candidateAtIndex:5 url:fresh deferred:NO],
    ];
    NSSet *priority = [NSSet setWithArray:@[tried, fresh]];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, priority, NO);
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
    NSSet *priority = [NSSet setWithArray:@[later, earlier, outside]];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, priority, NO);
    XCTAssertEqualObjects(best.url, earlier);
}

- (void)testAYieldedRecordWaitsWhileTheForegroundIsActiveAndNotAfter {
    NSURL *yielded = [NSURL fileURLWithPath:@"/yielded.flac"];
    NSArray *candidates = @[[self priorityCandidateAtIndex:0 url:yielded
                                                  deferred:NO
                                          yieldedUnderHold:YES]];
    NSSet *priority = [NSSet setWithObject:yielded];
    // Re-picking under an active foreground would repeat the bounded probe and
    // yield when its answer lands; the first idle pick takes it.
    XCTAssertNil(VibeBestPriorityScanCandidate(candidates, priority, YES));
    XCTAssertEqualObjects(
            VibeBestPriorityScanCandidate(candidates, priority, NO).url, yielded);
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
    NSSet *priority = [NSSet setWithArray:@[yielded, fresh]];
    id<MetadataScanOrderCandidate> best =
            VibeBestPriorityScanCandidate(candidates, priority, YES);
    XCTAssertEqualObjects(best.url, fresh);
}

@end
