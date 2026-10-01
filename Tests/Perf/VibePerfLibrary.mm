//
//  VibePerfLibrary.mm
//  VibePerf
//
//  The library side: the metadata sweep's pick, the disk cache, tag and art
//  reads, playlist files, the folder walk and the playlist model's edits.
//  Inputs are synthesized under NSTemporaryDirectory and removed at exit.
//

#import "VibePerf.h"

#import <AVFAudio/AVFAudio.h>

#import <PINCache/PINDiskCache.h>
#import <PINOperation/PINOperation.h>

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
#import "AudioTrackArtworkInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataLoaderInternal.h"
#import "MetadataParseCoordinator.h"
#import "NSURLUtilInternal.h"
#import "Playlist.h"
#import "PlaylistFile.h"

#include <memory>
#include <vector>

// MARK: - Fixtures

static NSMutableArray<NSString *> *VibePerfTemporaryRoots(void) {
    static NSMutableArray<NSString *> *roots;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roots = [NSMutableArray array];
        atexit_b(^{
            for (NSString *root in roots) {
                [NSFileManager.defaultManager removeItemAtPath:root error:nil];
            }
        });
    });
    return roots;
}

// A fresh directory, removed when the process exits.
static NSString *VibePerfTemporaryDirectory(NSString *label) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"vibe-perf-%@-%@", label, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [VibePerfTemporaryRoots() addObject:root];
    return root;
}

// Runs the main queue, where metadata deliveries land, until done or a
// generous bound.
static void VibePerfSpinMainUntil(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:600];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
    }
    if (!done()) {
        printf("warning: wait timed out\n");
    }
}

// `count` one-byte files in folders of 100, the relative paths returned.
static NSArray<NSString *> *VibePerfMakeFiles(NSString *root, NSUInteger count, NSString *extension) {
    NSMutableArray<NSString *> *relative = [NSMutableArray arrayWithCapacity:count];
    NSData *byte = [NSData dataWithBytes:"\1" length:1];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *folder = [NSString stringWithFormat:@"Artist %03lu/Album %03lu", (unsigned long)(i / 1000),
                                                      (unsigned long)(i / 100)];
        if (i % 100 == 0) {
            [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:folder]
                                    withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSString *path = [folder stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%02lu Track %lu.%@", (unsigned long)(i % 100 + 1), (unsigned long)i, extension]];
        [byte writeToFile:[root stringByAppendingPathComponent:path] atomically:NO];
        [relative addObject:path];
    }
    return relative;
}

// MARK: - The metadata sweep

@interface VibePerfMetadataOwner : NSObject
@property (nonatomic, strong) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@property (atomic) uint64_t cacheGeneration;
@property (atomic, strong) id metadataCache;
@end

@implementation VibePerfMetadataOwner
@end

@interface VibePerfMetadataDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property (nonatomic) NSUInteger delivered;
@end

@implementation VibePerfMetadataDelegate
- (void)didLoadMetadata:(AudioTrack *)track {
    self.delivered++;
}
@end

@interface VibePerfReadyOperation : NSObject <AudioFileMaterializationOperation>
@end

@implementation VibePerfReadyOperation
- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    return YES;
}
- (void)cancel {
}
@end

struct VibePerfSweep {
    AudioTrackMetadata *prototype;
    NSString *root;
};

// The production loader over `count` local misses, cache reads and the TagLib
// parse replaced (a copy of one parsed file), until `picks` rows delivered.
static void VibePerfRunSweep(VibePerfSweep *sweep, NSUInteger count, NSUInteger picks) {
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *path = [sweep->root stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Album %03lu/Track %06lu.mp3", (unsigned long)(i / 12), (unsigned long)i]];
        [tracks addObject:[AudioTrack withURL:[NSURL fileURLWithPath:path isDirectory:NO]]];
    }
    VibePerfMetadataOwner *owner = [[VibePerfMetadataOwner alloc] init];
    owner.parseCoordinator = [[MetadataParseCoordinator alloc] init];
    AudioLoadingConfiguration *configuration =
            [[AudioLoadingConfiguration alloc] initWithValues:VibeAudioLoadingProductionConfigurationValues() error:nil];
    AudioFileMaterializationCoordinator *coordinator = [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
                 operationFactory:^id<AudioFileMaterializationOperation>(NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[VibePerfReadyOperation alloc] init];
    } datalessProbe:^BOOL(NSURL *url) {
        return NO;
    } clock:^NSTimeInterval {
        return 0;
    }];
    VibePerfMetadataDelegate *delegate = [[VibePerfMetadataDelegate alloc] init];
    AudioTrackMetadata *prototype = sweep->prototype;
    AudioTrackMetadataLoader *loader = [[AudioTrackMetadataLoader alloc]
            initWithOwner:(AudioTrackMetadataCache *)owner
                 delegate:delegate
     loadingConfiguration:configuration
materializationCoordinator:coordinator
              cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        return prototype;
    }];
    // As a shell does while the first row plays.
    [loader setNeighborhoodURLs:@[tracks[1].url, tracks[2].url, tracks[0].url]];
    [loader load:tracks];
    VibePerfSpinMainUntil(^BOOL {
        return delegate.delivered >= picks;
    });
    [loader cancel];
}

static void VibePerfRegisterSweep(void) {
    auto sweep = std::make_shared<VibePerfSweep>();
    auto prepare = [sweep](double units) {
        return [sweep, units]() -> double {
            NSString *path = VibePerfFile(@"mp3-320");
            if (!path) {
                return -1;
            }
            NSData *displayArt = nil;
            sweep->prototype = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:path] displayArtData:&displayArt];
            sweep->root = VibePerfTemporaryDirectory(@"sweep");
            return units;
        };
    };
    // The whole sweep of a 5,000-row playlist of misses, one pick per file.
    VibePerfAdd("scan", "sweep-5k", "row", prepare(5000), [sweep]() {
        VibePerfRunSweep(sweep.get(), 5000, 5000);
    });
    // The first 200 picks of a 100,000-row sweep, stage 1 included.
    VibePerfAdd("scan", "picks-100k", "pick", prepare(200), [sweep]() {
        VibePerfRunSweep(sweep.get(), 100000, 200);
    });
}

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

// MARK: - Tags and art

static void VibePerfRegisterTags(void) {
    // The art re-extraction a full-art miss runs: TagLib's open and the
    // picture read, twenty per repetition.
    for (NSString *name in @[@"mp3-320", @"flac-16-44", @"aac-256"]) {
        auto file = std::make_shared<VibePerfFileState>();
        auto extractor = std::make_shared<AudioTrackArtworkExtractor>();
        VibePerfAdd("art-extract", name.UTF8String, "read", [name, file, extractor]() -> double {
            file->path = VibePerfFile(name);
            if (!file->path) {
                return -1;
            }
            NSData *displayArt = nil;
            AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:file->path]
                                                               displayArtData:&displayArt];
            *extractor = [metadata.artwork valueForKey:@"extractor"];
            return *extractor ? 20 : -1;
        }, [file, extractor]() {
            for (int i = 0; i < 20; i++) {
                NSData *art = nil;
                (*extractor)(file->path, &art);
            }
        });
    }

    // The scan's parse over the library's MP3s, which carry ID3v2 tags and a
    // cover each.
    auto library = std::make_shared<std::vector<NSURL *>>();
    VibePerfAdd("metadata", "library-mp3", "parse", [library]() -> double {
        NSString *root = [VibePerfCorpus() stringByAppendingPathComponent:@"library"];
        for (NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:root]) {
            if ([relative.pathExtension isEqualToString:@"mp3"] && ![relative.lastPathComponent hasPrefix:@"."]) {
                library->push_back([NSURL fileURLWithPath:[root stringByAppendingPathComponent:relative]]);
            }
        }
        return library->empty() ? -1 : (double)library->size();
    }, [library]() {
        for (NSURL *url : *library) {
            NSData *displayArt = nil;
            (void)[AudioTrackMetadata metadataWithURL:url displayArtData:&displayArt];
        }
    });
}

// MARK: - Playlist files and the folder walk

static void VibePerfRegisterOpen(void) {
    // A 10,000-entry M3U of relative paths, every file present.
    auto m3u = std::make_shared<NSURL *>();
    VibePerfAdd("m3u", "resolve-10k", "entry", [m3u]() -> double {
        NSString *root = VibePerfTemporaryDirectory(@"m3u");
        NSArray<NSString *> *files = VibePerfMakeFiles(root, 10000, @"mp3");
        NSString *text = [[@"#EXTM3U\n" stringByAppendingString:[files componentsJoinedByString:@"\n"]]
                stringByAppendingString:@"\n"];
        NSString *path = [root stringByAppendingPathComponent:@"list.m3u8"];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        *m3u = [NSURL fileURLWithPath:path];
        return 10000;
    }, [m3u]() {
        NSArray<AudioTrack *> *rows = [PlaylistFile rowsForPlaylistAtURL:*m3u];
        if (rows.count != 10000) {
            printf("warning: m3u resolved %lu rows\n", (unsigned long)rows.count);
        }
    });

    // A dropped folder of 10,000 files, walked, filtered and sorted.
    auto folder = std::make_shared<NSURL *>();
    auto prepareFolder = [folder]() -> double {
        if (!*folder) {
            NSString *root = VibePerfTemporaryDirectory(@"walk");
            VibePerfMakeFiles(root, 10000, @"flac");
            *folder = [NSURL fileURLWithPath:root isDirectory:YES];
        }
        return 10000;
    };
    for (auto sort : {VibeFolderOpenSortName, VibeFolderOpenSortNewestFirst}) {
        VibePerfAdd("walk", sort == VibeFolderOpenSortName ? "10k-name" : "10k-newest", "file", prepareFolder,
                    [folder, sort]() {
            NSUInteger folders = 0;
            NSArray<AudioTrack *> *rows = [NSURLUtil expandAndFilterList:@[*folder] sortedBy:sort folderCount:&folders];
            if (rows.count != 10000) {
                printf("warning: walk found %lu rows\n", (unsigned long)rows.count);
            }
        });
    }

    // The corpus library: 600 real files with covers beside them.
    VibePerfAdd("walk", "library", "file", []() -> double {
        return [NSFileManager.defaultManager fileExistsAtPath:[VibePerfCorpus() stringByAppendingPathComponent:@"library"]]
                ? 600 : -1;
    }, []() {
        NSUInteger folders = 0;
        NSURL *library = [NSURL fileURLWithPath:[VibePerfCorpus() stringByAppendingPathComponent:@"library"] isDirectory:YES];
        (void)[NSURLUtil expandAndFilterList:@[library] sortedBy:VibeFolderOpenSortName folderCount:&folders];
    });
}

// MARK: - The playlist model

static void VibePerfRegisterPlaylist(void) {
    // A 100,000-row playlist; one repetition is five single-row removals each
    // undone by its insert, and five single-row moves there and back, at one
    // place in the list.
    auto playlist = std::make_shared<Playlist *>();
    auto prepare = [playlist]() -> double {
        if (!*playlist) {
            NSMutableArray<AudioTrack *> *tracks = [NSMutableArray arrayWithCapacity:100000];
            for (NSUInteger i = 0; i < 100000; i++) {
                NSString *path = [NSString stringWithFormat:@"/Volumes/Music/Artist %03lu/Album %04lu/Track %06lu.flac",
                                                            (unsigned long)(i / 1000), (unsigned long)(i / 12), (unsigned long)i];
                [tracks addObject:[AudioTrack withURL:[NSURL fileURLWithPath:path isDirectory:NO]]];
            }
            *playlist = [[Playlist alloc] init];
            [*playlist replaceAllWithTracks:tracks];
        }
        return 20;
    };
    for (double at : {0.0, 0.5, 0.99}) {
        const char *where = at == 0 ? "head" : at == 0.5 ? "middle" : "tail";
        VibePerfAdd("playlist-edit", std::string("100k-") + where, "edit", prepare, [playlist, at]() {
            Playlist *list = *playlist;
            NSUInteger row = (NSUInteger)(at * (list.count - 1));
            for (int i = 0; i < 5; i++) {
                NSIndexSet *one = [NSIndexSet indexSetWithIndex:row + i];
                NSArray<AudioTrack *> *removed = [list removeTracksAtIndexes:one];
                [list insertTracks:removed atIndexes:one];
                NSIndexSet *to = [NSIndexSet indexSetWithIndex:row + i + 5];
                [list moveTracksAtIndexes:one toIndexes:to];
                [list moveTracksAtIndexes:to toIndexes:one];
            }
        });
    }
}

VIBE_PERF_REGISTER(VibePerfRegisterSweep)
VIBE_PERF_REGISTER(VibePerfRegisterDiskCache)
VIBE_PERF_REGISTER(VibePerfRegisterTags)
VIBE_PERF_REGISTER(VibePerfRegisterOpen)
VIBE_PERF_REGISTER(VibePerfRegisterPlaylist)
