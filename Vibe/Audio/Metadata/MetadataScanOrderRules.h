//
//  MetadataScanOrderRules.h
//  Vibe
//
//  Which pending scan miss is materialized next. Because that lane admits one
//  file at a time, this ordering is the whole of what it decides — the tail
//  included: without an explicit tail order, a folder of large evicted files
//  downloads in whatever order the four stage-1 workers happen to finish.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MetadataScanOrderCandidate <NSObject>
@property (nonatomic, readonly) BOOL local;
@property (nonatomic, readonly) BOOL deferred;
@property (nonatomic, readonly) NSUInteger playlistIndex;
@property (nonatomic, readonly, copy) NSURL *url;
// A priority submission of this record came back Yielded while the foreground
// rule was in force; the record waits for an idle re-pick rather than
// spinning against the coordinator's synchronous yield (MetadataRetryRules.h).
@property (nonatomic, readonly) BOOL yieldedUnderHold;
@end

// local — the file's contents are already on disk — leads every other key: its
// materialization is a no-op, so on a partially downloaded folder every local
// row's tags land before a single download is chosen, deferred retries
// included. rank is the URL's position in the neighborhood — next, second-next,
// previous — or NSNotFound past it, which sorts last by being the largest
// NSUInteger. index is the entry's playlist row, stamped when the sweep was
// built. A deferred retry sorts below everything else: it has already failed
// once, so every track that has not tried yet goes first, however the
// neighborhood moves.
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

// The priority slot's own pick: among the records whose URL a shell
// prioritized, an untried record beats a deferred retry, then the lowest
// playlist row wins (NSNotFound — a record minted outside the sweep — sorts
// last by being the largest NSUInteger). While the foreground rule is in
// force, a record it already yielded is skipped: re-picking it would spin
// against the coordinator's synchronous yield, so it waits for the first
// idle re-pick. Neighborhood rank deliberately plays no part — priority
// records are the current track and at most a convert target, and their own
// slot is the whole of their precedence.
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

// Exact one-pass selection from everything still pending.
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
