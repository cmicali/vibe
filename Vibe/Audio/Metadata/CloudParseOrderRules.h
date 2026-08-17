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

NS_ASSUME_NONNULL_END
