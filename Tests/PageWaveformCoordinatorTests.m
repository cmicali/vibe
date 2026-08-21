//
// The iOS pager's waveform bookkeeping: N pages against one load-at-a-time
// cache. Its whole job is deciding which page that load is pointed at and
// dropping deliveries that no longer belong to it, which is the app-wide
// "async deliveries race track changes" guarantee — so it is worth testing
// without a pager, a cache or a decode.
//
// The cache is a duck-typed fake cast to the property type, per Tests/CLAUDE.md:
// the coordinator only ever sends it three messages.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "AudioWaveformCache.h"   // AudioWaveformCacheDelegate, which the coordinator adopts
#import "PageWaveformCoordinator.h"

#pragma mark - Fakes

@interface FakeWaveformCache : NSObject
@property (nonatomic, weak) id delegate;
@property (nonatomic) NSUInteger cancelCount;
@property (nonatomic, strong) NSMutableArray<NSURL *> *loadedURLs;
@end

@implementation FakeWaveformCache
- (instancetype)init {
    self = [super init];
    if (self) {
        _loadedURLs = [NSMutableArray array];
    }
    return self;
}
- (void)cancelLoad {
    _cancelCount++;
}
- (void)loadWaveformForTrack:(AudioTrack *)track {
    [_loadedURLs addObject:track.url];
}
@end

@interface RecordingCoordinatorDelegate : NSObject <PageWaveformCoordinatorDelegate>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *updatedIndexes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *failedIndexes;
@end

@implementation RecordingCoordinatorDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _updatedIndexes = [NSMutableArray array];
        _failedIndexes = [NSMutableArray array];
    }
    return self;
}
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)coordinator
              didUpdateWaveform:(CodableAudioWaveform *)waveform
                       forIndex:(NSUInteger)index {
    [_updatedIndexes addObject:@(index)];
}
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)coordinator
      didFailWaveformForIndex:(NSUInteger)index {
    [_failedIndexes addObject:@(index)];
}
@end

#pragma mark - Tests

@interface PageWaveformCoordinatorTests : XCTestCase
@end

@implementation PageWaveformCoordinatorTests {
    FakeWaveformCache *_cache;
    RecordingCoordinatorDelegate *_delegate;
    PageWaveformCoordinator *_coordinator;
    NSArray<AudioTrack *> *_tracks;
}

- (void)setUp {
    [super setUp];
    _cache = [[FakeWaveformCache alloc] init];
    _delegate = [[RecordingCoordinatorDelegate alloc] init];
    _coordinator = [[PageWaveformCoordinator alloc]
            initWithCache:(AudioWaveformCache *)_cache delegate:_delegate];
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSUInteger i = 0; i < 8; i++) {
        [tracks addObject:[AudioTrack withURL:
                [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/vibe-%lu.mp3",
                                        (unsigned long)i]]]];
    }
    _tracks = tracks;
}

// A stand-in for the delivered waveform. The coordinator only stores it and
// hands it on, so any object will do — but it must not be nil, because a nil
// value is what a dictionary uses to mean "no entry", and the snapshot store
// is a dictionary.
- (void)deliverForURL:(NSURL *)url percent:(float)percent {
    CodableAudioWaveform *waveform = (CodableAudioWaveform *)[NSObject new];
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveform:waveform
                                                    didLoadData:percent
                                                         forURL:url];
}

- (void)failForURL:(NSURL *)url {
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveformCache:(AudioWaveformCache *)_cache
                                                didFailToLoadForURL:url];
}

#pragma mark Targeting

- (void)testRequestPointsTheLoadAtThePage {
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqual(_coordinator.targetIndex, 3u);
    XCTAssertEqualObjects(_cache.loadedURLs, @[_tracks[3].url]);
}

- (void)testNilTrackIsIgnored {
    [_coordinator requestIndex:2 track:nil];
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);
    XCTAssertEqual(_cache.loadedURLs.count, 0u);
}

// Re-requesting the page already targeted, still holding the same file, must
// not restart the decode — a cell reload would otherwise kill it every time
// and no waveform would ever complete.
- (void)testRepeatRequestForTheSameFileIsANoOp {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqual(_cache.loadedURLs.count, 1u);
    XCTAssertEqual(_cache.cancelCount, 1u);
}

// But the same INDEX holding a different file is a different request. Matching
// on the index alone left the load pointed at the departed track.
- (void)testSameIndexWithADifferentFileReloads {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:3 track:_tracks[5]];
    XCTAssertEqual(_cache.loadedURLs.count, 2u);
    XCTAssertEqualObjects(_cache.loadedURLs.lastObject, _tracks[5].url);
}

- (void)testRetargetingCancelsTheOutgoingLoad {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:4 track:_tracks[4]];
    XCTAssertEqual(_coordinator.targetIndex, 4u);
    XCTAssertEqual(_cache.cancelCount, 2u);
}

#pragma mark Deliveries

- (void)testDeliveryForTheTargetIsRecordedAndForwarded {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self deliverForURL:_tracks[3].url percent:0.5f];
    XCTAssertEqualObjects(_delegate.updatedIndexes, @[@3]);
    XCTAssertFalse([_coordinator isCompleteAtIndex:3]);
}

// The cache detaches a superseded decode rather than aborting it, so a
// delivery can outlive its retarget. It is dropped on the value.
- (void)testDeliveryForADepartedURLIsDropped {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [self deliverForURL:_tracks[3].url percent:1.0f];
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
    XCTAssertFalse([_coordinator isCompleteAtIndex:4]);
}

- (void)testFullDeliveryMarksThePageComplete {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self deliverForURL:_tracks[3].url percent:1.0f];
    XCTAssertTrue([_coordinator isCompleteAtIndex:3]);
}

- (void)testFailureForTheTargetSettlesItAndAllowsRetry {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self failForURL:_tracks[3].url];
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);
    XCTAssertEqualObjects(_delegate.failedIndexes, @[@3]);

    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqualObjects(_cache.loadedURLs, (@[_tracks[3].url, _tracks[3].url]));
}

- (void)testFailureForADepartedURLIsDropped {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [self failForURL:_tracks[3].url];
    XCTAssertEqual(_coordinator.targetIndex, 4u);
    XCTAssertEqual(_delegate.failedIndexes.count, 0u);
}

- (void)testFailureDuringAHoldIsForwardedOnRelease {
    [_coordinator requestIndex:3 track:_tracks[3]];
    _coordinator.held = YES;
    [self failForURL:_tracks[3].url];
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);
    XCTAssertEqual(_delegate.failedIndexes.count, 0u);

    _coordinator.held = NO;
    XCTAssertEqualObjects(_delegate.failedIndexes, @[@3]);
}

- (void)testRequestDroppedDuringAHoldLoadsWhenTheSettlePathRetries {
    _coordinator.held = YES;
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqual(_cache.loadedURLs.count, 0u);
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);

    _coordinator.held = NO;
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqualObjects(_cache.loadedURLs, @[_tracks[3].url]);
    XCTAssertEqual(_coordinator.targetIndex, 3u);
}

// A completed page re-requested after a detour needs no second decode; its
// snapshot is what hydration draws.
- (void)testCompletedPageIsNotReloaded {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self deliverForURL:_tracks[3].url percent:1.0f];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqualObjects(_cache.loadedURLs, (@[_tracks[3].url, _tracks[4].url]));
}

#pragma mark Pruning and reset

- (void)testPruneDropsDistantPagesAndKeepsTheTarget {
    for (NSUInteger i = 0; i < 8; i++) {
        [_coordinator requestIndex:i track:_tracks[i]];
        [self deliverForURL:_tracks[i].url percent:1.0f];
    }
    [_coordinator pruneAroundIndex:7];
    XCTAssertTrue([_coordinator isCompleteAtIndex:7]);
    XCTAssertTrue([_coordinator isCompleteAtIndex:5]);
    XCTAssertFalse([_coordinator isCompleteAtIndex:0]);
    XCTAssertNil([_coordinator snapshotAtIndex:0]);
}

- (void)testResetForgetsEverythingSoALateDeliveryIsDropped {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator reset];
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);
    [self deliverForURL:_tracks[3].url percent:1.0f];
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
}

@end
