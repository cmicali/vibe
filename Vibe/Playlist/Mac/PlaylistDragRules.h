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

typedef NS_ENUM(NSInteger, VibePlaylistDropDecision) {
    // Malformed input — an empty or out-of-range source set, or a slot
    // outside 0..count. No operation is offered.
    VibePlaylistDropRejected,
    // A legal slot that would leave the order unchanged: a contiguous block
    // dropped onto or immediately beside itself, or every row dragged at
    // once. Offering a move here would pretend to perform one.
    VibePlaylistDropNoOp,
    // Perform the move; *finalDestination is Playlist's input.
    VibePlaylistDropMove,
};

// Converts an AppKit insertion slot (0..count, from an NSTableViewDropAbove
// validation) into the model's coordinate: the FINAL index of the first moved
// row after the move. The downward off-by-one is solved here once — the
// dragged rows vacate their positions above the slot, so the destination is
// the slot minus however many sources precede it. sourceIndexes are the
// dragged rows in current coordinates; count is the row count before the move.
static inline VibePlaylistDropDecision
VibePlaylistDropDecisionForSlot(NSIndexSet *_Nullable sourceIndexes,
                                NSInteger proposedSlot,
                                NSUInteger count,
                                NSUInteger *finalDestination) {
    NSUInteger moving = sourceIndexes.count;
    if (moving == 0 || sourceIndexes.lastIndex >= count
            || proposedSlot < 0 || (NSUInteger)proposedSlot > count) {
        return VibePlaylistDropRejected;
    }
    NSUInteger slot = (NSUInteger)proposedSlot;
    NSUInteger destination = slot - [sourceIndexes countOfIndexesInRange:NSMakeRange(0, slot)];
    // A contiguous block landing on its own first row changes nothing, and
    // every slot from the block's first row through one past its last resolves
    // to exactly that destination. A non-contiguous set never qualifies:
    // gathering it moves the survivors between its members wherever it lands.
    BOOL contiguous = sourceIndexes.lastIndex - sourceIndexes.firstIndex + 1 == moving;
    if (contiguous && destination == sourceIndexes.firstIndex) {
        return VibePlaylistDropNoOp;
    }
    *finalDestination = destination;
    return VibePlaylistDropMove;
}

// Emits, in application order, the single-row (from, to) moves that transform
// a list so the rows at sourceIndexes land contiguously with the first at
// finalDestination — the calls a table applies as moveRowAtIndex:toIndex: so
// row views survive. Each pair is in EVOLVING coordinates: apply one before
// computing against the next. Rows above the insertion line move down to sit
// just above it, each extraction shifting the sources still to come; rows
// below keep their original position — everything extracted before them
// re-landed above — and stack under the line in order. Emits nothing for
// inputs the drop decision would not have accepted.
static inline void
VibePlaylistMoveSequenceEnumerate(NSIndexSet *_Nullable sourceIndexes,
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

NS_ASSUME_NONNULL_END
