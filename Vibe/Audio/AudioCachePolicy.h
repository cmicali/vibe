//
// AudioCachePolicy.h
// Vibe
//
// The disk-cache policy shared by the two PINDiskCache-backed stores,
// AudioTrackMetadataCache and AudioWaveformCache. Keeping it in one home stops
// the policies drifting: both caches key off the same file identity, through
// NSURL+Hash, and their entries should live and die on the same terms.
//

#import <Foundation/Foundation.h>
#import "PINCache.h"

// The per-cache disk budget. Entries are small — roughly 5-20KB for a metadata
// archive and 64KB for a waveform — so this holds thousands of tracks before
// LRU eviction starts.
static const NSUInteger kAudioCacheByteLimit = 64 * 1024 * 1024;

// Entries untouched for this long are evicted. A rewritten or moved file
// leaves an orphaned entry whose size-and-mtime key never matches again, and
// that must not sit in the byte budget forever.
static const NSTimeInterval kAudioCacheAgeLimit = 6 * (30 * (24 * 60 * 60)); // 6 months

// Applies the shared limits to a freshly constructed store. The memory cache
// is deliberately unused by both stores, which read and write diskCache
// directly: on macOS PINMemoryCache never evicts — costLimit needs per-entry
// costs, disk hits repopulate at cost 0, and its memory-pressure hooks are
// iOS-only — so it would pin every entry ever loaded for the app's lifetime.
static inline PINCache *VibeAudioCacheCreate(NSString *name) {
    PINCache *cache = [[PINCache alloc] initWithName:name];
    cache.diskCache.byteLimit = kAudioCacheByteLimit;
    cache.diskCache.ageLimit = kAudioCacheAgeLimit;
    return cache;
}

// The shared body of both stores' diskUsageWithCompletion:. The enumeration
// blocks, so call it on the store's own serial queue; the completion is
// dispatched to the main thread.
static inline void VibeAudioCacheDiskUsage(PINCache *cache,
        void (^completion)(NSUInteger fileCount, unsigned long long totalBytes)) {
    __block NSUInteger count = 0;
    __block unsigned long long bytes = 0;
    [cache.diskCache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
        count++;
        NSNumber *size = nil;
        if ([fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil]) {
            bytes += size.unsignedLongLongValue;
        }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(count, bytes);
    });
}
