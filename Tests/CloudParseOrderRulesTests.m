//
//  CloudParseOrderRulesTests.m
//
//  The cloud lane's pick order: (deferred, neighborhood rank, playlist index).
//  Because the lane is serial, this comparator is the whole of what decides
//  which file downloads next.
//

#import <XCTest/XCTest.h>

#import "CloudParseOrderRules.h"

@interface CloudParseOrderRulesTests : XCTestCase
@end

@implementation CloudParseOrderRulesTests

- (void)testNeighborhoodRankBeatsPlaylistIndex {
    // The next track (rank 0) goes ahead of an earlier row outside the
    // neighborhood, however small that row's index is.
    XCTAssertTrue(VibeCloudParseOrderedBefore(NO, 0, 7, NO, NSNotFound, 0));
    XCTAssertFalse(VibeCloudParseOrderedBefore(NO, NSNotFound, 0, NO, 0, 7));
    // Within the neighborhood the stated order holds: next, second-next,
    // previous.
    XCTAssertTrue(VibeCloudParseOrderedBefore(NO, 0, 9, NO, 1, 2));
    XCTAssertTrue(VibeCloudParseOrderedBefore(NO, 1, 9, NO, 2, 2));
}

- (void)testEqualRankFollowsPlaylistIndex {
    // The tail — everything past the neighborhood — is stable playlist order,
    // never stage-1 completion order.
    XCTAssertTrue(VibeCloudParseOrderedBefore(NO, NSNotFound, 3, NO, NSNotFound, 4));
    XCTAssertFalse(VibeCloudParseOrderedBefore(NO, NSNotFound, 4, NO, NSNotFound, 3));
}

- (void)testDeferredSortsLastWhateverTheNeighborhoodSays {
    // A deferred retry has already failed once; even rank 0 cannot promote it
    // past a track that has not tried at all.
    XCTAssertTrue(VibeCloudParseOrderedBefore(NO, NSNotFound, 99, YES, 0, 0));
    XCTAssertFalse(VibeCloudParseOrderedBefore(YES, 0, 0, NO, NSNotFound, 99));
    // Two deferred entries keep rank-then-index order among themselves.
    XCTAssertTrue(VibeCloudParseOrderedBefore(YES, 0, 5, YES, NSNotFound, 1));
    XCTAssertTrue(VibeCloudParseOrderedBefore(YES, NSNotFound, 1, YES, NSNotFound, 2));
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
        return VibeCloudParseOrderedBefore(
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

@end
