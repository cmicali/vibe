//
//  PlaylistDragRules.h
//  Vibe
//
//  The drag-reorder arithmetic, AppKit-free so host-less tests own its
//  off-by-ones.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL VibePlaylistIndexesAreContiguous(NSIndexSet *indexes) {
    return indexes.lastIndex - indexes.firstIndex + 1 == indexes.count;
}

// Converts an AppKit insertion slot (0..count, NSTableViewDropAbove) into the
// contiguous FINAL positions the dragged rows land at: the slot minus the
// sources above it, the downward off-by-one solved once. nil for malformed
// input or a no-op — a contiguous block dropped onto or beside itself, or
// every row at once; a non-contiguous set is never a no-op. count is the row
// count before the move.
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

// The single-row (from, to) moves that gather sourceIndexes contiguously at
// finalDestination, in EVOLVING coordinates: apply one before the next. Rows
// above the line sink to just above it, each extraction shifting the sources
// still to come; rows below stack under it in order. Callers use
// VibePlaylistMoveSequenceEnumerate.
static inline void
VibePlaylistGatherSequenceEnumerate(NSIndexSet *_Nullable sourceIndexes,
                                    NSUInteger finalDestination,
                                    void (NS_NOESCAPE ^enumerator)(NSUInteger from, NSUInteger to)) {
    // The unique slot whose preceding-source count subtracts back to
    // finalDestination.
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

// The moveRowAtIndex:toIndex: calls, in order and EVOLVING coordinates, that
// realize the model's move of sourceIndexes to destinationIndexes. One side is
// always contiguous: a gather (the drag) or its undo, a scatter, which is the
// reverse gather's pairs reversed and swapped. Emits nothing for input the
// model would refuse.
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
