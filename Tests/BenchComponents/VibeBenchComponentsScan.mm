//
//  VibeBenchComponentsScan.mm
//  VibeBenchComponents
//
//  The metadata sweep's picks through the production loader, its cache reads
//  and the TagLib parse replaced (1.15 on).
//

#import "VibeBenchComponents.h"

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioLoadingConfiguration.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataLoaderInternal.h"
#import "MetadataParseCoordinator.h"

#include <memory>

// MARK: - The metadata sweep

@interface VibeBenchComponentsMetadataOwner : NSObject
@property (nonatomic, strong) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@property (atomic) uint64_t cacheGeneration;
@property (atomic, strong) id metadataCache;
@end

@implementation VibeBenchComponentsMetadataOwner
@end

@interface VibeBenchComponentsMetadataDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property (nonatomic) NSUInteger delivered;
@end

@implementation VibeBenchComponentsMetadataDelegate
- (void)didLoadMetadata:(AudioTrack *)track {
    self.delivered++;
}
@end

@interface VibeBenchComponentsReadyOperation : NSObject <AudioFileMaterializationOperation>
@end

@implementation VibeBenchComponentsReadyOperation
- (BOOL)runOnReadable:(dispatch_block_t)onReadable
          probedLocal:(BOOL)probedLocal
                error:(NSError *__autoreleasing *)error {
    return YES;
}
// The protocol's earlier shapes; perf.py grafts this file onto older refs,
// whose coordinator sends these selectors.
- (BOOL)runOnReadable:(dispatch_block_t)onReadable error:(NSError *__autoreleasing *)error {
    return YES;
}
- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    return YES;
}
- (void)cancel {
}
@end

struct VibeBenchComponentsSweep {
    AudioTrackMetadata *prototype;
    NSString *root;
};

// The production loader over `count` local misses, cache reads and the TagLib
// parse replaced (a copy of one parsed file), until `picks` rows delivered.
static void VibeBenchComponentsRunSweep(VibeBenchComponentsSweep *sweep, NSUInteger count, NSUInteger picks) {
    NSMutableArray<AudioTrack *> *tracks = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        NSString *path = [sweep->root stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Album %03lu/Track %06lu.mp3", (unsigned long)(i / 12), (unsigned long)i]];
        [tracks addObject:[AudioTrack withURL:[NSURL fileURLWithPath:path isDirectory:NO]]];
    }
    VibeBenchComponentsMetadataOwner *owner = [[VibeBenchComponentsMetadataOwner alloc] init];
    owner.parseCoordinator = [[MetadataParseCoordinator alloc] init];
    AudioLoadingConfiguration *configuration =
            [[AudioLoadingConfiguration alloc] initWithValues:VibeAudioLoadingProductionConfigurationValues() error:nil];
    AudioFileMaterializationCoordinator *coordinator = [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
                 operationFactory:^id<AudioFileMaterializationOperation>(NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[VibeBenchComponentsReadyOperation alloc] init];
    } datalessProbe:^BOOL(NSURL *url) {
        return NO;
    } clock:^NSTimeInterval {
        return 0;
    }];
    VibeBenchComponentsMetadataDelegate *delegate = [[VibeBenchComponentsMetadataDelegate alloc] init];
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
    VibeBenchComponentsSpinMainUntil(^BOOL {
        return delegate.delivered >= picks;
    });
    [loader cancel];
}

static void VibeBenchComponentsRegisterSweep(void) {
    auto sweep = std::make_shared<VibeBenchComponentsSweep>();
    auto prepare = [sweep](double units) {
        return [sweep, units]() -> double {
            NSString *path = VibeBenchComponentsFile(@"mp3-320");
            if (!path) {
                return -1;
            }
            NSData *displayArt = nil;
            sweep->prototype = [AudioTrackMetadata metadataWithURL:[NSURL fileURLWithPath:path] displayArtData:&displayArt];
            sweep->root = VibeBenchComponentsTemporaryDirectory(@"sweep");
            return units;
        };
    };
    // The whole sweep of a 5,000-row playlist of misses, one pick per file.
    VibeBenchComponentsAdd("scan", "sweep-5k", "row", prepare(5000), [sweep]() {
        VibeBenchComponentsRunSweep(sweep.get(), 5000, 5000);
    });
    // The first 200 picks of a 100,000-row sweep, stage 1 included.
    VibeBenchComponentsAdd("scan", "picks-100k", "pick", prepare(200), [sweep]() {
        VibeBenchComponentsRunSweep(sweep.get(), 100000, 200);
    });
}

VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterSweep)
