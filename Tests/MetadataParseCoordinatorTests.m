//
//  MetadataParseCoordinatorTests.m
//
//  Deterministic contention coverage for duplicate metadata rows.
//

#import <XCTest/XCTest.h>

#import "MetadataParseCoordinator.h"

@interface EqualMetadataParticipant : NSObject
@end

@implementation EqualMetadataParticipant

- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:EqualMetadataParticipant.class];
}

- (NSUInteger)hash {
    return 1;
}

@end

@interface MetadataParseCoordinatorTests : XCTestCase
@end

@implementation MetadataParseCoordinatorTests

- (void)testDuplicateRowsWaitExactlyOnceForTheirHolder {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];
    NSObject *holder = [NSObject new];
    NSObject *firstDuplicate = [NSObject new];
    NSObject *secondDuplicate = [NSObject new];

    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    XCTAssertTrue(claim.isOwner);
    XCTAssertFalse([coordinator claimParseForKey:key participant:firstDuplicate].isOwner);
    XCTAssertFalse([coordinator claimParseForKey:key participant:secondDuplicate].isOwner);
    XCTAssertFalse([coordinator claimParseForKey:key participant:firstDuplicate].isOwner);
    XCTAssertFalse([coordinator claimParseForKey:key participant:holder].isOwner);

    NSArray *waiters = [coordinator completeClaim:claim];
    XCTAssertEqual(waiters.count, 2u);
    XCTAssertTrue([waiters containsObject:firstDuplicate]);
    XCTAssertTrue([waiters containsObject:secondDuplicate]);
    XCTAssertEqual([coordinator completeClaim:claim].count, 0u);

    // The next generation of this key starts clean. Were the waiter list not
    // cleared alongside the holder, these two would be delivered a second
    // time and republished onto rows that already have their metadata.
    MetadataParseClaim *next = [coordinator claimParseForKey:key participant:firstDuplicate];
    XCTAssertTrue(next.isOwner);
    XCTAssertEqual([coordinator completeClaim:next].count, 0u);
}

// A repeated holder also receives a non-owning claim. Completing it must not
// free the true holder or drain its waiters mid-parse.
- (void)testARepeatedOwnerClaimCannotCompleteTheRealOne {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];
    NSObject *holder = [NSObject new];
    NSObject *duplicate = [NSObject new];

    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    [coordinator claimParseForKey:key participant:duplicate];
    MetadataParseClaim *repeat = [coordinator claimParseForKey:key participant:holder];
    XCTAssertFalse(repeat.isOwner);

    XCTAssertEqual([coordinator completeClaim:repeat].count, 0u);
    // Still held, and still holding its waiter.
    XCTAssertFalse([coordinator claimParseForKey:key participant:duplicate].isOwner);
    XCTAssertEqualObjects([coordinator completeClaim:claim], (@[duplicate]));
}

// The mixed case, alongside testReleasedWaiterDoesNotKeepAnOldPlaylistRowAlive:
// one waiter dying must not take its surviving siblings out of the delivery.
- (void)testASurvivingWaiterIsStillDeliveredWhenASiblingDies {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];
    NSObject *holder = [NSObject new];
    NSObject *survivor = [NSObject new];

    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    @autoreleasepool {
        NSObject *discarded = [NSObject new];
        [coordinator claimParseForKey:key participant:discarded];
        [coordinator claimParseForKey:key participant:survivor];
        discarded = nil;
    }
    XCTAssertEqualObjects([coordinator completeClaim:claim], (@[survivor]));
}

- (void)testOnlyTheHolderCanReleaseAClaim {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];
    NSObject *holder = [NSObject new];
    NSObject *duplicate = [NSObject new];

    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    MetadataParseClaim *duplicateClaim = [coordinator claimParseForKey:key participant:duplicate];
    XCTAssertTrue(claim.isOwner);
    XCTAssertFalse(duplicateClaim.isOwner);
    XCTAssertEqual([coordinator completeClaim:duplicateClaim].count, 0u);
    XCTAssertFalse([coordinator claimParseForKey:key participant:duplicate].isOwner);
    NSArray *waiters = [coordinator completeClaim:claim];
    XCTAssertEqual(waiters.count, 1u);
    XCTAssertTrue([waiters containsObject:duplicate]);
    XCTAssertTrue([coordinator claimParseForKey:key participant:duplicate].isOwner);
}

- (void)testEqualButDistinctRowsWaitIndependently {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    EqualMetadataParticipant *holder = [EqualMetadataParticipant new];
    EqualMetadataParticipant *first = [EqualMetadataParticipant new];
    EqualMetadataParticipant *second = [EqualMetadataParticipant new];
    MetadataParseClaim *claim = [coordinator claimParseForKey:@"same" participant:holder];

    XCTAssertFalse([coordinator claimParseForKey:@"same" participant:first].isOwner);
    XCTAssertFalse([coordinator claimParseForKey:@"same" participant:second].isOwner);
    NSArray *waiters = [coordinator completeClaim:claim];
    XCTAssertEqual(waiters.count, 2u);
    XCTAssertTrue([waiters containsObject:first]);
    XCTAssertTrue([waiters containsObject:second]);
}

- (void)testReleasedWaiterDoesNotKeepAnOldPlaylistRowAlive {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSObject *holder = [NSObject new];
    MetadataParseClaim *claim = [coordinator claimParseForKey:@"same" participant:holder];
    __weak NSObject *weakWaiter;
    @autoreleasepool {
        NSObject *waiter = [NSObject new];
        weakWaiter = waiter;
        XCTAssertFalse([coordinator claimParseForKey:@"same" participant:waiter].isOwner);
    }

    XCTAssertNil(weakWaiter);
    XCTAssertEqual([coordinator completeClaim:claim].count, 0u);
}

- (void)testConcurrentCompletionDeliversWaitersOnce {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSObject *holder = [NSObject new];
    NSObject *waiter = [NSObject new];
    MetadataParseClaim *claim = [coordinator claimParseForKey:@"same" participant:holder];
    [coordinator claimParseForKey:@"same" participant:waiter];
    NSMutableArray<NSArray *> *results = [NSMutableArray array];
    NSObject *lock = [NSObject new];

    dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        NSArray *result = [coordinator completeClaim:claim];
        @synchronized (lock) {
            [results addObject:result];
        }
    });

    XCTAssertEqual(results.count, 2u);
    XCTAssertEqual(results[0].count + results[1].count, 1u);
    XCTAssertTrue([results[0] containsObject:waiter] || [results[1] containsObject:waiter]);
}

- (void)testSuccessfulDrainKeepsLateWaitersBehindTheHolderUntilAdopted {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSObject *holder = [NSObject new];
    NSObject *first = [NSObject new];
    NSObject *late = [NSObject new];
    MetadataParseClaim *claim = [coordinator claimParseForKey:@"same"
                                                   participant:holder];
    [coordinator claimParseForKey:@"same" participant:first];

    BOOL completed = YES;
    XCTAssertEqualObjects([coordinator drainWaitersForSuccessfulClaim:claim
                                                             completed:&completed],
                          (@[first]));
    XCTAssertFalse(completed);
    XCTAssertFalse([coordinator claimParseForKey:@"same" participant:late].isOwner,
                   @"a late row must join the handoff, not become a new owner");
    XCTAssertEqualObjects([coordinator drainWaitersForSuccessfulClaim:claim
                                                             completed:&completed],
                          (@[late]));
    XCTAssertFalse(completed);
    XCTAssertEqual([coordinator drainWaitersForSuccessfulClaim:claim
                                                      completed:&completed].count,
                   0u);
    XCTAssertTrue(completed);

    XCTAssertTrue([coordinator claimParseForKey:@"same"
                                     participant:[NSObject new]].isOwner);
}

- (void)testIndependentKeysDoNotContend {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *second = [NSObject new];

    MetadataParseClaim *firstClaim = [coordinator claimParseForKey:@"first" participant:first];
    MetadataParseClaim *secondClaim = [coordinator claimParseForKey:@"second" participant:second];
    XCTAssertTrue(firstClaim.isOwner);
    XCTAssertTrue(secondClaim.isOwner);
    XCTAssertEqual([coordinator completeClaim:firstClaim].count, 0u);
    XCTAssertEqual([coordinator completeClaim:secondClaim].count, 0u);
}

- (void)testMissingKeysRemainUncoordinated {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    MetadataParseClaim *first = [coordinator claimParseForKey:nil participant:[NSObject new]];
    MetadataParseClaim *second = [coordinator claimParseForKey:nil participant:[NSObject new]];
    XCTAssertTrue(first.isOwner);
    XCTAssertTrue(second.isOwner);
    XCTAssertEqual([coordinator completeClaim:first].count, 0u);
    XCTAssertEqual([coordinator completeClaim:second].count, 0u);
}

- (void)testCompletionUsesTheKeyCapturedAtClaimTime {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSMutableString *key = [@"original" mutableCopy];
    NSObject *holder = [NSObject new];
    NSObject *duplicate = [NSObject new];
    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    XCTAssertFalse([coordinator claimParseForKey:@"original" participant:duplicate].isOwner);
    [key setString:@"changed"];

    XCTAssertEqualObjects([coordinator completeClaim:claim], (@[duplicate]));
    XCTAssertTrue([coordinator claimParseForKey:@"original" participant:duplicate].isOwner);
}

- (void)testStaleOwnerCannotCompleteANewerGeneration {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSObject *first = [NSObject new];
    NSObject *second = [NSObject new];
    MetadataParseClaim *oldClaim = [coordinator claimParseForKey:@"same" participant:first];
    [coordinator completeClaim:oldClaim];
    MetadataParseClaim *newClaim = [coordinator claimParseForKey:@"same" participant:second];

    XCTAssertTrue(newClaim.isOwner);
    XCTAssertEqual([coordinator completeClaim:oldClaim].count, 0u);
    XCTAssertEqual([coordinator completeClaim:newClaim].count, 0u);
}

// The dangerous window: rows still claiming while the holder completes. A
// waiter that registers just after the holder snapshots its list, but before
// the holder entry is removed, would be dropped — its row left bare with no
// parse of its own coming. Every participant must be accounted for exactly
// once, as an owner or as some owner's delivered waiter.
- (void)testAWaiterRacingCompletionIsNeverLost {
    static const NSUInteger kRounds = 60;
    static const NSUInteger kContenders = 32;
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];

    for (NSUInteger round = 0; round < kRounds; round++) {
        @autoreleasepool {
            MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
            NSObject *firstHolder = [NSObject new];
            MetadataParseClaim *firstClaim = [coordinator claimParseForKey:key
                                                              participant:firstHolder];
            XCTAssertTrue(firstClaim.isOwner, @"round %lu", (unsigned long)round);

            NSMutableArray<NSObject *> *contenders = [NSMutableArray arrayWithCapacity:kContenders];
            NSMutableArray<MetadataParseClaim *> *claims = [NSMutableArray arrayWithCapacity:kContenders];
            for (NSUInteger i = 0; i < kContenders; i++) {
                [contenders addObject:[NSObject new]];
                [claims addObject:(MetadataParseClaim *)NSNull.null];
            }
            NSObject *lock = [NSObject new];
            __block NSArray *deliveredByFirst = nil;

            // Index 0 completes the holder's claim while 1..N are still
            // claiming, so registrations land on both sides of the removal.
            dispatch_apply(kContenders + 1, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
                if (index == 0) {
                    NSArray *waiters = [coordinator completeClaim:firstClaim];
                    @synchronized (lock) {
                        deliveredByFirst = waiters;
                    }
                    return;
                }
                NSUInteger slot = index - 1;
                MetadataParseClaim *claim = [coordinator claimParseForKey:key
                                                             participant:contenders[slot]];
                @synchronized (lock) {
                    claims[slot] = claim;
                }
            });

            // At most one contender can have found the key free, since nothing
            // completes that second claim during the fan-out.
            NSMutableArray<MetadataParseClaim *> *ownerClaims = [NSMutableArray array];
            for (MetadataParseClaim *claim in claims) {
                XCTAssertNotEqualObjects(claim, NSNull.null, @"round %lu", (unsigned long)round);
                if (claim.isOwner) {
                    [ownerClaims addObject:claim];
                }
            }
            XCTAssertLessThanOrEqual(ownerClaims.count, 1u, @"round %lu", (unsigned long)round);

            NSMutableArray *accounted = [NSMutableArray array];
            [accounted addObjectsFromArray:deliveredByFirst];
            for (NSUInteger i = 0; i < claims.count; i++) {
                if (claims[i].isOwner) {
                    [accounted addObject:contenders[i]];
                    [accounted addObjectsFromArray:[coordinator completeClaim:claims[i]]];
                }
            }

            // Exactly once each: no contender lost, none delivered twice.
            XCTAssertEqual(accounted.count, kContenders, @"round %lu", (unsigned long)round);
            XCTAssertEqual([NSSet setWithArray:accounted].count, kContenders,
                           @"round %lu", (unsigned long)round);
            for (NSObject *contender in contenders) {
                XCTAssertTrue([accounted containsObject:contender],
                              @"round %lu", (unsigned long)round);
            }
            XCTAssertFalse([accounted containsObject:firstHolder],
                           @"round %lu", (unsigned long)round);
        }
    }
}

- (void)testConcurrentContentionHasOneHolderAndEveryOtherRowWaits {
    static const NSUInteger kRounds = 40;
    static const NSUInteger kContenders = 64;
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/shared.flac"];

    for (NSUInteger round = 0; round < kRounds; round++) {
        @autoreleasepool {
            MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
            NSMutableArray<NSObject *> *contenders = [NSMutableArray arrayWithCapacity:kContenders];
            for (NSUInteger i = 0; i < kContenders; i++) {
                [contenders addObject:[NSObject new]];
            }
            NSObject *lock = [NSObject new];
            __block NSObject *holder = nil;
            __block MetadataParseClaim *holderClaim = nil;

            dispatch_apply(kContenders, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
                NSObject *contender = contenders[index];
                MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:contender];
                if (claim.isOwner) {
                    @synchronized (lock) {
                        holder = contender;
                        holderClaim = claim;
                    }
                }
            });

            XCTAssertNotNil(holder, @"round %lu", (unsigned long)round);
            XCTAssertNotNil(holderClaim, @"round %lu", (unsigned long)round);
            NSArray<NSObject *> *waiters = [coordinator completeClaim:holderClaim];
            XCTAssertEqual(waiters.count, kContenders - 1, @"round %lu", (unsigned long)round);
            NSSet *delivered = [NSSet setWithArray:waiters];
            XCTAssertEqual(delivered.count, waiters.count, @"round %lu", (unsigned long)round);
            for (NSObject *contender in contenders) {
                XCTAssertEqual(contender == holder, ![delivered containsObject:contender],
                               @"round %lu", (unsigned long)round);
            }
        }
    }
}

#if DEBUG
// The debug channel's dump_health reports these, and the stress driver holds
// them to a growth limit of a few entries. A counter that silently always read
// zero would look exactly like a clean run, so pin it here rather than trust a
// live sample: an in-flight parse is over in microseconds and a poll from
// outside the process almost never lands inside one.
- (void)testDebugPendingCountsTrackHoldersAndWaiters {
    MetadataParseCoordinator *coordinator = [MetadataParseCoordinator new];
    NSURL *key = [NSURL fileURLWithPath:@"/private/tmp/counted.flac"];
    NSObject *holder = [NSObject new];
    NSObject *waiter = [NSObject new];

    XCTAssertEqualObjects([coordinator pendingCounts][@"holders"], @0);
    XCTAssertEqualObjects([coordinator pendingCounts][@"waiters"], @0);

    MetadataParseClaim *claim = [coordinator claimParseForKey:key participant:holder];
    XCTAssertEqualObjects([coordinator pendingCounts][@"holders"], @1);
    XCTAssertEqualObjects([coordinator pendingCounts][@"waiters"], @0);

    [coordinator claimParseForKey:key participant:waiter];
    XCTAssertEqualObjects([coordinator pendingCounts][@"holders"], @1);
    XCTAssertEqualObjects([coordinator pendingCounts][@"waiters"], @1);

    // Completing the owner clears the holder and that key's whole waiter
    // table: both halves have to return to zero, or a soak run accumulates.
    [coordinator completeClaim:claim];
    XCTAssertEqualObjects([coordinator pendingCounts][@"holders"], @0);
    XCTAssertEqualObjects([coordinator pendingCounts][@"waiters"], @0);
}
#endif

@end
