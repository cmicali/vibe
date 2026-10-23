//
//  LegacyCacheStores.h
//  Vibe
//
//  The removal of the disk cache stores that other builds left behind.
//

#import <Foundation/Foundation.h>
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"

NS_ASSUME_NONNULL_BEGIN

// Removes every store in cachesDirectory that shares a current store's name
// apart from its version suffix (" v8", "_v7") and is not that store. A name
// with no suffix is a version too. So a version bump needs no edit here.
// Synchronous: it lists the directory and removes whole stores.
FOUNDATION_EXTERN void VibeRemoveLegacyCacheStores(NSString *cachesDirectory,
                                                   NSArray<NSString *> *currentStoreNames);

// Each shell calls this once at launch. Inline, so VibeTests compiles the
// rule without the metadata cache.
static inline void VibeRemoveLegacyCacheStoresOffMain(void) {
    NSArray<NSString *> *current = @[AudioTrackMetadataCache.cacheName, AudioWaveformCache.cacheName];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (caches) {
            VibeRemoveLegacyCacheStores(caches, current);
        }
    });
}

NS_ASSUME_NONNULL_END
