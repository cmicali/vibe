//
//  FileSearchIndexInternal.h
//  Vibe (iOS)
//
//  The root pruning behind setRoots:, exposed so the unit tests can drive it
//  without a file system: through the index alone the walk, its queue and the
//  main-thread hop stand between every assertion and which trees it chose.
//  Do not import it outside FileSearchIndex.m and its tests.
//

#import "FileSearchIndex.h"

NS_ASSUME_NONNULL_BEGIN

@interface FileSearchIndex (Internal)

// The roots to walk: the given ones with every root covered by another removed,
// in either direction, ancestors kept. Nothing here touches the disk.
+ (NSArray<NSURL *> *)pruneNestedRoots:(NSArray<NSURL *> *)roots;

@end

NS_ASSUME_NONNULL_END
