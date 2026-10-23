//
// The launch-time removal of the stores other builds left in Caches.
//

#import <XCTest/XCTest.h>

#import "LegacyCacheStores.h"
#import "TestFilesystemGuard.h"

@interface LegacyCacheStoresTests : XCTestCase
@end

@implementation LegacyCacheStoresTests {
    NSString *_root;
}

- (void)setUp {
    _root = [VibeTestProcessRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:_root withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtPath:_root error:nil];
}

- (void)makeStores:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        NSString *store = [_root stringByAppendingPathComponent:name];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES
                                                               attributes:nil error:nil]);
        [NSData.data writeToFile:[store stringByAppendingPathComponent:@"entry"] atomically:NO];
    }
}

- (NSSet<NSString *> *)remaining {
    return [NSSet setWithArray:[NSFileManager.defaultManager contentsOfDirectoryAtPath:_root error:nil]];
}

// Every name a release shipped, with the next bump's current names standing in.
- (void)testRemovesEveryOtherVersionAndKeepsTheCurrentStores {
    NSMutableArray<NSString *> *legacy = [NSMutableArray array];
    for (NSString *name in @[@"Audio Track Metadata", @"Audio Track Metadata v2", @"Audio Track Metadata v3",
                             @"Audio Track Metadata v4", @"Audio Track Metadata v5", @"Audio Track Metadata v7",
                             @"Audio Track Metadata v10", @"audio_waveform_cache", @"audio_waveform_cache_v2",
                             @"audio_waveform_cache_v4", @"audio_waveform_cache_v5", @"audio_waveform_cache_v6"]) {
        [legacy addObject:[@"com.pinterest.PINDiskCache." stringByAppendingString:name]];
    }
    NSArray<NSString *> *kept = @[@"com.pinterest.PINDiskCache.Audio Track Metadata v8",
                                  @"com.pinterest.PINDiskCache.audio_waveform_cache_v7",
                                  // Another store, and a directory that is no store.
                                  @"com.pinterest.PINDiskCache.Audio Track Metadata Art v1",
                                  @"Audio Track Metadata v5"];
    [self makeStores:[legacy arrayByAddingObjectsFromArray:kept]];

    VibeRemoveLegacyCacheStores(_root, @[@"Audio Track Metadata v8", @"audio_waveform_cache_v7"]);

    XCTAssertEqualObjects(self.remaining, [NSSet setWithArray:kept]);
}

- (void)testTheWaveformStoreNameFollowsTheRule {
    NSString *current = [@"com.pinterest.PINDiskCache." stringByAppendingString:AudioWaveformCache.cacheName];
    [self makeStores:@[current, @"com.pinterest.PINDiskCache.audio_waveform_cache_v1"]];

    VibeRemoveLegacyCacheStores(_root, @[AudioWaveformCache.cacheName]);

    XCTAssertEqualObjects(self.remaining, [NSSet setWithObject:current]);
}

- (void)testAMissingDirectoryIsANoOp {
    VibeRemoveLegacyCacheStores([_root stringByAppendingPathComponent:@"absent"], @[@"Audio Track Metadata v8"]);
    XCTAssertEqualObjects(self.remaining, [NSSet set]);
}

@end
