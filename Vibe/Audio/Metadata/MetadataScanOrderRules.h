//
//  MetadataScanOrderRules.h
//  Vibe
//
//  Which pending scan miss materializes next. The scan submits one at a time,
//  so this order decides everything, the tail included.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MetadataScanOrderCandidate <NSObject>
@property (nonatomic, readonly) BOOL local;
@property (nonatomic, readonly) BOOL deferred;
@property (nonatomic, readonly) NSUInteger playlistIndex;
@property (nonatomic, readonly, copy) NSURL *url;
// Yielded under the rule; waits for an idle re-pick (MetadataRetryRules.h).
@property (nonatomic, readonly) BOOL yieldedUnderHold;
@end

// Local first (a no-op materialization, so every local row lands before any
// download), then untried before deferred, then neighborhood rank (NSNotFound
// sorts last), then playlist row.
static inline BOOL VibeMetadataScanOrderedBefore(
        BOOL aLocal, BOOL aDeferred, NSUInteger aRank, NSUInteger aIndex,
        BOOL bLocal, BOOL bDeferred, NSUInteger bRank, NSUInteger bIndex) {
    if (aLocal != bLocal) {
        return aLocal;
    }
    if (aDeferred != bDeferred) {
        return !aDeferred;
    }
    if (aRank != bRank) {
        return aRank < bRank;
    }
    return aIndex < bIndex;
}

// The priority slot's pick: untried before deferred, then lowest playlist
// row. Under the rule a record it already yielded is skipped. Rank plays no
// part: the slot is their whole precedence.
static inline id<MetadataScanOrderCandidate> _Nullable VibeBestPriorityScanCandidate(
        NSArray<id<MetadataScanOrderCandidate>> *candidates,
        NSSet<NSURL *> *priorityURLs,
        BOOL foregroundActive) {
    if (priorityURLs.count == 0) {
        return nil;
    }
    id<MetadataScanOrderCandidate> best = nil;
    for (id<MetadataScanOrderCandidate> candidate in candidates) {
        if (![priorityURLs containsObject:candidate.url]) {
            continue;
        }
        if (foregroundActive && candidate.yieldedUnderHold) {
            continue;
        }
        if (!best
                || (best.deferred && !candidate.deferred)
                || (best.deferred == candidate.deferred
                        && candidate.playlistIndex < best.playlistIndex)) {
            best = candidate;
        }
    }
    return best;
}

// One pass; nothing is sorted.
static inline id<MetadataScanOrderCandidate> _Nullable VibeBestMetadataScanCandidate(
        NSArray<id<MetadataScanOrderCandidate>> *candidates,
        NSArray<NSURL *> *neighborhood) {
    NSMutableDictionary<NSURL *, NSNumber *> *rankByURL =
            [NSMutableDictionary dictionaryWithCapacity:neighborhood.count];
    [neighborhood enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger rank, BOOL *stop) {
        if (rankByURL[url] == nil) {
            rankByURL[url] = @(rank);
        }
    }];

    id<MetadataScanOrderCandidate> best = nil;
    NSUInteger bestRank = NSNotFound;
    for (id<MetadataScanOrderCandidate> candidate in candidates) {
        NSNumber *found = rankByURL[candidate.url];
        NSUInteger rank = found != nil ? found.unsignedIntegerValue : NSNotFound;
        if (!best || VibeMetadataScanOrderedBefore(
                candidate.local, candidate.deferred, rank, candidate.playlistIndex,
                best.local, best.deferred, bestRank, best.playlistIndex)) {
            best = candidate;
            bestRank = rank;
        }
    }
    return best;
}

NS_ASSUME_NONNULL_END
