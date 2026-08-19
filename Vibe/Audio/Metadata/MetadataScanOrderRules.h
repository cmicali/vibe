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
@property (nonatomic, readonly) BOOL deferred;
@property (nonatomic, readonly) NSUInteger playlistIndex;
@property (nonatomic, readonly, copy) NSURL *url;
@end

// rank is the URL's position in the neighborhood — next, second-next,
// previous — or NSNotFound past it, which sorts last by being the largest
// NSUInteger. index is the entry's playlist row, stamped when the sweep was
// built. A deferred retry sorts below everything: it has already failed once,
// so every track that has not tried yet goes first, however the neighborhood
// moves.
static inline BOOL VibeMetadataScanOrderedBefore(
        BOOL aDeferred, NSUInteger aRank, NSUInteger aIndex,
        BOOL bDeferred, NSUInteger bRank, NSUInteger bIndex) {
    if (aDeferred != bDeferred) {
        return !aDeferred;
    }
    if (aRank != bRank) {
        return aRank < bRank;
    }
    return aIndex < bIndex;
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
                candidate.deferred, rank, candidate.playlistIndex,
                best.deferred, bestRank, best.playlistIndex)) {
            best = candidate;
            bestRank = rank;
        }
    }
    return best;
}

NS_ASSUME_NONNULL_END
