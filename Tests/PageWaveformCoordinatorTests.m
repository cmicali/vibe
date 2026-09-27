//
// The iOS pager's waveform bookkeeping: N pages against one load-at-a-time
// cache, pointing that load and dropping deliveries that no longer belong.
// The cache is a duck-typed fake (Tests/CLAUDE.md); the coordinator sends it
// three messages.
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
@property (nonatomic, strong) NSMutableArray<NSURL *> *tempoURLs;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *tempos;
@end

@implementation RecordingCoordinatorDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _updatedIndexes = [NSMutableArray array];
        _failedIndexes = [NSMutableArray array];
        _tempoURLs = [NSMutableArray array];
        _tempos = [NSMutableArray array];
    }
    return self;
}
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)coordinator
                   didDetectBPM:(float)bpm
                         forURL:(NSURL *)url {
    [_tempoURLs addObject:url];
    [_tempos addObject:@(bpm)];
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

// Any non-nil object will do: the coordinator only stores the waveform, in a
// dictionary where nil means no entry, and hands it on.
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

// A cell reload re-requests the targeted page; restarting the decode each time
// would never let a waveform complete.
- (void)testRepeatRequestForTheSameFileIsANoOp {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqual(_cache.loadedURLs.count, 1u);
    XCTAssertEqual(_cache.cancelCount, 1u);
}

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

// A tempo is forwarded as delivered — with its URL, untargeted and unheld —
// because the model matches it by URL across every row, not by page.
- (void)testTempoIsForwardedByURLWhateverThePageAndHold {
    [_coordinator requestIndex:3 track:_tracks[3]];
    _coordinator.held = YES;
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveformCache:(AudioWaveformCache *)_cache
                                                        didDetectBPM:128 forURL:_tracks[5].url];
    XCTAssertEqualObjects(_delegate.tempoURLs, @[_tracks[5].url]);
    XCTAssertEqualObjects(_delegate.tempos, @[@128]);
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
