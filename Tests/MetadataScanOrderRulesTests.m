//
//  MetadataScanOrderRulesTests.m
//
//  The scan materialization lane's pick order: deferred work, neighborhood
//  rank, then playlist index.
//  Because the lane is serial, this comparator is the whole of what decides
//  which file downloads next.
//

#import <XCTest/XCTest.h>

#import "MetadataScanOrderRules.h"

@interface MetadataScanCandidateFake : NSObject <MetadataScanOrderCandidate>
@property (nonatomic) BOOL deferred;
@property (nonatomic) NSUInteger playlistIndex;
@property (nonatomic, copy) NSURL *url;
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
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, 0, 7, NO, NSNotFound, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NSNotFound, 0, NO, 0, 7));
    // Within the neighborhood the stated order holds: next, second-next,
    // previous.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, 0, 9, NO, 1, 2));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, 1, 9, NO, 2, 2));
}

- (void)testEqualRankFollowsPlaylistIndex {
    // The tail — everything past the neighborhood — is stable playlist order,
    // never stage-1 completion order.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NSNotFound, 3, NO, NSNotFound, 4));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(NO, NSNotFound, 4, NO, NSNotFound, 3));
}

- (void)testDeferredSortsLastWhateverTheNeighborhoodSays {
    // A deferred retry has already failed once; even rank 0 cannot promote it
    // past a track that has not tried at all.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(NO, NSNotFound, 99, YES, 0, 0));
    XCTAssertFalse(VibeMetadataScanOrderedBefore(YES, 0, 0, NO, NSNotFound, 99));
    // Two deferred entries keep rank-then-index order among themselves.
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, 0, 5, YES, NSNotFound, 1));
    XCTAssertTrue(VibeMetadataScanOrderedBefore(YES, NSNotFound, 1, YES, NSNotFound, 2));
}

- (void)testATotalOrderOverAMixedPendingList {
    // The shape the picker sees after a track change mid-sweep: sorting a
    // mixed list yields neighborhood first in rank order, then the tail by
    // index, then deferred retries.
    NSArray<NSArray<NSNumber *> *> *entries = @[
        @[@NO, @(NSNotFound), @6],   // tail
        @[@YES, @(NSNotFound), @1],  // deferred
        @[@NO, @1, @4],              // second-next
        @[@NO, @(NSNotFound), @5],   // tail, earlier row
        @[@NO, @0, @3],              // next
    ];
    NSArray *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        if (a == b) {
            return NSOrderedSame;
        }
        return VibeMetadataScanOrderedBefore(
                [a[0] boolValue], [a[1] unsignedIntegerValue], [a[2] unsignedIntegerValue],
                [b[0] boolValue], [b[1] unsignedIntegerValue], [b[2] unsignedIntegerValue])
                ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSArray *expected = @[
        @[@NO, @0, @3],
        @[@NO, @1, @4],
        @[@NO, @(NSNotFound), @5],
        @[@NO, @(NSNotFound), @6],
        @[@YES, @(NSNotFound), @1],
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

@end
