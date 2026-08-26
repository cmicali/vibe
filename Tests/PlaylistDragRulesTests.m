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

static NSIndexSet *Range(NSUInteger location, NSUInteger length) {
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(location, length)];
}

// The reference for the general set-to-set form: remove at the sources,
// insert at the destinations.
static NSArray<NSString *> *ReferenceMoveToSet(NSArray<NSString *> *list,
                                               NSIndexSet *sources,
                                               NSIndexSet *destinations) {
    NSMutableArray<NSString *> *result = [list mutableCopy];
    NSArray<NSString *> *moved = [result objectsAtIndexes:sources];
    [result removeObjectsAtIndexes:sources];
    [result insertObjects:moved atIndexes:destinations];
    return result;
}

// Applies the emitted pairs as NSMutableArray remove/insert — the same
// semantics as NSTableView's moveRowAtIndex:toIndex:.
static NSArray<NSString *> *ApplySequence(NSArray<NSString *> *list,
                                          NSIndexSet *sources,
                                          NSIndexSet *destinations,
                                          NSUInteger *pairCount) {
    NSMutableArray<NSString *> *result = [list mutableCopy];
    __block NSUInteger pairs = 0;
    VibePlaylistMoveSequenceEnumerate(sources, destinations, ^(NSUInteger from, NSUInteger to) {
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

    // {1,3} -> [0,2): two up-movers stack under the line.
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@1u, @3u]), Range(0, 2), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@1u, @0u], @[@3u, @1u]]));

    // {0,4} -> [2,4): one down-mover to the line's underside, one up-mover.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @4u]), Range(2, 2), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @2u], @[@4u, @3u]]));

    // {0,1} -> [3,5) downward: the second extraction's index has shifted up.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @1u]), Range(3, 2), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @4u], @[@0u, @4u]]));
    XCTAssertEqualObjects(ApplySequence(list, Rows(@[@0u, @1u]), Range(3, 2), NULL),
                          (@[@"C", @"D", @"E", @"A", @"B"]));

    // {0,2,4} -> [1,4): the source already in place emits nothing.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@0u, @2u, @4u]), Range(1, 3), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @1u], @[@4u, @3u]]));
}

- (void)testScatterSequenceIsTheGatherReversedAndSwapped {
    // The undo shape: the gathered block [0,2) scatters back to {1,3} — the
    // gather's pairs (1,0),(3,1) reversed with from/to swapped.
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(Range(0, 2), Rows(@[@1u, @3u]), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@1u, @3u], @[@0u, @1u]]));
    // Applied to the gathered list, it restores the original.
    XCTAssertEqualObjects(ApplySequence(@[@"B", @"D", @"A", @"C", @"E"],
                                        Range(0, 2), Rows(@[@1u, @3u]), NULL),
                          (@[@"A", @"B", @"C", @"D", @"E"]));
}

- (void)testGeneralSequenceHandlesBothSidesNonContiguous {
    // {1,3} -> {0,2} of four: gather to the front, then scatter out — checked
    // against the remove/insert reference, within the 2k move bound.
    NSArray<NSString *> *list = @[@"A", @"B", @"C", @"D"];
    NSIndexSet *sources = Rows(@[@1u, @3u]);
    NSIndexSet *destinations = Rows(@[@0u, @2u]);
    NSUInteger pairCount = 0;
    NSArray<NSString *> *applied = ApplySequence(list, sources, destinations, &pairCount);
    XCTAssertEqualObjects(applied, ReferenceMoveToSet(list, sources, destinations));
    XCTAssertEqualObjects(applied, (@[@"B", @"A", @"D", @"C"]));
    XCTAssertLessThanOrEqual(pairCount, 2 * sources.count);
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
            NSIndexSet *landed = Range(destination, sources.count);
            NSArray<NSString *> *applied = ApplySequence(list, sources, landed, &pairCount);
            XCTAssertEqualObjects(applied, ReferenceMove(list, sources, destination),
                                  @"sources %@ slot %ld", sources, (long)slot);
            XCTAssertLessThanOrEqual(pairCount, sources.count,
                                     @"sources %@ slot %ld", sources, (long)slot);
            // And every gather's swapped-set scatter is its exact undo.
            XCTAssertEqualObjects(ApplySequence(applied, landed, sources, NULL), list,
                                  @"inverse of sources %@ slot %ld", sources, (long)slot);
        }
    }
}

- (void)testSingleRowSequenceIsOnePairMatchingTheDecision {
    NSUInteger destination;
    XCTAssertEqual(VibePlaylistDropDecisionForSlot(Rows(@[@3u]), 1, 5, &destination),
                   VibePlaylistDropMove);
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(Rows(@[@3u]), Range(destination, 1), ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@3u, @1u]]));
}

@end
