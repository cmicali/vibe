//
//  CloudParseOrderRules.h
//  Vibe
//
//  Which pending cloud parse the serial lane runs next. Because that lane is
//  one download at a time, this ordering is the whole of what it decides —
//  and the tail used to have none: every non-neighborhood entry shared one
//  NSOperationQueue priority, whose ties the queue resolves arbitrarily, so a
//  folder of large evicted files downloaded in whatever order the four
//  stage-1 workers happened to finish.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol VibeCloudParseOrderCandidate <NSObject>
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
static inline BOOL VibeCloudParseOrderedBefore(
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

// Exact one-pass selection from everything still pending. Excluding a URL
// excludes every duplicate row for that path at once; otherwise a fixed-size
// candidate window can be filled by duplicates of one blocked path and park
// even though an unblocked entry exists immediately after the window.
static inline id<VibeCloudParseOrderCandidate> _Nullable VibeBestCloudParseCandidate(
        NSArray<id<VibeCloudParseOrderCandidate>> *candidates,
        NSArray<NSURL *> *neighborhood,
        NSSet<NSURL *> *excludedURLs) {
    NSMutableDictionary<NSURL *, NSNumber *> *rankByURL =
            [NSMutableDictionary dictionaryWithCapacity:neighborhood.count];
    [neighborhood enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger rank, BOOL *stop) {
        if (rankByURL[url] == nil) {
            rankByURL[url] = @(rank);
        }
    }];

    id<VibeCloudParseOrderCandidate> best = nil;
    NSUInteger bestRank = NSNotFound;
    for (id<VibeCloudParseOrderCandidate> candidate in candidates) {
        if ([excludedURLs containsObject:candidate.url]) {
            continue;
        }
        NSNumber *found = rankByURL[candidate.url];
        NSUInteger rank = found != nil ? found.unsignedIntegerValue : NSNotFound;
        if (!best || VibeCloudParseOrderedBefore(
                candidate.deferred, rank, candidate.playlistIndex,
                best.deferred, bestRank, best.playlistIndex)) {
            best = candidate;
            bestRank = rank;
        }
    }
    return best;
}

NS_ASSUME_NONNULL_END
