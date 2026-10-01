//
//  VibePerfDiskCache.mm
//  VibePerf
//
//  PINDiskCache on Vibe's terms: hits, writes, a full cache's writes and a
//  launch's open.
//

#import "VibePerf.h"

#import <PINCache/PINDiskCache.h>
#import <PINOperation/PINOperation.h>

#include <memory>
#include <vector>

// MARK: - The disk cache

struct VibePerfDiskCache {
    PINDiskCache *cache;
    PINOperationQueue *queue;
    NSString *root;
    std::vector<NSString *> keys;
    NSUInteger next = 0;
};

// Vibe's audio caches' terms: least recently used, not TTL, an age limit.
static PINDiskCache *VibePerfMakeDiskCache(NSString *root, PINOperationQueue *queue, NSUInteger byteLimit) {
    return [[PINDiskCache alloc] initWithName:@"bench" prefix:@"com.vibe.perf" rootPath:root
                                   serializer:nil deserializer:nil keyEncoder:nil keyDecoder:nil
                               operationQueue:queue ttlCache:NO byteLimit:byteLimit
                                     ageLimit:6 * 30 * 24 * 3600
                             evictionStrategy:PINCacheEvictionStrategyLeastRecentlyUsed];
}

// A metadata archive's size.
static NSData *VibePerfEntryData(NSUInteger seed) {
    NSMutableData *data = [NSMutableData dataWithLength:16 * 1024];
    uint32_t state = (uint32_t)seed * 2654435761u + 1;
    uint32_t *words = (uint32_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < data.length / 4; i++) {
        state = state * 1664525u + 1013904223u;
        words[i] = state;
    }
    return data;
}

static void VibePerfFillDiskCache(VibePerfDiskCache *state, NSUInteger count, NSUInteger byteLimit) {
    state->root = VibePerfTemporaryDirectory(@"pincache");
    state->queue = [[PINOperationQueue alloc] initWithMaxConcurrentOperations:10];
    state->cache = VibePerfMakeDiskCache(state->root, state->queue, byteLimit);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *key = [NSString stringWithFormat:@"%lu-%llu-%040lu", (unsigned long)(4000000 + i),
                                                   1700000000000000ull + i, (unsigned long)i];
        [state->cache setObject:VibePerfEntryData(i) forKey:key];
        state->keys.push_back(key);
    }
    [state->queue waitUntilAllOperationsAreFinished];
}

static void VibePerfRegisterDiskCache(void) {
    // Hits on entries already read today, as the sweep and every redraw's
    // archived art read make them: the read and the bookkeeping it schedules.
    auto hits = std::make_shared<VibePerfDiskCache>();
    VibePerfAdd("pincache", "hit-300", "hit", [hits]() -> double {
        VibePerfFillDiskCache(hits.get(), 300, 1024 * 1024 * 1024);
        return 300;
    }, [hits]() {
        for (NSString *key : hits->keys) {
            (void)[hits->cache objectForKey:key];
        }
        [hits->queue waitUntilAllOperationsAreFinished];
    });

    // The same hits from four threads at once, as the stage-1 workers read.
    auto parallel = std::make_shared<VibePerfDiskCache>();
    VibePerfAdd("pincache", "hit-300x4-parallel", "hit", [parallel]() -> double {
        VibePerfFillDiskCache(parallel.get(), 300, 1024 * 1024 * 1024);
        return 1200;
    }, [parallel]() {
        VibePerfDiskCache *state = parallel.get();
        dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t worker) {
            for (NSString *key : state->keys) {
                (void)[state->cache objectForKey:key];
            }
        });
        [state->queue waitUntilAllOperationsAreFinished];
    });

    // Writes of new entries under the limit, as a sweep of misses makes them.
    auto writes = std::make_shared<VibePerfDiskCache>();
    VibePerfAdd("pincache", "write-300", "write", [writes]() -> double {
        VibePerfFillDiskCache(writes.get(), 0, 1024 * 1024 * 1024);
        return 300;
    }, [writes]() {
        VibePerfDiskCache *state = writes.get();
        for (int i = 0; i < 300; i++) {
            NSUInteger n = state->next++;
            [state->cache setObject:VibePerfEntryData(n) forKey:[NSString stringWithFormat:@"w-%lu", (unsigned long)n]];
        }
        [state->queue waitUntilAllOperationsAreFinished];
    });

    // Writes into a cache already at its byte limit: 1,500 entries, each
    // write past it evicting.
    auto full = std::make_shared<VibePerfDiskCache>();
    VibePerfAdd("pincache", "write-300-at-limit", "write", [full]() -> double {
        VibePerfFillDiskCache(full.get(), 1500, 0);
        full->cache.byteLimit = full->cache.byteCount;
        return 300;
    }, [full]() {
        VibePerfDiskCache *state = full.get();
        for (int i = 0; i < 300; i++) {
            NSUInteger n = state->next++;
            [state->cache setObject:VibePerfEntryData(n) forKey:[NSString stringWithFormat:@"f-%lu", (unsigned long)n]];
        }
        [state->queue waitUntilAllOperationsAreFinished];
    });

    // A launch: a new cache over 2,000 entries, until its disk state is known.
    auto open = std::make_shared<VibePerfDiskCache>();
    VibePerfAdd("pincache", "open-2000", "entry", [open]() -> double {
        VibePerfFillDiskCache(open.get(), 2000, 1024 * 1024 * 1024);
        return 2000;
    }, [open]() {
        VibePerfDiskCache *state = open.get();
        PINDiskCache *cache = VibePerfMakeDiskCache(state->root, state->queue, 1024 * 1024 * 1024);
        [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
            *stop = YES;
        }];
        [state->queue waitUntilAllOperationsAreFinished];
    });
}

VIBE_PERF_REGISTER(VibePerfRegisterDiskCache)
