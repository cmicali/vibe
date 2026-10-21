//
//  MetadataScanEntry.h
//  Vibe
//
//  The metadata loader's two records: one file's scan entry and one
//  priority mark. Private to the loader's files.
//

#import <Foundation/Foundation.h>
#import "MetadataScanOrderRules.h"
#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

// One file from cache check to materialization, with every row sharing its
// standardized path. A successful parse settles them all; after a failure
// the remaining rows may retry. A plain record, never a pre-built
// operation, so everything pending stays re-rankable. The current track's file
// is the same record holding a marked row, a second slot rather than a second
// lane, so playlist replacement drops it like any row.
@interface MetadataScanEntry : NSObject <MetadataScanOrderCandidate>
// Never empty. Replaced whole under _materializationLock, and read off it only
// while no other thread can replace it: before the record is published, or
// once picked.
@property (nonatomic, copy, nonnull) NSArray<id<VibePlayableItem>> *tracks;
// The first row's: any spelling reaches the file.
@property (nonatomic, copy, readonly, nonnull) NSURL *url;
@property (nonatomic, copy, readonly, nonnull) NSString *standardizedPath;
// The first row's, the equal-rank tie-break; without it the tail downloads in
// stage-1 completion order. NSNotFound, sorting last, for a record
// prioritizeTrack: made outside the sweep.
@property (nonatomic) NSUInteger playlistIndex;
// A retry after a failure: below every untried record, however the
// neighborhood moves.
@property (nonatomic) BOOL deferred;
// On disk at the last probe: leads the order and is exempt from the hold.
// Re-probed at every enqueue, submit and requeue, since the playback open
// downloading this very file is how it usually flips.
@property (nonatomic) BOOL local;
// A priority submission yielded under the hold; the record waits for a
// gated tick to re-judge it (MetadataRetryRules.h).
@property (nonatomic) BOOL yieldedUnderHold;
// The rank under the neighborhood neighborhoodRankGeneration names, kept
// across picks: the neighborhood moves per track, the sweep picks per file,
// and ranking compares URLs. Under _materializationLock.
@property (nonatomic) NSUInteger neighborhoodRank;
@property (nonatomic) NSUInteger neighborhoodRankGeneration;
// The prioritizeTrack: edge this record carried when its slot was claimed. An
// off-lock probe's result acts only while this still matches the row's mark.
@property (nonatomic) NSUInteger priorityMarkGeneration;
- (instancetype)initWithTracks:(NSArray<id<VibePlayableItem>> *)tracks
              standardizedPath:(NSString *)standardizedPath
                 playlistIndex:(NSUInteger)playlistIndex;
- (BOOL)holdsTrack:(id<VibePlayableItem>)track;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface MetadataPriorityMark : NSObject
@property(nonatomic) NSUInteger markGeneration;
@property(nonatomic, strong) id<VibePlayableItem> track;
@end

NS_ASSUME_NONNULL_END
