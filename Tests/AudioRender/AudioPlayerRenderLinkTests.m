//
//  AudioPlayerRenderLinkTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenRules.h"
#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"
#import "LinkStore.h"
#import "PlaceholderFiles.h"

// A link opened through LinkStore over HTTPStub: the probe, the placeholder,
// the coordinator's streaming open of the store's fetch, and the client's
// resends, all production. Played on the decode pool, Declick off, and at the
// file's own rate, so every edge is a cut and the capture is the file's own
// samples.
@interface AudioPlayerRenderLinkTests : AudioPlayerRenderTests
@end

@implementation AudioPlayerRenderLinkTests {
    HTTPStub *_stub;
    LinkStore *_links;
    NSMutableArray<dispatch_semaphore_t> *_gates;
}

static NSString *const kLinkFixture = @"noise-48000-24-2.wav";
// The fixture's frame and header, 48 kHz 24-bit stereo.
static const NSUInteger kLinkFrameBytes = 6, kLinkHeaderBytes = 44;

- (void)setUp {
    [super setUp];
    _stub = [[HTTPStub alloc] init];
    LinkClient *client = [[LinkClient alloc] initWithConfiguration:_stub.configuration];
    client.retryDelayScale = 0.01;
    _links = [[LinkStore alloc] initWithClient:client rootURL:[_temporary URLByAppendingPathComponent:@"Links"
                                                                                           isDirectory:YES]];
    [_links installAsRemoteBackend];
    _gates = [NSMutableArray array];
}

- (void)tearDown {
    // A held stub delivery goes on to find its load stopped.
    for (dispatch_semaphore_t gate in _gates) {
        dispatch_semaphore_signal(gate);
    }
    [super tearDown];
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
}

// The fixture served with a strong ETag, opened as a link: its placeholder.
- (NSURL *)link {
    [_stub serveData:[NSData dataWithContentsOfURL:[self fixture:kLinkFixture]]
              atPath:[@"/" stringByAppendingString:kLinkFixture] headers:@{@"ETag": @"\"v1\""}];
    __block NSURL *file = nil;
    __block NSError *failure = nil;
    [_links resolveURLString:[_stub URLForPath:kLinkFixture].absoluteString completion:^(NSURL *answer, NSError *error) {
        file = answer;
        failure = error ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:0 userInfo:nil];
    }];
    [self settleUntil:^BOOL { return failure != nil; }];
    XCTAssertNotNil(file, @"%@", failure);
    XCTAssertTrue([PlaceholderFiles isDatalessFile:file], @"a placeholder under the registered root");
    return file;
}

- (NSUInteger)offsetOfSecond:(double)seconds {
    return kLinkHeaderBytes + (NSUInteger)(seconds * 48000) * kLinkFrameBytes;
}

// The fetch's requests: the download, and its tail read when the fixture
// takes a window.
- (int)requestsPerFetch {
    uint64_t size = [NSData dataWithContentsOfURL:[self fixture:kLinkFixture]].length;
    return VibeAudioFileTailWindowBytes(kLinkFixture.pathExtension, size) > 0 ? 2 : 1;
}

// The fetch's download and its tail read arrive in either order. Each takes
// a stall past the tail's whole length, so only the download is held.
- (dispatch_semaphore_t)stallAt:(double)seconds {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_gates addObject:gate];
    NSString *path = [@"/" stringByAppendingString:kLinkFixture];
    for (int request = 0; request < [self requestsPerFetch]; request++) {
        [_stub queueStep:[HTTPStubStep stallAfter:[self offsetOfSecond:seconds] gate:gate] forPath:path];
    }
    return gate;
}

- (void)playLink:(NSURL *)url {
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
}

// Renders until `frames` audible frames follow a cut, and answers them.
- (NSData *)audibleFramesAfterCut:(NSUInteger)frames {
    [_capture setLength:0];
    XCTAssertTrue([self renderUntil:^BOOL { return VibeAudibleFrames(self->_capture, 2).length >= frames * 8; }]);
    return [VibeAudibleFrames(_capture, 2) subdataWithRange:NSMakeRange(0, frames * 8)];
}

- (void)assertFrames:(NSData *)frames are:(NSData *)reference from:(double)seconds {
    NSUInteger at = (NSUInteger)(seconds * 48000) * 8;
    NSDictionary *comparison = VibeComparePCM([reference subdataWithRange:NSMakeRange(at, frames.length)], frames, 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"from %.2f s: %@", seconds, comparison);
}

// A download held behind the audio: the voice holds silent in place, then
// plays on once the bytes come. The whole capture, silences taken out, is
// the file.
- (void)testALinkHoldsAtAStallAndPlaysOnExactly {
    NSURL *url = [self link];
    dispatch_semaphore_t gate = [self stallAt:1.0];
    [self playLink:url];
    NSData *reference = VibePCM([self read:[self fixture:kLinkFixture]]);
    [_capture setLength:0];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    NSTimeInterval held = _player.position;
    NSUInteger before = _capture.length / 8;
    [self render:9600];
    XCTAssertEqual(_player.position, held, @"the hold keeps its place");
    XCTAssertEqual(VibeRMS(_capture, 2, 0, NSMakeRange(before, _capture.length / 8 - before)), 0);
    XCTAssertTrue(_player.isPlaying);
    XCTAssertNotNil([_links availabilityForURL:url], @"streaming");

    dispatch_semaphore_signal(gate);
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    XCTAssertNil(_playError);
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:url], [NSData dataWithContentsOfURL:[self fixture:kLinkFixture]]);
}

// A link that ends while its download still runs lets it go. The stopped
// player keeps no handle, so the foreground hold drops and the download is
// cancelled rather than read to its last byte.
- (void)testALinkEndedMidDownloadLetsItsStreamGo {
    NSURL *url = [self link];
    [self stallAt:1.0];
    [self playLink:url];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
    XCTAssertTrue(coordinator.isForegroundTransferActive);
    [_player finishCurrentTrack];
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self settleUntil:^BOOL { return !coordinator.isForegroundTransferActive; }];
    XCTAssertFalse(coordinator.isForegroundTransferActive, @"the stopped player still holds the stream");
    XCTAssertTrue(_player.isStopped);
}

// A seek past the download's edge lands once the bytes come. A seek back into what has arrived lands at once. Both play the
// file's own samples from their targets.
- (void)testALinkSeeksAheadAndBehindExactly {
    NSURL *url = [self link];
    dispatch_semaphore_t gate = [self stallAt:1.0];
    [self playLink:url];
    NSData *reference = VibePCM([self read:[self fixture:kLinkFixture]]);
    // Held at the edge, its ring played out.
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);

    [_player seekToPosition:1.3];
    [_capture setLength:0];
    [self render:4800];
    XCTAssertEqual(VibeAudibleFrames(_capture, 2).length, 0u, @"nothing plays before its bytes");
    dispatch_semaphore_signal(gate);
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    XCTAssertTrue([self renderUntil:^BOOL { return VibeAudibleFrames(self->_capture, 2).length >= 9600 * 8; }]);
    [self assertFrames:[VibeAudibleFrames(_capture, 2) subdataWithRange:NSMakeRange(0, 9600 * 8)] are:reference from:1.3];

    [_player seekToPosition:0.2];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 2; }];
    [self assertFrames:[self audibleFramesAfterCut:9600] are:reference from:0.2];
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    XCTAssertNil(_playError);
}

// A connection lost mid-body is resent from the last byte written: the
// capture, silences taken out, is the file, with no failure.
- (void)testALinkDroppedMidBodyResumesExactly {
    NSURL *url = [self link];
    NSUInteger drop = [self offsetOfSecond:1.2];
    NSString *part = [PlaceholderFiles remotePlaceholderPartURL:url].path;
    NSString *path = [@"/" stringByAppendingString:kLinkFixture];
    for (int request = 0; request < [self requestsPerFetch]; request++) {
        [_stub queueStep:[HTTPStubStep dropAfter:drop ready:^BOOL {
            struct stat st;
            return stat(part.fileSystemRepresentation, &st) == 0 && (NSUInteger)st.st_size >= drop;
        }] forPath:path];
    }
    [self playLink:url];
    NSData *reference = VibePCM([self read:[self fixture:kLinkFixture]]);
    [_capture setLength:0];
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    XCTAssertNil(_playError);
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
    NSString *resend = [NSString stringWithFormat:@"bytes=%lu-", (unsigned long)drop];
    NSUInteger resends = [[_stub requestsToPath:path] indexesOfObjectsPassingTest:^BOOL(NSURLRequest *request,
                                                                                       NSUInteger index, BOOL *stop) {
        return [[request valueForHTTPHeaderField:@"Range"] isEqualToString:resend];
    }].count;
    XCTAssertEqual(resends, 1u, @"one resend, from the last byte");
}

@end
