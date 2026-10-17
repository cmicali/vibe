//
//  VibeBenchComponentsDiskCache.mm
//  VibeBenchComponents
//
//  PINDiskCache on Vibe's terms: hits, writes, a full cache's writes and a
//  launch's open.
//

#import "VibeBenchComponents.h"

#import <PINCache/PINDiskCache.h>
#import <PINOperation/PINOperation.h>
#import "AudioWaveform.h"
#import "AudioWaveformLoader.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#if VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
#import "WaveformRenderer.h"
#import "WaveformRendererRegistry.h"
#endif

#include <memory>
#include <vector>

// MARK: - The disk cache

struct VibeBenchComponentsDiskCache {
    PINDiskCache *cache;
    PINOperationQueue *queue;
    NSString *root;
    std::vector<NSString *> keys;
    NSUInteger next = 0;
#if VIBE_BENCH_COMPONENTS_WAVEFORM_SUMMARY
    std::unique_ptr<wavecore::SummaryBuilder> waveformBuilder;
#endif
};

// Vibe's audio caches' terms: least recently used, not TTL, an age limit.
static PINDiskCache *VibeBenchComponentsMakeDiskCache(NSString *root, PINOperationQueue *queue, NSUInteger byteLimit) {
    return [[PINDiskCache alloc] initWithName:@"bench" prefix:@"com.vibe.perf" rootPath:root
                                   serializer:nil deserializer:nil keyEncoder:nil keyDecoder:nil
                               operationQueue:queue ttlCache:NO byteLimit:byteLimit
                                     ageLimit:6 * 30 * 24 * 3600
                             evictionStrategy:PINCacheEvictionStrategyLeastRecentlyUsed];
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
    state->queue = [[PINOperationQueue alloc] initWithMaxConcurrentOperations:10];
    state->cache = VibeBenchComponentsMakeDiskCache(state->root, state->queue, byteLimit);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *key = [NSString stringWithFormat:@"%lu-%llu-%040lu", (unsigned long)(4000000 + i),
                                                   1700000000000000ull + i, (unsigned long)i];
        [state->cache setObject:VibeBenchComponentsEntryData(i) forKey:key];
        state->keys.push_back(key);
    }
    [state->queue waitUntilAllOperationsAreFinished];
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
                [disk->cache setObject:*waveform forKey:@"waveform"];
                [disk->queue waitUntilAllOperationsAreFinished];
                return 100;
            };
            for (const char *operation : {"read", "write", "snapshot", "read-draw", "snapshot-draw"}) {
#if !VIBE_BENCH_COMPONENTS_WAVEFORM_DRAW
                if (std::string(operation).find("-draw") != std::string::npos) continue;
#endif
                std::string op = operation;
                VibeBenchComponentsAdd("waveform-cache", op + (bands ? "-bands" : "-plain") +
                                      ([name hasSuffix:@"60min"] ? "-60min" : ""), "op", prepare,
                                      [waveform, disk, op, bands, name]() {
                    for (int i = 0; i < 100; i++) {
                        @autoreleasepool {
                            if (op == "write") {
                                [disk->cache setObject:*waveform forKey:@"waveform"];
                            } else {
                                CodableAudioWaveform *result;
                                if (op == "read" || op == "read-draw") {
                                    result = (CodableAudioWaveform *)[disk->cache objectForKey:@"waveform"];
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
                    [disk->queue waitUntilAllOperationsAreFinished];
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
                [disk->cache setObject:*metadata forKey:@"metadata"];
                [disk->queue waitUntilAllOperationsAreFinished];
                return 100;
            }, [disk, metadata, op]() {
                for (int i = 0; i < 100; i++) {
                    @autoreleasepool {
                        if (op == "write") [disk->cache setObject:*metadata forKey:@"metadata"];
                        else VibeBenchComponentsRequire([disk->cache objectForKey:@"metadata"] != nil,
                                                        "metadata archive read failed");
                    }
                }
                [disk->queue waitUntilAllOperationsAreFinished];
                VibeBenchComponentsRequire([disk->cache containsObjectForKey:@"metadata"], "metadata cache write failed");
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
            VibeBenchComponentsRequire([hits->cache objectForKey:key] != nil, "disk cache hit missed");
        }
        [hits->queue waitUntilAllOperationsAreFinished];
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
                VibeBenchComponentsRequire([state->cache objectForKey:key] != nil, "parallel disk cache hit missed");
            }
        });
        [state->queue waitUntilAllOperationsAreFinished];
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
            [state->cache setObject:VibeBenchComponentsEntryData(n) forKey:[NSString stringWithFormat:@"w-%lu", (unsigned long)n]];
        }
        [state->queue waitUntilAllOperationsAreFinished];
    });

    // Writes into a cache already at its byte limit: 1,500 entries, each
    // write past it evicting.
    auto full = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "write-300-at-limit", "write", [full]() -> double {
        VibeBenchComponentsFillDiskCache(full.get(), 1500, 0);
        full->cache.byteLimit = full->cache.byteCount;
        return 300;
    }, [full]() {
        VibeBenchComponentsDiskCache *state = full.get();
        for (int i = 0; i < 300; i++) {
            NSUInteger n = state->next++;
            [state->cache setObject:VibeBenchComponentsEntryData(n) forKey:[NSString stringWithFormat:@"f-%lu", (unsigned long)n]];
        }
        [state->queue waitUntilAllOperationsAreFinished];
    });

    // A launch: a new cache over 2,000 entries, until its disk state is known.
    auto open = std::make_shared<VibeBenchComponentsDiskCache>();
    VibeBenchComponentsAdd("pincache", "open-2000", "entry", [open]() -> double {
        VibeBenchComponentsFillDiskCache(open.get(), 2000, 1024 * 1024 * 1024);
        return 2000;
    }, [open]() {
        VibeBenchComponentsDiskCache *state = open.get();
        PINDiskCache *cache = VibeBenchComponentsMakeDiskCache(state->root, state->queue, 1024 * 1024 * 1024);
        [cache enumerateObjectsWithBlock:^(NSString *key, NSURL *fileURL, BOOL *stop) {
            *stop = YES;
        }];
        [state->queue waitUntilAllOperationsAreFinished];
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterDiskCache)
