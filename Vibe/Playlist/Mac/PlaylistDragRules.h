//
//  PlaylistDragRules.h
//  Vibe
//
//  The internal drag-reorder arithmetic, kept out of the AppKit delegate so
//  host-less tests own its off-by-ones: what a proposed insertion slot means
//  for a set of dragged rows, and which single-row table moves realize an
//  accepted drop. Pure functions of their arguments; nothing here mutates the
//  playlist or imports AppKit.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL VibePlaylistIndexesAreContiguous(NSIndexSet *indexes) {
    return indexes.lastIndex - indexes.firstIndex + 1 == indexes.count;
}

// Converts an AppKit insertion slot (0..count, from an NSTableViewDropAbove
// validation) into the model's landing set: the contiguous FINAL positions the
// dragged rows would occupy. The downward off-by-one is solved here once — the
// dragged rows vacate their positions above the slot, so the landing starts at
// the slot minus however many sources precede it. nil when no move should be
// offered: malformed input (an empty or out-of-range source set, a slot
// outside 0..count), or a slot that would leave the order unchanged — a
// contiguous block dropped onto or immediately beside itself, or every row
// dragged at once. A non-contiguous set is never a no-op: gathering it moves
// the survivors between its members wherever it lands. sourceIndexes are the
// dragged rows in current coordinates; count is the row count before the move.
static inline NSIndexSet *_Nullable
VibePlaylistDropDestinationForSlot(NSIndexSet *_Nullable sourceIndexes,
                                   NSInteger proposedSlot,
                                   NSUInteger count) {
    NSUInteger moving = sourceIndexes.count;
    if (moving == 0 || sourceIndexes.lastIndex >= count
            || proposedSlot < 0 || (NSUInteger)proposedSlot > count) {
        return nil;
    }
    NSUInteger slot = (NSUInteger)proposedSlot;
    NSUInteger destination = slot - [sourceIndexes countOfIndexesInRange:NSMakeRange(0, slot)];
    if (VibePlaylistIndexesAreContiguous(sourceIndexes)
            && destination == sourceIndexes.firstIndex) {
        return nil;
    }
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(destination, moving)];
}

// The gather half of the sequence arithmetic: the single-row (from, to) moves
// that land the rows at sourceIndexes contiguously with the first at
// finalDestination. Each pair is in EVOLVING coordinates: apply one before
// computing against the next. Rows above the insertion line move down to sit
// just above it, each extraction shifting the sources still to come; rows
// below keep their original position — everything extracted before them
// re-landed above — and stack under the line in order. Callers use
// VibePlaylistMoveSequenceEnumerate below, which dispatches here.
static inline void
VibePlaylistGatherSequenceEnumerate(NSIndexSet *_Nullable sourceIndexes,
                                    NSUInteger finalDestination,
                                    void (NS_NOESCAPE ^enumerator)(NSUInteger from, NSUInteger to)) {
    // Recover the insertion slot the destination was derived from: the unique
    // slot whose preceding-source count subtracts back to finalDestination.
    __block NSUInteger slot = finalDestination;
    [sourceIndexes enumerateIndexesUsingBlock:^(NSUInteger source, BOOL *stop) {
        if (source < slot) {
            slot += 1;
        } else {
            *stop = YES;
        }
    }];
    __block NSInteger extractedAbove = 0;
    __block NSUInteger landedBelow = 0;
    NSUInteger lineSlot = slot;
    [sourceIndexes enumerateIndexesUsingBlock:^(NSUInteger source, BOOL *stop) {
        NSUInteger from, to;
        if (source < lineSlot) {
            from = (NSUInteger)((NSInteger)source + extractedAbove);
            to = lineSlot - 1;
            extractedAbove -= 1;
        } else {
            from = source;
            to = lineSlot + landedBelow;
            landedBelow += 1;
        }
        if (from != to) {
            enumerator(from, to);
        }
    }];
}

// Emits, in application order, the single-row (from, to) moves that transform
// a list so the rows at sourceIndexes occupy destinationIndexes — the model's
// remove-at-A-insert-at-B semantics, realized as the moveRowAtIndex:toIndex:
// calls a table applies so row views survive. Pairs are in EVOLVING
// coordinates. One side is always contiguous, because every move is a gather
// or a gather's undo: a contiguous destination is the drag collecting its
// selection, and a contiguous source scattering outward is that move with its
// sets swapped, derived as the inverse of the gather that would collect the
// destinations back into the block — each moveRow's inverse swaps its
// coordinates, so the inverse sequence is the gather's pairs reversed and
// swapped. Emits nothing for inputs the model would refuse.
static inline void
VibePlaylistMoveSequenceEnumerate(NSIndexSet *_Nullable sourceIndexes,
                                  NSIndexSet *_Nullable destinationIndexes,
                                  void (NS_NOESCAPE ^enumerator)(NSUInteger from, NSUInteger to)) {
    NSUInteger moving = sourceIndexes.count;
    if (moving == 0 || destinationIndexes.count != moving) {
        return;
    }
    if (VibePlaylistIndexesAreContiguous(destinationIndexes)) {
        VibePlaylistGatherSequenceEnumerate(sourceIndexes, destinationIndexes.firstIndex,
                                            enumerator);
        return;
    }
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray arrayWithCapacity:moving];
    VibePlaylistGatherSequenceEnumerate(destinationIndexes, sourceIndexes.firstIndex,
                                        ^(NSUInteger from, NSUInteger to) {
        [pairs addObject:@[@(from), @(to)]];
    });
    for (NSArray<NSNumber *> *pair in pairs.reverseObjectEnumerator) {
        enumerator(pair[1].unsignedIntegerValue, pair[0].unsignedIntegerValue);
    }
}

NS_ASSUME_NONNULL_END
