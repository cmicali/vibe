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

// The priority slot's pick among the priority records: untried before
// deferred, then lowest playlist row. Under the rule a record it already
// yielded is skipped. Rank plays no part: the slot is their whole precedence.
static inline id<MetadataScanOrderCandidate> _Nullable VibeBestPriorityScanCandidate(
        NSArray<id<MetadataScanOrderCandidate>> *candidates,
        BOOL foregroundActive) {
    id<MetadataScanOrderCandidate> best = nil;
    for (id<MetadataScanOrderCandidate> candidate in candidates) {
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

// The URL's first place in the neighborhood, NSNotFound when absent.
// Compared directly: the neighborhood holds three URLs.
static inline NSUInteger VibeMetadataScanNeighborhoodRank(NSURL *url, NSArray<NSURL *> *neighborhood) {
    NSUInteger rank = 0;
    for (NSURL *neighbor in neighborhood) {
        if (neighbor == url || [neighbor isEqual:url]) {
            return rank;
        }
        rank++;
    }
    return NSNotFound;
}

// One pass, nothing sorted or copied: the index of the best candidate skip
// leaves in, or NSNotFound. rankOf answers a candidate's neighborhood rank
// (VibeMetadataScanNeighborhoodRank), so a caller picking again and again
// under one neighborhood can remember it rather than compare URLs per pick.
static inline NSUInteger VibeBestMetadataScanCandidateIndex(
        NSArray<id<MetadataScanOrderCandidate>> *candidates,
        NSUInteger (NS_NOESCAPE ^rankOf)(id<MetadataScanOrderCandidate> candidate),
        BOOL (NS_NOESCAPE ^ _Nullable skip)(id<MetadataScanOrderCandidate> candidate)) {
    NSUInteger bestIndex = NSNotFound;
    BOOL bestLocal = NO;
    BOOL bestDeferred = NO;
    NSUInteger bestRank = NSNotFound;
    NSUInteger bestPlaylistIndex = NSNotFound;
    NSUInteger count = candidates.count;
    for (NSUInteger index = 0; index < count; index++) {
        id<MetadataScanOrderCandidate> candidate = candidates[index];
        if (skip && skip(candidate)) {
            continue;
        }
        BOOL local = candidate.local;
        BOOL deferred = candidate.deferred;
        NSUInteger rank = rankOf(candidate);
        NSUInteger playlistIndex = candidate.playlistIndex;
        if (bestIndex == NSNotFound || VibeMetadataScanOrderedBefore(
                local, deferred, rank, playlistIndex,
                bestLocal, bestDeferred, bestRank, bestPlaylistIndex)) {
            bestIndex = index;
            bestLocal = local;
            bestDeferred = deferred;
            bestRank = rank;
            bestPlaylistIndex = playlistIndex;
        }
    }
    return bestIndex;
}

NS_ASSUME_NONNULL_END
