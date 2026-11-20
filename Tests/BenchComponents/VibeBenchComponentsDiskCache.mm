//
//  VibeBenchComponentsDiskCache.mm
//  VibeBenchComponents
//
//  The disk cache on Vibe's terms: hits, writes, a full cache's writes, a
//  launch's open, and a usage count. A version with vibe-libs' SQLite store
//  measures the store, and an older one PINDiskCache, under the same names,
//  so the page compares the two.
//

#import "VibeBenchComponents.h"

#if __has_include("VibeCacheStore.h")
#import "VibeCacheStore.h"
#define VIBE_BENCH_COMPONENTS_CACHE_STORE 1
#else
#import <PINCache/PINDiskCache.h>
#import <PINOperation/PINOperation.h>
#define VIBE_BENCH_COMPONENTS_CACHE_STORE 0
#endif
#import "AudioWaveform.h"
#import "AudioWaveformLoader.h"
#import "AudioTrackMetadata.h"
#if __has_include("AudioTrackMetadataInternal.h")
#import "AudioTrackMetadataInternal.h"
#endif
#if VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
#if __has_include("WaveformRenderer.h")
#import "WaveformRenderer.h"
#else
#import "AudioWaveformRenderer.h"
// The renderer was AudioWaveformRenderer before it took the Waveform* name.
#define WaveformRenderer AudioWaveformRenderer
#endif
#import "WaveformRendererRegistry.h"
#endif

#include <memory>
#include <vector>

// MARK: - The disk cache

struct VibeBenchComponentsDiskCache {
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    VibeCacheStore *cache;
#else
    PINDiskCache *cache;
    PINOperationQueue *queue;
#endif
    NSString *root;
    std::vector<NSString *> keys;
    NSUInteger next = 0;
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
    std::unique_ptr<wavecore::SummaryBuilder> waveformBuilder;
#endif
};

#if VIBE_BENCH_COMPONENTS_CACHE_STORE
// The store over the directory, with Vibe's terms: the byte limit, and the
// default age from the last use.
static VibeCacheStore *VibeBenchComponentsMakeDiskCache(NSString *root, NSUInteger byteLimit) {
    VibeCacheStore *store = [[VibeCacheStore alloc] initWithDirectory:[root stringByAppendingPathComponent:@"bench"]];
    VibeBenchComponentsRequire(store != nil, "disk cache open failed");
    store.byteLimit = byteLimit;
    return store;
}
#else
// Vibe's audio caches' terms: least recently used, not TTL, an age limit.
static PINDiskCache *VibeBenchComponentsMakeDiskCache(NSString *root, PINOperationQueue *queue, NSUInteger byteLimit) {
    return [[PINDiskCache alloc] initWithName:@"bench" prefix:@"com.vibe.perf" rootPath:root
                                   serializer:nil deserializer:nil keyEncoder:nil keyDecoder:nil
                               operationQueue:queue ttlCache:NO byteLimit:byteLimit
                                     ageLimit:6 * 30 * 24 * 3600
                             evictionStrategy:PINCacheEvictionStrategyLeastRecentlyUsed];
}
#endif

// Files an object. The store keeps bytes, so it files a blob as it is, and
// archives any other object as PINCache's serializer did. PINCache archives
// every object.
static void VibeBenchComponentsCachePut(VibeBenchComponentsDiskCache *state, id object, NSString *key) {
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    NSData *data = [object isKindOfClass:NSData.class] ? (NSData *)object
            : [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:nil];
    [state->cache setData:data forKey:key format:1 sharedName:nil];
#else
    [state->cache setObject:object forKey:key];
#endif
}

// Reads an object back, a blob as it is or an object unarchived, as
// PINCache's deserializer did. nil on a miss.
static id VibeBenchComponentsCacheGet(VibeBenchComponentsDiskCache *state, NSString *key, BOOL archived) {
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    VibeCacheHit *hit = [state->cache hitForKey:key format:1];
    if (!hit || !archived) return hit.data;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:hit.data error:nil];
    unarchiver.requiresSecureCoding = NO;
    id object = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return object;
#else
    return [state->cache objectForKey:key];
#endif
}

static BOOL VibeBenchComponentsCacheHas(VibeBenchComponentsDiskCache *state, NSString *key) {
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    return [state->cache hasEntryForKey:key];
#else
    return [state->cache containsObjectForKey:key];
#endif
}

// Waits for the work a read or a write left queued: PINCache's re-dates and
// trims, or the store's.
static void VibeBenchComponentsCacheSettle(VibeBenchComponentsDiskCache *state) {
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [state->cache performAfterQueuedWork:^{
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
#else
    [state->queue waitUntilAllOperationsAreFinished];
#endif
}

// A metadata archive's size.
static NSData *VibeBenchComponentsEntryData(NSUInteger seed) {
    NSMutableData *data = [NSMutableData dataWithLength:16 * 1024];
    uint32_t state = (uint32_t)seed * 2654435761u + 1;
    uint32_t *words = (uint32_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < data.length / 4; i++) {
        state = state * 1664525u + 1013904223u;
        words[i] = state;
    }
    return data;
}

static void VibeBenchComponentsFillDiskCache(VibeBenchComponentsDiskCache *state, NSUInteger count, NSUInteger byteLimit) {
    state->root = VibeBenchComponentsTemporaryDirectory(@"pincache");
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
    state->cache = VibeBenchComponentsMakeDiskCache(state->root, byteLimit);
#else
    state->queue = [[PINOperationQueue alloc] initWithMaxConcurrentOperations:10];
    state->cache = VibeBenchComponentsMakeDiskCache(state->root, state->queue, byteLimit);
#endif
    for (NSUInteger i = 0; i < count; i++) {
        NSString *key = [NSString stringWithFormat:@"%lu-%llu-%040lu", (unsigned long)(4000000 + i),
                                                   1700000000000000ull + i, (unsigned long)i];
        VibeBenchComponentsCachePut(state, VibeBenchComponentsEntryData(i), key);
        state->keys.push_back(key);
    }
    VibeBenchComponentsCacheSettle(state);
}

static void VibeBenchComponentsRegisterDiskCache(void) {
    for (NSString *name in @[@"flac-16-44", @"mp3-320-60min"]) {
        for (int bands = 0; bands <= (VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE); bands++) {
            auto waveform = std::make_shared<CodableAudioWaveform *>();
            auto disk = std::make_shared<VibeBenchComponentsDiskCache>();
            auto prepare = [waveform, disk, bands, name]() -> double {
                NSString *path = VibeBenchComponentsFile(name);
                if (!path) return -1;
                AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(NO);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE
                loader.analysis = (VibeWaveformAnalysis){.bands = (BOOL)bands};
#endif
                *waveform = [loader load:path];
                VibeBenchComponentsRequire(*waveform != nil && loader.isComplete, "waveform cache fixture failed");
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
                VibeBenchComponentsReader *reader = [[VibeBenchComponentsReader alloc] initWithPath:path interleaved:YES];
                VibeBenchComponentsRequire(reader != nil, "snapshot fixture open failed");
                disk->waveformBuilder = std::make_unique<wavecore::SummaryBuilder>(bands, reader.length,
                                                                                  reader.processingFormat.sampleRate);
                AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:reader.processingFormat frameCapacity:65536];
                std::vector<float> scratch(65536);
                while ([reader read:buffer]) {
                    const float *mono = AudioWaveformMonoMix(buffer.floatChannelData[0], scratch.data(), buffer.frameLength,
                                                             reader.processingFormat.channelCount);
                    disk->waveformBuilder->append(mono, buffer.frameLength);
                }
#endif
                VibeBenchComponentsFillDiskCache(disk.get(), 0, 1024 * 1024 * 1024);
                VibeBenchComponentsCachePut(disk.get(), *waveform, @"waveform");
                VibeBenchComponentsCacheSettle(disk.get());
                return 100;
            };
            for (const char *operation : {"read", "write", "snapshot", "read-draw", "snapshot-draw"}) {
                // A bands draw is Spectrum's, so a version without Spectrum has none.
                if (std::string(operation).find("-draw") != std::string::npos &&
                    (!VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW || (bands && !VIBE_BENCH_COMPONENTS_WAVEFORM_SPECTRUM))) {
                    continue;
                }
                std::string op = operation;
                VibeBenchComponentsAdd("waveform-cache", op + (bands ? "-bands" : "-plain") +
                                      ([name hasSuffix:@"60min"] ? "-60min" : ""), "op", prepare,
                                      [waveform, disk, op, bands, name]() {
                    for (int i = 0; i < 100; i++) {
                        @autoreleasepool {
                            if (op == "write") {
                                VibeBenchComponentsCachePut(disk.get(), *waveform, @"waveform");
                            } else {
                                CodableAudioWaveform *result;
                                if (op == "read" || op == "read-draw") {
                                    result = (CodableAudioWaveform *)VibeBenchComponentsCacheGet(disk.get(), @"waveform", YES);
                                } else {
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
                                    result = [[CodableAudioWaveform alloc] initWithWaveform:disk->waveformBuilder->snapshot()];
#else
                                    result = [*waveform snapshot];
#endif
                                }
                                VibeBenchComponentsRequire(result != nil && result.waveform != nullptr,
                                                           "waveform cache read or snapshot failed");
#if VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
                                if (op.find("-draw") != std::string::npos) {
                                    CALayer *layer = [CALayer layer];
                                    layer.bounds = CGRectMake(0, 0, 800, 60);
                                    layer.contentsScale = 2;
                                    WaveformRenderer *renderer = [WaveformRendererRegistry
                                            rendererForResolvedIdentifier:bands ? @"spectrum" : @"detailed"
                                            layer:layer bounds:layer.bounds isDark:YES];
                                    VibeBenchComponentsRequire(renderer != nil, "first draw renderer missing");
                                    [renderer updateWaveform:layer.bounds progress:0.4 waveform:result.waveform];
                                    [renderer settleMorphImmediately];
                                    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                                    CGContextRef context = CGBitmapContextCreate(NULL, 1600, 120, 8, 0, space,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
                                    CGColorSpaceRelease(space);
                                    VibeBenchComponentsRequire(context != NULL, "first draw bitmap allocation failed");
                                    CGContextScaleCTM(context, 2, 2);
                                    [layer renderInContext:context];
                                    if (i == 0 && getenv("VIBE_BENCH_COMPONENTS_UI_DUMP")) {
                                        NSString *label = [NSString stringWithFormat:@"%@-%s-%d", name, op.c_str(), bands];
                                        VibeBenchComponentsUIDump([label stringByAppendingString:@".pixels"],
                                                [NSData dataWithBytes:CGBitmapContextGetData(context)
                                                               length:CGBitmapContextGetBytesPerRow(context) * 120]);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
                                        auto bytes = result.waveform->encode();
                                        VibeBenchComponentsUIDump([label stringByAppendingString:@".archive"],
                                                [NSData dataWithBytes:bytes.data() length:bytes.size()]);
#endif
                                    }
                                    CGContextRelease(context);
                                    [CATransaction flush];
                                }
#endif
                            }
                        }
                    }
                    VibeBenchComponentsCacheSettle(disk.get());
                });
            }
            VibeBenchComponentsAdd("waveform-cache", std::string("fresh-write") + (bands ? "-bands" : "-plain") +
                                  ([name hasSuffix:@"60min"] ? "-60min" : ""), "op",
                                  [name]() -> double { return VibeBenchComponentsFile(name) ? 1 : -1; },
                                  [name, bands]() {
                @autoreleasepool {
                    AudioWaveformLoader *loader = VibeBenchComponentsWaveformLoader(NO);
#if VIBE_BENCH_COMPONENTS_WAVEFORM_BANDS && VIBE_BENCH_COMPONENTS_ANALYSIS_VALUE
                    loader.analysis = (VibeWaveformAnalysis){.bands = (BOOL)bands};
#endif
                    CodableAudioWaveform *fresh = [loader load:VibeBenchComponentsFile(name)];
                    VibeBenchComponentsRequire(fresh != nil && loader.isComplete, "fresh waveform failed");
                    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:fresh requiringSecureCoding:NO error:nil];
                    VibeBenchComponentsRequire(archive.length > 0, "fresh waveform archive failed");
                }
            });
        }
    }

    for (NSString *name in @[@"mp3-320", @"flac-16-44"]) {
        for (const char *operation : {"read", "write"}) {
            auto disk = std::make_shared<VibeBenchComponentsDiskCache>();
            auto metadata = std::make_shared<AudioTrackMetadata *>();
            std::string op = operation;
            VibeBenchComponentsAdd("metadata-cache-" + op, name.UTF8String, "op", [name, disk, metadata]() -> double {
                NSString *path = VibeBenchComponentsFile(name);
                if (!path) return -1;
#if VIBE_BENCH_COMPONENTS_METADATA_DISPLAY_ART
                NSData *art = nil;
                *metadata = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:path] displayArtData:&art];
#else
                *metadata = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:path]];
#endif
                VibeBenchComponentsRequire(*metadata != nil, "metadata archive fixture failed");
                VibeBenchComponentsFillDiskCache(disk.get(), 0, 1024 * 1024 * 1024);
                VibeBenchComponentsCachePut(disk.get(), *metadata, @"metadata");
                VibeBenchComponentsCacheSettle(disk.get());
                return 100;
            }, [disk, metadata, op]() {
                for (int i = 0; i < 100; i++) {
                    @autoreleasepool {
                        if (op == "write") VibeBenchComponentsCachePut(disk.get(), *metadata, @"metadata");
                        else VibeBenchComponentsRequire(VibeBenchComponentsCacheGet(disk.get(), @"metadata", YES) != nil,
                                                        "metadata archive read failed");
                    }
                }
                VibeBenchComponentsCacheSettle(disk.get());
                VibeBenchComponentsRequire(VibeBenchComponentsCacheHas(disk.get(), @"metadata"), "metadata cache write failed");
            });
        }
    }

    // Include the bookkeeping scheduled by a disk cache hit.
    auto hits = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "hit-300", "hit", [hits]() -> double {
        VibeBenchComponentsFillDiskCache(hits.get(), 300, 1024 * 1024 * 1024);
        return 300;
    }, [hits]() {
        for (NSString *key : hits->keys) {
            VibeBenchComponentsRequire(VibeBenchComponentsCacheGet(hits.get(), key, NO) != nil, "disk cache hit missed");
        }
        VibeBenchComponentsCacheSettle(hits.get());
    });

    // The same hits from four threads at once, as the stage-1 workers read.
    auto parallel = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "hit-300x4-parallel", "hit", [parallel]() -> double {
        VibeBenchComponentsFillDiskCache(parallel.get(), 300, 1024 * 1024 * 1024);
        return 1200;
    }, [parallel]() {
        VibeBenchComponentsDiskCache *state = parallel.get();
        dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t worker) {
            for (NSString *key : state->keys) {
                VibeBenchComponentsRequire(VibeBenchComponentsCacheGet(state, key, NO) != nil, "parallel disk cache hit missed");
            }
        });
        VibeBenchComponentsCacheSettle(state);
    });

    // Writes of new entries under the limit, as a sweep of misses makes them.
    auto writes = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "write-300", "write", [writes]() -> double {
        VibeBenchComponentsFillDiskCache(writes.get(), 0, 1024 * 1024 * 1024);
        return 300;
    }, [writes]() {
        VibeBenchComponentsDiskCache *state = writes.get();
        for (int i = 0; i < 300; i++) {
            NSUInteger n = state->next++;
            VibeBenchComponentsCachePut(state, VibeBenchComponentsEntryData(n), [NSString stringWithFormat:@"w-%lu", (unsigned long)n]);
        }
        VibeBenchComponentsCacheSettle(state);
    });

    // Writes into a cache already at its byte limit: 1,500 entries, each
    // write past it evicting.
    auto full = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "write-300-at-limit", "write", [full]() -> double {
        VibeBenchComponentsFillDiskCache(full.get(), 1500, 0);
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
        full->cache.byteLimit = full->cache.usage.bytes;
#else
        full->cache.byteLimit = full->cache.byteCount;
#endif
        return 300;
    }, [full]() {
        VibeBenchComponentsDiskCache *state = full.get();
        for (int i = 0; i < 300; i++) {
            NSUInteger n = state->next++;
            VibeBenchComponentsCachePut(state, VibeBenchComponentsEntryData(n), [NSString stringWithFormat:@"f-%lu", (unsigned long)n]);
        }
        VibeBenchComponentsCacheSettle(state);
    });

    // A launch: a new cache over 2,000 entries, until it can answer. The
    // store's open reads its database, and PINCache's counts its files.
    auto open = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "open-2000", "entry", [open]() -> double {
        VibeBenchComponentsFillDiskCache(open.get(), 2000, 1024 * 1024 * 1024);
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
        // One store a directory at a time.
        [open->cache close];
#endif
        return 2000;
    }, [open]() {
        VibeBenchComponentsDiskCache *state = open.get();
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
        VibeCacheStore *cache = VibeBenchComponentsMakeDiskCache(state->root, 1024 * 1024 * 1024);
        VibeBenchComponentsRequire(cache.usage.entries == 2000, "disk cache open lost entries");
        [cache close];
#else
        PINDiskCache *cache = VibeBenchComponentsMakeDiskCache(state->root, state->queue, 1024 * 1024 * 1024);
        [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
            *stop = YES;
        }];
        [state->queue waitUntilAllOperationsAreFinished];
#endif
    });

    // A usage count over 2,000 entries, as Settings shows it: the store's
    // sum, or PINCache's walk of its files.
    auto usage = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "usage-2000", "entry", [usage]() -> double {
        VibeBenchComponentsFillDiskCache(usage.get(), 2000, 1024 * 1024 * 1024);
        return 2000;
    }, [usage]() {
        VibeBenchComponentsDiskCache *state = usage.get();
#if VIBE_BENCH_COMPONENTS_CACHE_STORE
        VibeBenchComponentsRequire(state->cache.usage.entries == 2000, "disk cache usage miscounted");
#else
        __block NSUInteger entries = 0;
        [state->cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
            entries++;
        }];
        VibeBenchComponentsRequire(entries == 2000, "disk cache usage miscounted");
#endif
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterDiskCache)
