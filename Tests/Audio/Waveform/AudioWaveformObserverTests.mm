//
//  AudioWaveformObserverTests.mm
//  VibeTests
//
//  The observer contract, through the real cache and loader over a store of
//  the test's own: what a decode feeds a sink, what a hit, a missing result,
//  a joined decode, a cancellation and a late completion deliver, and a cue
//  window's frames. The observer here records what its sinks saw, and can
//  hold its next sink on its first block so a decode stays in flight.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFixtures.h"
#import "AudioLoadTiming.h"
#import "AudioTrack.h"
#import "AudioWaveform.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformObserver.h"
#import "NSURL+Hash.h"
#import "TestFilesystemGuard.h"

#include <cmath>

// One decode's record: its rate and window, the frames it was fed, their
// loudest sample, and how often it finished.
@interface WaveformRecordingSink : NSObject <AudioWaveformSink>
@property (atomic) double sampleRate;
@property (atomic) NSRange window;
@property (atomic) NSUInteger frames;
@property (atomic) float peak;
@property (atomic) NSUInteger finishes;
@property (atomic, nullable) dispatch_semaphore_t gate;
@property (atomic, nullable) dispatch_semaphore_t entered;
@end

@implementation WaveformRecordingSink
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (self.gate && self.frames == 0) {
        dispatch_semaphore_signal(self.entered);
        dispatch_semaphore_wait(self.gate, DISPATCH_TIME_FOREVER);
    }
    float peak = self.peak;
    for (NSUInteger i = 0; i < frameCount; i++) {
        peak = MAX(peak, fabsf(samples[i]));
    }
    self.peak = peak;
    self.frames += frameCount;
}
- (id)waveformResult {
    self.finishes++;
    return @(self.frames);
}
@end

// An observer whose result is the frames its decode was fed.
@interface WaveformRecordingObserver : NSObject
@property (nonatomic, readonly) AudioWaveformObserver *observer;
// The next sink made blocks on its first block until the test releases it.
- (void)holdNextDecode;
- (BOOL)awaitHeld;
- (void)resume;
- (NSArray<WaveformRecordingSink *> *)sinks;
@end

@implementation WaveformRecordingObserver {
    NSMutableArray<WaveformRecordingSink *> *_sinks;
    // The next sink's gate, and every gate handed out and not yet opened.
    dispatch_semaphore_t _gate;
    dispatch_semaphore_t _entered;
    NSMutableArray<dispatch_semaphore_t> *_closed;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _sinks = [NSMutableArray array];
        _closed = [NSMutableArray array];
        __weak WaveformRecordingObserver *weakSelf = self;
        _observer = [[AudioWaveformObserver alloc] initWithIdentifier:identifier
                sinkFactory:^id<AudioWaveformSink>(double sampleRate, NSRange window) {
            WaveformRecordingSink *sink = [WaveformRecordingSink new];
            sink.sampleRate = sampleRate;
            sink.window = window;
            WaveformRecordingObserver *strongSelf = weakSelf;
            @synchronized (strongSelf) {
                sink.gate = strongSelf->_gate;
                sink.entered = strongSelf->_entered;
                strongSelf->_gate = nil;
                [strongSelf->_sinks addObject:sink];
            }
            return sink;
        }];
    }
    return self;
}

- (void)holdNextDecode {
    @synchronized (self) {
        _gate = dispatch_semaphore_create(0);
        _entered = dispatch_semaphore_create(0);
        [_closed addObject:_gate];
    }
}

- (BOOL)awaitHeld {
    return dispatch_semaphore_wait(_entered, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
}

- (void)resume {
    @synchronized (self) {
        for (dispatch_semaphore_t gate in _closed) {
            dispatch_semaphore_signal(gate);
        }
        [_closed removeAllObjects];
    }
}

- (NSArray<WaveformRecordingSink *> *)sinks {
    @synchronized (self) {
        return [_sinks copy];
    }
}

@end

// The cache's deliveries, on main, each with the track it carried.
@interface ObserverCacheRecorder : NSObject <AudioWaveformCacheDelegate>
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *completedTracks;
@property (nonatomic) NSMutableArray<id<VibePlayableItem>> *resultTracks;
@property (nonatomic) NSMutableArray<NSDictionary *> *results;
@property (nonatomic) NSUInteger failures;
@end

@implementation ObserverCacheRecorder
- (instancetype)init {
    if ((self = [super init])) {
        _completedTracks = [NSMutableArray array];
        _resultTracks = [NSMutableArray array];
        _results = [NSMutableArray array];
    }
    return self;
}
- (void)audioWaveform:(CodableAudioWaveform *)waveform didLoadData:(float)percentLoaded
             forTrack:(id<VibePlayableItem>)track {
    if (percentLoaded >= 1) {
        [_completedTracks addObject:track];
    }
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(id<VibePlayableItem>)track {
    _failures++;
}
- (void)audioWaveformCache:(AudioWaveformCache *)cache
            didLoadResults:(NSDictionary<NSString *, id> *)results
                  forTrack:(id<VibePlayableItem>)track {
    [_resultTracks addObject:track];
    [_results addObject:results];
}
@end

@interface AudioWaveformObserverTests : XCTestCase
@end

@implementation AudioWaveformObserverTests {
    NSURL *_tempDirectory;
    WaveformRecordingObserver *_frames;
    ObserverCacheRecorder *_recorder;
    AudioWaveformCache *_cache;
    // What each request lists.
    VibeWaveformAnalysis _analysis;
}

- (void)setUp {
    [super setUp];
    _tempDirectory = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_tempDirectory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    _frames = [[WaveformRecordingObserver alloc] initWithIdentifier:@"test.frames"];
    _recorder = [ObserverCacheRecorder new];
    _cache = [[AudioWaveformCache alloc] initWithRootPath:[_tempDirectory URLByAppendingPathComponent:@"cache"].path];
    _cache.delegate = _recorder;
    _analysis = (VibeWaveformAnalysis){.observers = @[_frames.observer]};
    __weak AudioWaveformObserverTests *weakSelf = self;
    _cache.analysisProvider = ^VibeWaveformAnalysis {
        AudioWaveformObserverTests *strongSelf = weakSelf;
        return strongSelf ? strongSelf->_analysis : (VibeWaveformAnalysis){};
    };
}

- (void)tearDown {
    [_frames resume];
    _cache = nil;
    [NSFileManager.defaultManager removeItemAtURL:_tempDirectory error:nil];
    [super tearDown];
}

// 44.1 kHz stereo float: ±0.5, but ±0.25 over [quietFrom, quietTo) seconds,
// so a window's samples can be told from the rest of the file's.
- (NSURL *)writeWAVNamed:(NSString *)name seconds:(double)seconds
               quietFrom:(double)quietFrom to:(double)quietTo {
    NSURL *url = [_tempDirectory URLByAppendingPathComponent:name];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:44100
                                                               channels:2 interleaved:NO];
    const AVAudioFrameCount total = (AVAudioFrameCount)(44100.0 * seconds);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:total];
    buffer.frameLength = total;
    for (AVAudioFrameCount i = 0; i < total; i++) {
        double t = i / 44100.0;
        float level = t >= quietFrom && t < quietTo ? 0.25f : 0.5f;
        buffer.floatChannelData[0][i] = buffer.floatChannelData[1][i] = (i % 2) ? level : -level;
    }
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"could not write fixture: %@", error);
    return url;
}

- (NSURL *)writeWAVNamed:(NSString *)name seconds:(double)seconds {
    return [self writeWAVNamed:name seconds:seconds quietFrom:seconds to:seconds];
}

- (BOOL)eventually:(BOOL (^)(void))condition {
    return VibeSpinUntil(condition);
}

// Whether the entry is on disk, read through the lane that never decodes.
// Its own result deliveries are not recorded.
- (BOOL)eventuallyCached:(AudioTrack *)track {
    __block BOOL cached = NO;
    _cache.delegate = nil;
    BOOL found = [self eventually:^BOOL {
        __block BOOL answered = NO;
        [self->_cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
            cached = waveform != nil;
            answered = YES;
        }];
        VibeSpinUntil(^BOOL { return answered; });
        return cached;
    }];
    _cache.delegate = _recorder;
    return found;
}

#pragma mark - A decode

// A sink is made per decode with the file's rate and the window, is fed every
// frame in order, finishes once, and its result is filed and delivered with
// the track.
- (void)testADecodeFeedsItsSinkEveryFrameAndDeliversTheResult {
    NSURL *url = [self writeWAVNamed:@"decode.wav" seconds:2.0];
    AudioTrack *track = [AudioTrack withURL:url];
    [_cache loadWaveformForTrack:track];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);

    XCTAssertEqual(_frames.sinks.count, 1u);
    WaveformRecordingSink *sink = _frames.sinks.firstObject;
    XCTAssertEqual(sink.sampleRate, 44100);
    XCTAssertTrue(NSEqualRanges(sink.window, NSMakeRange(0, 88200)));
    XCTAssertEqual(sink.frames, 88200u);
    XCTAssertEqual(sink.finishes, 1u);
    XCTAssertEqualObjects(_recorder.results.firstObject, @{@"test.frames": @88200});
    XCTAssertEqual(_recorder.resultTracks.firstObject, track);
    XCTAssertEqualObjects(_recorder.completedTracks, @[track]);
    XCTAssertEqual(_recorder.failures, 0u);
}

#pragma mark - A cache hit

// A hit decodes nothing: no sink is made and no decode is timed, and the
// filed result comes back with the summary.
- (void)testACacheHitDecodesNothingAndHandsBackTheResult {
    NSURL *url = [self writeWAVNamed:@"hit.wav" seconds:2.0];
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);

    [AudioLoadTiming reset];
    AudioTrack *again = [AudioTrack withURL:url];
    [_cache loadWaveformForTrack:again];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 2; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"a hit makes no sink");
    XCTAssertNil([AudioLoadTiming newestJSONForPath:url.path], @"a hit runs no decode");
    XCTAssertEqualObjects(_recorder.results.lastObject, @{@"test.frames": @88200});
    XCTAssertEqual(_recorder.resultTracks.lastObject, again);
    XCTAssertEqual(_recorder.completedTracks.lastObject, again);
}

#pragma mark - A missing result

// An entry without an observer's result misses for a request that lists it,
// which decodes again and replaces the entry. A request that does not list
// it takes the new entry, result and all.
- (void)testAnEntryWithoutAResultMissesForARequestThatListsIt {
    NSURL *url = [self writeWAVNamed:@"missing.wav" seconds:2.0];
    _analysis = (VibeWaveformAnalysis){};
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    XCTAssertEqual(_recorder.results.count, 0u, @"decoded without it, so it holds no result");
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);

    _analysis = (VibeWaveformAnalysis){.observers = @[_frames.observer]};
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"the missing result is a miss, decoded again");
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);

    _analysis = (VibeWaveformAnalysis){};
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 2; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"a request without it takes the new entry");
    XCTAssertEqualObjects(_recorder.results.lastObject, @{@"test.frames": @88200});
}

#pragma mark - A joined decode

// A request for a window already decoding joins it when that decode carries
// every observer it lists: one sink, one decode, delivered to the joiner.
- (void)testARequestJoinsADecodeThatCarriesItsObservers {
    NSURL *url = [self writeWAVNamed:@"joined.wav" seconds:2.0];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([_frames awaitHeld]);

    _analysis = (VibeWaveformAnalysis){};
    AudioTrack *joiner = [AudioTrack withURL:url];
    [_cache loadWaveformForTrack:joiner];
    [_frames resume];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"joined, not decoded twice");
    XCTAssertEqual(_recorder.completedTracks.firstObject, joiner);
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    XCTAssertEqualObjects(_recorder.results.firstObject, @{@"test.frames": @88200});
}

// One that lists an observer the running decode lacks does not join it. It
// gets a decode of its own, which carries both and files both. Longer than
// the two blocks a held decode can read ahead, so the stopped one ends
// partial and files nothing.
- (void)testARequestThatWantsMoreDoesNotJoin {
    NSURL *url = [self writeWAVNamed:@"more.wav" seconds:5.0];
    WaveformRecordingObserver *more = [[WaveformRecordingObserver alloc] initWithIdentifier:@"test.more"];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([_frames awaitHeld]);

    _analysis = (VibeWaveformAnalysis){.observers = @[_frames.observer, more.observer]};
    AudioTrack *wanting = [AudioTrack withURL:url];
    [_cache loadWaveformForTrack:wanting];
    [_frames resume];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    XCTAssertEqual(_recorder.completedTracks.firstObject, wanting);
    XCTAssertEqual(more.sinks.count, 1u);
    XCTAssertEqual(_frames.sinks.count, 2u, @"its own decode, beside the one it did not join");
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    NSDictionary *both = @{@"test.frames": @220500, @"test.more": @220500};
    XCTAssertEqualObjects(_recorder.results.firstObject, both);
    XCTAssertEqual(_recorder.failures, 0u);
}

#pragma mark - A cancellation

// A cancelled request detaches its decode, which finishes its sinks and files
// a whole entry. Its results still reach the receiver with its track, though
// its waveform does not, and the next request is a hit.
- (void)testACancelledRequestsDecodeStillFinishesItsSinks {
    NSURL *url = [self writeWAVNamed:@"cancelled.wav" seconds:2.0];
    AudioTrack *track = [AudioTrack withURL:url];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:track];
    XCTAssertTrue([_frames awaitHeld]);
    [_cache cancelLoad];
    [_frames resume];

    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    XCTAssertEqual(_frames.sinks.firstObject.finishes, 1u);
    XCTAssertEqual(_recorder.resultTracks.firstObject, track);
    XCTAssertEqual(_recorder.completedTracks.count, 0u, @"the cancelled request's waveform is not delivered");
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);

    [_cache loadWaveformForTrack:[AudioTrack withURL:url]];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"the filed entry is whole, so a hit");
    XCTAssertEqualObjects(_recorder.results.lastObject, @{@"test.frames": @88200});
}

#pragma mark - A late completion

// A decode superseded by another track's completes late: its waveform reaches
// no one, and its result carries its own track, never the current one, so a
// receiver matches it by source key.
- (void)testALateCompletionReachesOnlyItsOwnTrack {
    NSURL *first = [self writeWAVNamed:@"first.wav" seconds:2.0];
    NSURL *second = [self writeWAVNamed:@"second.wav" seconds:1.0];
    AudioTrack *late = [AudioTrack withURL:first];
    AudioTrack *current = [AudioTrack withURL:second];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:late];
    XCTAssertTrue([_frames awaitHeld]);
    [_cache loadWaveformForTrack:current];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    [_frames resume];

    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 2; }]);
    VibeSpinFor(kVibeTestNegativeWindow);
    XCTAssertEqualObjects(_recorder.completedTracks, @[current], @"the late waveform lands on no track");
    NSUInteger lateIndex = [_recorder.resultTracks indexOfObjectIdenticalTo:late];
    NSUInteger currentIndex = [_recorder.resultTracks indexOfObjectIdenticalTo:current];
    XCTAssertNotEqual(lateIndex, NSNotFound);
    XCTAssertNotEqual(currentIndex, NSNotFound);
    XCTAssertEqualObjects(_recorder.results[lateIndex], @{@"test.frames": @88200});
    XCTAssertEqualObjects(_recorder.results[currentIndex], @{@"test.frames": @44100});
}

// What a download that installs another version does under a decode: the
// file moves to another size, and every memoized key is retired. The rename
// leaves the decode reading the version it opened.
- (void)replace:(NSURL *)url withWAVOfSeconds:(double)seconds {
    NSURL *next = [self writeWAVNamed:@"next.wav" seconds:seconds];
    XCTAssertEqual(rename(next.fileSystemRepresentation, url.fileSystemRepresentation), 0);
    [NSURL invalidateMemoizedCacheKeys];
}

// The disk store's entry count, once the writes in flight have landed.
- (NSUInteger)filedEntries {
    __block NSUInteger count = NSNotFound;
    [_cache diskUsageWithCompletion:^(NSUInteger fileCount, unsigned long long totalBytes) {
        count = fileCount;
    }];
    XCTAssertTrue([self eventually:^BOOL { return count != NSNotFound; }]);
    return count;
}

// A decode that completes after its file was replaced by another version is
// stale: neither its waveform nor its result reaches the track, and nothing
// is filed under the old version's key. The current load decodes once more
// under the new key and delivers the version the file now holds.
- (void)testALateCompletionOfAReplacedVersionIsNotDelivered {
    NSURL *url = [self writeWAVNamed:@"replaced.wav" seconds:2.0];
    AudioTrack *track = [AudioTrack withURL:url];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:track];
    XCTAssertTrue([_frames awaitHeld]);
    [self replace:url withWAVOfSeconds:3.0];
    [_frames resume];

    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 1; }]);
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    VibeSpinFor(kVibeTestNegativeWindow);
    XCTAssertEqual(_frames.sinks.count, 2u, @"the stale decode, then the new version's");
    XCTAssertEqual(_frames.sinks.firstObject.frames, 88200u, @"the stale decode read the version it opened");
    XCTAssertEqualObjects(_recorder.completedTracks, @[track]);
    XCTAssertEqualObjects(_recorder.results, @[@{@"test.frames": @132300}], @"only the new version's result");
    XCTAssertEqual(_recorder.failures, 0u);
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);
    XCTAssertEqual([self filedEntries], 1u, @"the stale decode filed nothing");
}

// Retired memos alone are no new version: the key read again at completion
// is the one the decode was looked up under, so it is delivered and filed.
- (void)testALateCompletionOfAnUnchangedFileIsDelivered {
    NSURL *url = [self writeWAVNamed:@"unchanged.wav" seconds:2.0];
    AudioTrack *track = [AudioTrack withURL:url];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:track];
    XCTAssertTrue([_frames awaitHeld]);
    [NSURL invalidateMemoizedCacheKeys];
    [_frames resume];

    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    VibeSpinFor(kVibeTestNegativeWindow);
    XCTAssertEqual(_frames.sinks.count, 1u, @"delivered, not decoded again");
    XCTAssertEqualObjects(_recorder.completedTracks, @[track]);
    XCTAssertEqualObjects(_recorder.results, @[@{@"test.frames": @88200}]);
    XCTAssertEqual(_recorder.failures, 0u);
    XCTAssertTrue([self eventuallyCached:[AudioTrack withURL:url]]);
}

// A cue row's key is its file's plus its window, read again the same way. An
// unchanged image delivers its window. A replaced one is decoded once more,
// and that decode reads the new version's window: quiet in the old version,
// loud in the new.
- (void)testACueWindowsLateCompletionIsCheckedUnderItsWindowedKey {
    NSURL *url = [self writeWAVNamed:@"image.wav" seconds:4.0 quietFrom:1.0 to:3.0];
    AudioTrack *row = [[AudioTrack alloc] initWithURL:url cueStart:75 cueEnd:150
                                                title:nil performer:nil sheet:nil trackNumber:0];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:row];
    XCTAssertTrue([_frames awaitHeld]);
    [NSURL invalidateMemoizedCacheKeys];
    [_frames resume];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    XCTAssertEqual(_frames.sinks.count, 1u, @"an unchanged window is its key's version");
    XCTAssertEqualObjects(_recorder.completedTracks, @[row]);

    AudioTrack *next = [[AudioTrack alloc] initWithURL:url cueStart:150 cueEnd:225
                                                 title:nil performer:nil sheet:nil trackNumber:0];
    [_frames holdNextDecode];
    [_cache loadWaveformForTrack:next];
    XCTAssertTrue([_frames awaitHeld]);
    [self replace:url withWAVOfSeconds:5.0];
    [_frames resume];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.completedTracks.count == 2; }]);
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 2; }]);
    VibeSpinFor(kVibeTestNegativeWindow);
    NSArray<WaveformRecordingSink *> *sinks = _frames.sinks;
    XCTAssertEqual(sinks.count, 3u, @"the stale window's decode, then the new version's");
    XCTAssertEqual(sinks[1].peak, 0.25f, @"the stale decode read the old version's window");
    XCTAssertTrue(NSEqualRanges(sinks[2].window, NSMakeRange(88200, 44100)));
    XCTAssertEqual(sinks[2].peak, 0.5f, @"the retry read the new version's");
    XCTAssertEqualObjects(_recorder.completedTracks, (@[row, next]));
    XCTAssertEqualObjects(_recorder.results.lastObject, @{@"test.frames": @44100});
    XCTAssertEqual(_recorder.failures, 0u);
}

#pragma mark - A CUE window

// A cue row's decode reads only its window, so its sink is told the window
// and sees only its frames: the quiet second, none of the loud ones around it.
- (void)testACueWindowsSinkSeesOnlyItsFrames {
    NSURL *url = [self writeWAVNamed:@"image.wav" seconds:3.0 quietFrom:1.0 to:2.0];
    AudioTrack *row = [[AudioTrack alloc] initWithURL:url cueStart:75 cueEnd:150
                                                title:nil performer:nil sheet:nil trackNumber:0];
    [_cache loadWaveformForTrack:row];
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.results.count == 1; }]);
    WaveformRecordingSink *sink = _frames.sinks.firstObject;
    XCTAssertTrue(NSEqualRanges(sink.window, NSMakeRange(44100, 44100)));
    XCTAssertEqual(sink.frames, 44100u);
    XCTAssertEqual(sink.peak, 0.25f, @"no frame from outside the window");
    XCTAssertEqual(_recorder.resultTracks.firstObject, row);
    XCTAssertEqualObjects(_recorder.results.firstObject, @{@"test.frames": @44100});
}

@end
