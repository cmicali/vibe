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

static NSIndexSet *RowSetOf(NSArray<NSNumber *> *rows) {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (NSNumber *row in rows) {
        [indexes addIndex:row.unsignedIntegerValue];
    }
    return indexes;
}

static NSIndexSet *RowRange(NSUInteger location, NSUInteger length) {
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(location, length)];
}

// The reference the sequence must reproduce: the model's own remove-at-A,
// insert-at-B semantics.
static NSArray<NSString *> *ReferenceMove(NSArray<NSString *> *list,
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

#pragma mark - Drop destination

- (void)testSingleRowDestinationAtEverySlot {
    // Dragging row 1 of 4: slots 1 and 2 bracket the row itself and offer
    // nothing; a slot past the source subtracts the vacated row.
    NSIndexSet *source = RowSetOf(@[@1u]);
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 0, 4), RowRange(0, 1));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(source, 1, 4));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(source, 2, 4));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 3, 4), RowRange(2, 1));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 4, 4), RowRange(3, 1));
}

- (void)testContiguousBlockNoOpSlotsSpanTheBlockAndBothEdges {
    // Dragging rows 1-2 of 5: every slot from the block's first row through
    // one past its last leaves the order unchanged, so no move is offered.
    NSIndexSet *source = RowSetOf(@[@1u, @2u]);
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 0, 5), RowRange(0, 2));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(source, 1, 5));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(source, 2, 5));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(source, 3, 5));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 4, 5), RowRange(2, 2));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(source, 5, 5), RowRange(3, 2));
}

- (void)testNonContiguousSetIsNeverANoOp {
    // Even landing at its own first row gathers the set, which moves the
    // survivor out from between its members.
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u, @2u]), 0, 3),
                          RowRange(0, 2));
    // And each slot inside the set subtracts only the sources above it.
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(RowSetOf(@[@1u, @3u]), 2, 5),
                          RowRange(1, 2));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(RowSetOf(@[@1u, @3u]), 5, 5),
                          RowRange(3, 2));
}

- (void)testDraggingEveryRowOffersNoMove {
    NSIndexSet *all = RowSetOf(@[@0u, @1u, @2u]);
    for (NSInteger slot = 0; slot <= 3; slot++) {
        XCTAssertNil(VibePlaylistDropDestinationForSlot(all, slot, 3), @"slot %ld", (long)slot);
    }
}

- (void)testOneRowPlaylistOffersNoMove {
    XCTAssertNil(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u]), 0, 1));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u]), 1, 1));
}

- (void)testMalformedInputsOfferNoMove {
    XCTAssertNil(VibePlaylistDropDestinationForSlot(nil, 0, 3));
    XCTAssertNil(VibePlaylistDropDestinationForSlot([NSIndexSet indexSet], 0, 3));
    // A member at count is out of range, not the legal edge slot.
    XCTAssertNil(VibePlaylistDropDestinationForSlot(RowSetOf(@[@3u]), 0, 3));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u]), -1, 3));
    XCTAssertNil(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u]), 4, 3));
}

- (void)testAllButOneRowMovesInBothDirections {
    // Dragging rows 1-3 of 4 to slot 0: the block lands first. Rows 0-2 to
    // slot 4: the block lands after the survivor.
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(RowSetOf(@[@1u, @2u, @3u]), 0, 4),
                          RowRange(0, 3));
    XCTAssertEqualObjects(VibePlaylistDropDestinationForSlot(RowSetOf(@[@0u, @1u, @2u]), 4, 4),
                          RowRange(1, 3));
}

#pragma mark - Move sequence

- (void)testSequencePinsTheWorkedExamples {
    NSArray<NSString *> *list = @[@"A", @"B", @"C", @"D", @"E"];

    // {1,3} -> [0,2): two up-movers stack under the line.
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(RowSetOf(@[@1u, @3u]), RowRange(0, 2),
                                      ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@1u, @0u], @[@3u, @1u]]));

    // {0,4} -> [2,4): one down-mover to the line's underside, one up-mover.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(RowSetOf(@[@0u, @4u]), RowRange(2, 2),
                                      ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @2u], @[@4u, @3u]]));

    // {0,1} -> [3,5) downward: the second extraction's index has shifted up.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(RowSetOf(@[@0u, @1u]), RowRange(3, 2),
                                      ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @4u], @[@0u, @4u]]));
    XCTAssertEqualObjects(ApplySequence(list, RowSetOf(@[@0u, @1u]), RowRange(3, 2), NULL),
                          (@[@"C", @"D", @"E", @"A", @"B"]));

    // {0,2,4} -> [1,4): the source already in place emits nothing.
    [pairs removeAllObjects];
    VibePlaylistMoveSequenceEnumerate(RowSetOf(@[@0u, @2u, @4u]), RowRange(1, 3),
                                      ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@0u, @1u], @[@4u, @3u]]));
}

- (void)testScatterSequenceIsTheGatherReversedAndSwapped {
    // The undo shape: the gathered block [0,2) scatters back to {1,3} — the
    // gather's pairs (1,0),(3,1) reversed with from/to swapped.
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    VibePlaylistMoveSequenceEnumerate(RowRange(0, 2), RowSetOf(@[@1u, @3u]),
                                      ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    XCTAssertEqualObjects(pairs, (@[@[@1u, @3u], @[@0u, @1u]]));
    // Applied to the gathered list, it restores the original.
    XCTAssertEqualObjects(ApplySequence(@[@"B", @"D", @"A", @"C", @"E"],
                                        RowRange(0, 2), RowSetOf(@[@1u, @3u]), NULL),
                          (@[@"A", @"B", @"C", @"D", @"E"]));
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
        NSIndexSet *sources = RowSetOf(sourceCase);
        for (NSInteger slot = 0; slot <= (NSInteger)list.count; slot++) {
            NSIndexSet *landed = VibePlaylistDropDestinationForSlot(sources, slot, list.count);
            if (!landed) {
                continue;
            }
            NSUInteger pairCount = 0;
            NSArray<NSString *> *applied = ApplySequence(list, sources, landed, &pairCount);
            XCTAssertEqualObjects(applied, ReferenceMove(list, sources, landed),
                                  @"sources %@ slot %ld", sources, (long)slot);
            XCTAssertLessThanOrEqual(pairCount, sources.count,
                                     @"sources %@ slot %ld", sources, (long)slot);
            // And every gather's swapped-set scatter is its exact undo.
            XCTAssertEqualObjects(ApplySequence(applied, landed, sources, NULL), list,
                                  @"inverse of sources %@ slot %ld", sources, (long)slot);
        }
    }
}

@end
