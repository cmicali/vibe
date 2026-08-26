//
// The internal drag-reorder arithmetic: what an AppKit insertion slot means
// for a set of dragged rows — the downward off-by-one, the no-op slots — and
// the evolving-coordinate single-row move sequence that realizes an accepted
// drop. Host-less on purpose: these off-by-ones are exactly what a pointer
// drag cannot pin deterministically.
//

#import <XCTest/XCTest.h>

#import "../Vibe/Playlist/Mac/PlaylistDragRules.h"

@interface PlaylistDragRulesTests : XCTestCase
@end

@implementation PlaylistDragRulesTests

static NSIndexSet *Rows(NSArray<NSNumber *> *rows) {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (NSNumber *row in rows) {
        [indexes addIndex:row.unsignedIntegerValue];
    }
    return indexes;
}

// The reference the sequence must reproduce: extract ascending, splice back
// contiguously at the destination.
static NSArray<NSString *> *ReferenceMove(NSArray<NSString *> *list,
                                          NSIndexSet *sources,
                                          NSUInteger destination) {
    NSMutableArray<NSString *> *result = [list mutableCopy];
    NSArray<NSString *> *moved = [result objectsAtIndexes:sources];
    [result removeObjectsAtIndexes:sources];
    [result insertObjects:moved
                atIndexes:[NSIndexSet indexSetWithIndexesInRange:
                           NSMakeRange(destination, moved.count)]];
    return result;
}

// Applies the emitted pairs as NSMutableArray remove/insert — the same
// semantics as NSTableView's moveRowAtIndex:toIndex:.
static NSArray<NSString *> *ApplySequence(NSArray<NSString *> *list,
                                          NSIndexSet *sources,
                                          NSUInteger destination,
                                          NSUInteger *pairCount) {
    NSMutableArray<NSString *> *result = [list mutableCopy];
    __block NSUInteger pairs = 0;
    VibePlaylistMoveSequenceEnumerate(sources, destination, ^(NSUInteger from, NSUInteger to) {
        NSString *row = result[from];
        [result removeObjectAtIndex:from];
        [result insertObject:row atIndex:to];
        pairs += 1;
    });
    if (pairCount) {
        *pairCount = pairs;
    }
    return result;
}

#pragma mark - Drop decision

- (void)testSingleRowDecisionAtEverySlot {
    // Dragging row 1 of 4: slots 1 and 2 bracket the row itself and are
    // no-ops; a slot past the source subtracts the vacated row.
    NSIndexSet *source = Rows(@[@1u]);
    NSUInteger destination;
    struct { NSInteger slot; VibePlaylistDropDecision decision; NSUInteger final; } cases[] = {
        {0, VibePlaylistDropMove, 0},
        {1, VibePlaylistDropNoOp, 0},
        {2, VibePlaylistDropNoOp, 0},
        {3, VibePlaylistDropMove, 2},
        {4, VibePlaylistDropMove, 3},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        destination = NSNotFound;
        VibePlaylistDropDecision decision =
                VibePlaylistDropDecisionForSlot(source, cases[i].slot, 4, &destination);
        XCTAssertEqual(decision, cases[i].decision, @"slot %ld", (long)cases[i].slot);
        if (decision == VibePlaylistDropMove) {
            XCTAssertEqual(destination, cases[i].final, @"slot %ld", (long)cases[i].slot);
        }
    }
}

- (void)testContiguousBlockNoOpSlotsSpanTheBlockAndBothEdges {
    // Dragging rows 1-2 of 5: every slot from the block's first row through
    // one past its last leaves the order unchanged.
    NSIndexSet *source = Rows(@[@1u, @2u]);
    NSUInteger destination;
    struct { NSInteger slot; VibePlaylistDropDecision decision; NSUInteger final; } cases[] = {
        {0, VibePlaylistDropMove, 0},
        {1, VibePlaylistDropNoOp, 0},
        {2, VibePlaylistDropNoOp, 0},
        {3, VibePlaylistDropNoOp, 0},
        {4, VibePlaylistDropMove, 2},
        {5, VibePlaylistDropMove, 3},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        VibePlaylistDropDecision decision =
                VibePlaylistDropDecisionForSlot(source, cases[i].slot, 5, &destination);
        XCTAssertEqual(decision, cases[i].decision, @"slot %ld", (long)cases[i].slot);
        if (decision == VibePlaylistDropMove) {
            XCTAssertEqual(destination, cases[i].final, @"slot %ld", (long)cases[i].slot);
        }
    }
}

- (void)testNonContiguousSetIsNeverANoOp {
    // Even landing at its own first row gathers the set, which moves the
    // survivor out from between its members.
    NSUInteger destination;
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u, @2u]), 0, 3, &destination),
                   VibePlaylistDropMove);
    XCTAssertEqual(destination, 0u);
    // And each slot inside the set subtracts only the sources above it.
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@1u, @3u]), 2, 5, &destination),
                   VibePlaylistDropMove);
    XCTAssertEqual(destination, 1u);
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@1u, @3u]), 5, 5, &destination),
                   VibePlaylistDropMove);
    XCTAssertEqual(destination, 3u);
}

- (void)testDraggingEveryRowIsAlwaysANoOp {
    NSIndexSet *all = Rows(@[@0u, @1u, @2u]);
    NSUInteger destination;
    for (NSInteger slot = 0; slot <= 3; slot++) {
        XCTAssertEqual(VibePlaylistDropDecisionForSlot(all, slot, 3, &destination),
                       VibePlaylistDropNoOp, @"slot %ld", (long)slot);
    }
}

- (void)testOneRowPlaylistOffersNoMove {
    NSUInteger destination;
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u]), 0, 1, &destination),
                   VibePlaylistDropNoOp);
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u]), 1, 1, &destination),
                   VibePlaylistDropNoOp);
}

- (void)testMalformedInputsAreRejectedNotGuessed {
    NSUInteger destination;
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(nil, 0, 3, &destination),
                   VibePlaylistDropRejected);
    XCTAssertEqual(VibePlaylistDropDecisionForSlot([NSIndexSet indexSet], 0, 3, &destination),
                   VibePlaylistDropRejected);
    // A member at count is out of range, not the legal edge slot.
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@3u]), 0, 3, &destination),
                   VibePlaylistDropRejected);
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u]), -1, 3, &destination),
                   VibePlaylistDropRejected);
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u]), 4, 3, &destination),
                   VibePlaylistDropRejected);
}

- (void)testAllButOneRowMovesInBothDirections {
    NSUInteger destination;
    // Dragging rows 1-3 of 4 to slot 0: the block lands first.
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@1u, @2u, @3u]), 0, 4, &destination),
                   VibePlaylistDropMove);
    XCTAssertEqual(destination, 0u);
    // Dragging rows 0-2 of 4 to slot 4: the block lands after the survivor.
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@0u, @1u, @2u]), 4, 4, &destination),
                   VibePlaylistDropMove);
    XCTAssertEqual(destination, 1u);
}

#pragma mark - Move sequence

- (void)testSequencePinsTheWorkedExamples {
    NSArray<NSString *> *list = @[@"A", @"B", @"C", @"D", @"E"];

    // {1,3} -> 0: two up-movers stack under the line.
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@1u, @3u]), 0, ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@1u, @0u], @[@3u, @1u]]));

    // {0,4} -> 2: one down-mover to the line's underside, one up-mover.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @4u]), 2, ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @2u], @[@4u, @3u]]));

    // {0,1} -> 3 downward: the second extraction's index has shifted up.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @1u]), 3, ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @4u], @[@0u, @4u]]));
    XCTAssertEqualObjects(ApplySequence(list, Rows(@[@0u, @1u]), 3, NULL),
                          (@[@"C", @"D", @"E", @"A", @"B"]));

    // {0,2,4} -> 1: the source already in place emits nothing.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @2u, @4u]), 1, ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @1u], @[@4u, @3u]]));
}

- (void)testSequenceReproducesTheReferenceMoveForEveryAcceptedDrop {
    NSArray<NSString *> *list = @[@"A", @"B", @"C", @"D", @"E"];
    NSArray<NSArray<NSNumber *> *> *sourceCases = @[
        @[@0u], @[@2u], @[@4u],
        @[@0u, @1u], @[@1u, @2u], @[@3u, @4u],
        @[@0u, @2u], @[@1u, @3u], @[@0u, @4u],
        @[@0u, @2u, @4u], @[@1u, @2u, @3u],
        @[@0u, @1u, @2u, @3u],
    ];
    for (NSArray<NSNumber *> *sourceCase in sourceCases) {
        NSIndexSet *sources = Rows(sourceCase);
        for (NSInteger slot = 0; slot <= (NSInteger)list.count; slot++) {
            NSUInteger destination;
            if (VibePlaylistDropDecisionForSlot(sources, slot, list.count, &destination)
                    != VibePlaylistDropMove) {
                continue;
            }
            NSUInteger pairCount = 0;
            NSArray<NSString *> *applied = ApplySequence(list, sources, destination, &pairCount);
            XCTAssertEqualObjects(applied, ReferenceMove(list, sources, destination),
                                  @"sources %@ slot %ld", sources, (long)slot);
            XCTAssertLessThanOrEqual(pairCount, sources.count,
                                     @"sources %@ slot %ld", sources, (long)slot);
        }
    }
}

- (void)testSingleRowSequenceIsOnePairMatchingTheDecision {
    NSUInteger destination;
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@3u]), 1, 5, &destination),
                   VibePlaylistDropMove);
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@3u]), destination, ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@3u, @1u]]));
}

@end
