//
// The iOS pager's waveform bookkeeping: N pages against one load-at-a-time
// cache, pointing that load and dropping deliveries that no longer belong.
// The cache is a duck-typed fake (Tests/AGENTS.md); the coordinator sends it
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
@property (nonatomic, strong) NSMutableArray *cacheReads;
@property (nonatomic, strong) NSMutableArray<NSURL *> *loadedURLs;
@end

@implementation FakeWaveformCache
- (instancetype)init {
    self = [super init];
    if (self) {
        _loadedURLs = [NSMutableArray array];
        _cacheReads = [NSMutableArray array];
    }
    return self;
}
- (void)cachedWaveformForTrack:(AudioTrack *)track completion:(void (^)(CodableAudioWaveform *))completion {
    [_cacheReads addObject:[completion copy]];
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
                       forTrack:(AudioTrack *)track {
    [_tempoURLs addObject:track.url];
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
- (void)deliverForTrack:(AudioTrack *)track percent:(float)percent {
    CodableAudioWaveform *waveform = (CodableAudioWaveform *)[NSObject new];
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveform:waveform
                                                    didLoadData:percent
                                                       forTrack:track];
}

- (void)failForTrack:(AudioTrack *)track {
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveformCache:(AudioWaveformCache *)_cache
                                              didFailToLoadForTrack:track];
}

- (void)testPrefetchReadsOnlyTheCacheAndLeavesTheActiveLoadAlone {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    XCTAssertEqual(_cache.cacheReads.count, 1u);
    XCTAssertEqual(_cache.cancelCount, 1u);
    XCTAssertEqual(_cache.loadedURLs.count, 1u);
    XCTAssertEqual(_coordinator.targetIndex, 3u);
    void (^complete)(CodableAudioWaveform *) = _cache.cacheReads[0];
    complete((CodableAudioWaveform *)[NSObject new]);
    XCTAssertTrue([_coordinator isCompleteAtIndex:4]);
    [_coordinator requestIndex:4 track:_tracks[4]];
    XCTAssertEqual(_cache.loadedURLs.count, 1u);
}

- (void)testPrefetchMissDoesNotFailThePageOrStartADecode {
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    void (^complete)(CodableAudioWaveform *) = _cache.cacheReads[0];
    complete(nil);
    XCTAssertEqual(_cache.loadedURLs.count, 0u);
    XCTAssertEqual(_delegate.failedIndexes.count, 0u);
    XCTAssertNil([_coordinator snapshotAtIndex:4]);
    [_coordinator requestIndex:4 track:_tracks[4]];
    XCTAssertEqual(_cache.loadedURLs.count, 1u);
}

- (void)testPrefetchLandingDuringSwipeIsHeldUntilItEnds {
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    _coordinator.held = YES;
    void (^complete)(CodableAudioWaveform *) = _cache.cacheReads[0];
    complete((CodableAudioWaveform *)[NSObject new]);
    XCTAssertTrue([_coordinator isCompleteAtIndex:4]);
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
    [_coordinator prefetchIndex:5 track:_tracks[5]];
    XCTAssertEqual(_cache.cacheReads.count, 1u);
    _coordinator.held = NO;
    XCTAssertEqualObjects(_delegate.updatedIndexes, @[@4]);
}

- (void)testResetAndPruneRejectOutstandingPrefetches {
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    void (^beforeReset)(CodableAudioWaveform *) = _cache.cacheReads.lastObject;
    [_coordinator reset];
    [_coordinator prefetchIndex:4 track:_tracks[4]];
    beforeReset((CodableAudioWaveform *)[NSObject new]);
    XCTAssertNil([_coordinator snapshotAtIndex:4]);
    void (^beforePrune)(CodableAudioWaveform *) = _cache.cacheReads.lastObject;
    [_coordinator pruneAroundIndex:0];
    beforePrune((CodableAudioWaveform *)[NSObject new]);
    XCTAssertNil([_coordinator snapshotAtIndex:4]);
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
}

- (void)testPrefetchRejectsAnotherCueWindowAtTheSameIndex {
    AudioTrack *first = [[AudioTrack alloc] initWithURL:_tracks[4].url cueStart:0 cueEnd:4500
                                              title:nil performer:nil sheet:nil trackNumber:0];
    AudioTrack *second = [[AudioTrack alloc] initWithURL:_tracks[4].url cueStart:4500 cueEnd:0
                                               title:nil performer:nil sheet:nil trackNumber:0];
    [_coordinator prefetchIndex:4 track:first];
    [_coordinator prefetchIndex:4 track:second];
    void (^stale)(CodableAudioWaveform *) = _cache.cacheReads[0];
    stale((CodableAudioWaveform *)[NSObject new]);
    XCTAssertNil([_coordinator snapshotAtIndex:4]);
    void (^current)(CodableAudioWaveform *) = _cache.cacheReads[1];
    current((CodableAudioWaveform *)[NSObject new]);
    XCTAssertTrue([_coordinator isCompleteAtIndex:4]);
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

static AudioTrack *CueRow(NSUInteger start, NSUInteger end) {
    return [[AudioTrack alloc] initWithURL:[NSURL fileURLWithPath:@"/tmp/vibe-mix.flac"]
                                  cueStart:start cueEnd:end title:nil performer:nil
                                     sheet:nil trackNumber:0];
}

// Rows of one file each have a waveform, so the page's row, not its file, is
// what a repeat request is matched on.
- (void)testSameIndexWithAnotherRowOfTheSameFileReloads {
    [_coordinator requestIndex:3 track:CueRow(0, 4500)];
    [_coordinator requestIndex:3 track:CueRow(4500, 0)];
    XCTAssertEqual(_cache.loadedURLs.count, 2u);
    [_coordinator requestIndex:3 track:CueRow(4500, 0)];
    XCTAssertEqual(_cache.loadedURLs.count, 2u);
}

// A late delivery for the departed row carries the page's file, so only the
// window tells it apart.
- (void)testDeliveryForAnotherRowOfTheSameFileIsDropped {
    [_coordinator requestIndex:3 track:CueRow(0, 4500)];
    [_coordinator requestIndex:4 track:CueRow(4500, 0)];
    [self deliverForTrack:CueRow(0, 4500) percent:1.0f];
    [self failForTrack:CueRow(0, 4500)];
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
    XCTAssertEqual(_delegate.failedIndexes.count, 0u);
    XCTAssertEqual(_coordinator.targetIndex, 4u);

    [self deliverForTrack:CueRow(4500, 0) percent:1.0f];
    XCTAssertEqualObjects(_delegate.updatedIndexes, @[@4]);
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
    [self deliverForTrack:_tracks[3] percent:0.5f];
    XCTAssertEqualObjects(_delegate.updatedIndexes, @[@3]);
    XCTAssertFalse([_coordinator isCompleteAtIndex:3]);
}

// The cache detaches a superseded decode rather than aborting it, so a
// delivery can outlive its retarget. It is dropped on the value.
- (void)testDeliveryForADepartedURLIsDropped {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [self deliverForTrack:_tracks[3] percent:1.0f];
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
    XCTAssertFalse([_coordinator isCompleteAtIndex:4]);
}

// A tempo is forwarded as delivered — with its track, untargeted and unheld —
// because the model matches it across every row, not by page.
- (void)testTempoIsForwardedByTrackWhateverThePageAndHold {
    [_coordinator requestIndex:3 track:_tracks[3]];
    _coordinator.held = YES;
    [(id<AudioWaveformCacheDelegate>)_coordinator audioWaveformCache:(AudioWaveformCache *)_cache
                                                        didDetectBPM:128 forTrack:_tracks[5]];
    XCTAssertEqualObjects(_delegate.tempoURLs, @[_tracks[5].url]);
    XCTAssertEqualObjects(_delegate.tempos, @[@128]);
}

- (void)testFullDeliveryMarksThePageComplete {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self deliverForTrack:_tracks[3] percent:1.0f];
    XCTAssertTrue([_coordinator isCompleteAtIndex:3]);
}

- (void)testFailureForTheTargetSettlesItAndAllowsRetry {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [self failForTrack:_tracks[3]];
    XCTAssertEqual(_coordinator.targetIndex, NSNotFound);
    XCTAssertEqualObjects(_delegate.failedIndexes, @[@3]);

    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqualObjects(_cache.loadedURLs, (@[_tracks[3].url, _tracks[3].url]));
}

- (void)testFailureForADepartedURLIsDropped {
    [_coordinator requestIndex:3 track:_tracks[3]];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [self failForTrack:_tracks[3]];
    XCTAssertEqual(_coordinator.targetIndex, 4u);
    XCTAssertEqual(_delegate.failedIndexes.count, 0u);
}

- (void)testFailureDuringAHoldIsForwardedOnRelease {
    [_coordinator requestIndex:3 track:_tracks[3]];
    _coordinator.held = YES;
    [self failForTrack:_tracks[3]];
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
    [self deliverForTrack:_tracks[3] percent:1.0f];
    [_coordinator requestIndex:4 track:_tracks[4]];
    [_coordinator requestIndex:3 track:_tracks[3]];
    XCTAssertEqualObjects(_cache.loadedURLs, (@[_tracks[3].url, _tracks[4].url]));
}

#pragma mark Pruning and reset

- (void)testPruneDropsDistantPagesAndKeepsTheTarget {
    for (NSUInteger i = 0; i < 8; i++) {
        [_coordinator requestIndex:i track:_tracks[i]];
        [self deliverForTrack:_tracks[i] percent:1.0f];
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
    [self deliverForTrack:_tracks[3] percent:1.0f];
    XCTAssertEqual(_delegate.updatedIndexes.count, 0u);
}

@end
