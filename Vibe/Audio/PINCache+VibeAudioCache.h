//
//  PINCache+VibeAudioCache.h
//  Vibe
//
//  The disk-cache policy shared by the two PINDiskCache-backed stores,
//  AudioTrackMetadataCache and AudioWaveformCache. One home stops the policies
//  drifting: both key off the same file identity, through NSURL+Hash, and their
//  entries should live and die on the same terms.
//

#import <Foundation/Foundation.h>
#import "PINCache.h"

NS_ASSUME_NONNULL_BEGIN

@interface PINCache (VibeAudioCache)

// A store with the shared byte and age limits applied, under rootPath, nil for
// the user's caches. memoryByteLimit 0 means disk only: the store reads and
// writes diskCache directly. Otherwise memoryCache holds that many bytes of
// entries, least recently used evicted first.
// TRAP: never PINCache's own objectForKey: or setObject:forKey: on a store
// with a memory limit. Both enter memory at cost 0, which costLimit never
// evicts, and on macOS PINMemoryCache has no memory-pressure hook either, so
// every entry ever read would stay pinned for the app's lifetime. Read with
// audioObjectForKey:cost:, write with setObject:forKey:withCost:.
+ (PINCache *)audioCacheWithName:(NSString *)name
                        rootPath:(nullable NSString *)rootPath
                 memoryByteLimit:(NSUInteger)memoryByteLimit;

// Memory, then disk. A disk hit enters memory at the cost the block returns
// for it; a memory hit touches the disk entry, so the disk's LRU and age limit
// see the play. Blocks on a disk read, so never call it on main.
- (nullable id)audioObjectForKey:(NSString *)key cost:(NSUInteger (^)(id object))cost;

// Entry count and total bytes on disk. The enumeration blocks, so call it on
// the store's own serial queue; the completion is dispatched to the main thread.
- (void)audioDiskUsageWithCompletion:(void (^)(NSUInteger fileCount,
                                               unsigned long long totalBytes))completion;

@end

NS_ASSUME_NONNULL_END
