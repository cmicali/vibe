//
// AudioTrack's derived display values and the BPM precedence rule.
//
// The metadata stand-in below is duck-typed: AudioTrack only ever sends
// messages to its metadata and never names the class, so a fake cast to the
// property type behaves identically at runtime and keeps TagLib (and its ~70
// vendored sources) out of the test target.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"

@interface FakeTrackMetadata : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic) float bpm;
@property (nonatomic) NSInteger key;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong) NSImage *cachedArt;
@property (nonatomic, strong) NSImage *cachedThumbnail;
@property (nonatomic) BOOL parsedOK;
@end

@implementation FakeTrackMetadata
- (instancetype)init {
    self = [super init];
    // The real AudioTrackMetadata inits key to -1 (0 would be C major); the
    // fake must match or every untagged fixture would read as tagged C.
    _key = -1;
    return self;
}
@end

@interface AudioTrackTests : XCTestCase
@end

@implementation AudioTrackTests

static AudioTrack *TrackNamed(NSString *filename) {
    NSString *path = [@"/private/tmp/vibe-tests/" stringByAppendingString:filename];
    return [AudioTrack withURL:[NSURL fileURLWithPath:path]];
}

static void Attach(AudioTrack *track, FakeTrackMetadata *fake) {
    [track installMetadataIfUnresolved:(AudioTrackMetadata *)fake];
}

#pragma mark - BPM precedence

- (void)testTaggedTempoBeatsAnalyzedTempo {
    // The cross-directory guarantee: a file's own tag always wins. The BPM
    // label and the bar-aligned skips both read through here.
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.bpm = 128.0f;
    Attach(track, tagged);
    track.detectedBPM = 90.0f;

    XCTAssertEqual(track.bpm, 128.0f);
}

- (void)testAnalyzedTempoIsUsedWhenTheFileIsUntagged {
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *untagged = [FakeTrackMetadata new];
    untagged.bpm = 0.0f;
    Attach(track, untagged);
    track.detectedBPM = 174.0f;

    XCTAssertEqual(track.bpm, 174.0f);
}

- (void)testAnalyzedTempoIsUsedBeforeMetadataArrives {
    AudioTrack *track = TrackNamed(@"song.mp3");
    track.detectedBPM = 120.0f;
    XCTAssertEqual(track.bpm, 120.0f);
}

- (void)testTempoIsZeroWhenNeitherSourceKnowsIt {
    XCTAssertEqual(TrackNamed(@"song.mp3").bpm, 0.0f);
}

#pragma mark - Key precedence

- (void)testTaggedKeyBeatsAnalyzedKey {
    // Same cross-directory guarantee as tempo: the file's own tag wins.
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.key = 21; // Am
    Attach(track, tagged);
    track.detectedKey = 0; // C — a valid key, so precedence must not treat it as absent

    XCTAssertEqual(track.key, 21);
}

- (void)testTaggedCMajorIsNotMistakenForUntagged {
    // 0 is C major, the value nil-messaging would fabricate — the classic trap.
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.key = 0; // C
    Attach(track, tagged);
    track.detectedKey = 21;

    XCTAssertEqual(track.key, 0);
}

- (void)testAnalyzedKeyIsUsedWhenTheFileIsUntagged {
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *untagged = [FakeTrackMetadata new];
    Attach(track, untagged); // fake inits key to -1
    track.detectedKey = 18; // F#m

    XCTAssertEqual(track.key, 18);
}

- (void)testAnalyzedKeyIsUsedBeforeMetadataArrives {
    AudioTrack *track = TrackNamed(@"song.mp3");
    track.detectedKey = 3; // Eb
    XCTAssertEqual(track.key, 3);
}

- (void)testKeyIsNoneWhenNeitherSourceKnowsIt {
    XCTAssertEqual(TrackNamed(@"song.mp3").key, -1);
}

#pragma mark - Title fallback

- (void)testTitleFallsBackToTheFilenameWithoutItsExtension {
    XCTAssertEqualObjects(TrackNamed(@"My Song.mp3").title, @"My Song");
    XCTAssertEqualObjects(TrackNamed(@"tone.flac").title, @"tone");
}

- (void)testFilenameFallbackIsTrimmed {
    XCTAssertEqualObjects(TrackNamed(@"  Padded  .mp3").title, @"Padded");
}

- (void)testFilenameFallbackKeepsInteriorDots {
    // Only the real extension comes off — "Vol. 2" must survive intact.
    XCTAssertEqualObjects(TrackNamed(@"Best of Vol. 2.mp3").title, @"Best of Vol. 2");
}

- (void)testTaggedTitleBeatsTheFilename {
    AudioTrack *track = TrackNamed(@"01 - track.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.title = @"Real Title";
    Attach(track, tagged);

    XCTAssertEqualObjects(track.title, @"Real Title");
}

- (void)testEmptyTaggedTitleFallsBackToTheFilename {
    // A tag present but blank must not blank the row.
    AudioTrack *track = TrackNamed(@"01 - track.mp3");
    FakeTrackMetadata *blank = [FakeTrackMetadata new];
    blank.title = @"";
    Attach(track, blank);

    XCTAssertEqualObjects(track.title, @"01 - track");
}

#pragma mark - Artist

- (void)testArtistIsEmptyRatherThanNilWhenUnknown {
    // Callers measure .length; nil would read as empty anyway, but the
    // singleLineTitle format string would print "(null)".
    XCTAssertEqualObjects(TrackNamed(@"song.mp3").artist, @"");
}

- (void)testArtistComesFromMetadata {
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.artist = @"Art Tester";
    Attach(track, tagged);

    XCTAssertEqualObjects(track.artist, @"Art Tester");
}

#pragma mark - hasArtistAndTitle

- (void)testHasArtistAndTitleRequiresBothFromMetadata {
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *both = [FakeTrackMetadata new];
    both.artist = @"Art Tester";
    both.title = @"Red Art Test";
    Attach(track, both);

    XCTAssertTrue(track.hasArtistAndTitle);
}

- (void)testHasArtistAndTitleIgnoresTheFilenameFallback {
    // Deliberate asymmetry: it tests metadata.title, NOT the filename-derived
    // .title. A tagless file has a perfectly good display title but is not
    // "artist and title" — inlining .title here would make every tagless file
    // with an artist tag render as "Artist - filename".
    AudioTrack *track = TrackNamed(@"a good filename.mp3");
    FakeTrackMetadata *artistOnly = [FakeTrackMetadata new];
    artistOnly.artist = @"Art Tester";
    artistOnly.title = @"";
    Attach(track, artistOnly);

    XCTAssertEqualObjects(track.title, @"a good filename", @"title still falls back");
    XCTAssertFalse(track.hasArtistAndTitle, @"but that fallback is not a tagged title");
}

- (void)testHasArtistAndTitleIsFalseWithNoMetadata {
    XCTAssertFalse(TrackNamed(@"song.mp3").hasArtistAndTitle);
}

#pragma mark - singleLineTitle

- (void)testSingleLineTitleJoinsArtistAndTitle {
    AudioTrack *track = TrackNamed(@"whatever.mp3");
    FakeTrackMetadata *both = [FakeTrackMetadata new];
    both.artist = @"Art Tester";
    both.title = @"Red Art Test";
    Attach(track, both);

    XCTAssertEqualObjects(track.singleLineTitle, @"Art Tester - Red Art Test");
}

- (void)testSingleLineTitlePrettifiesUnderscoresInTheFallback {
    XCTAssertEqualObjects(TrackNamed(@"my_great_song.mp3").singleLineTitle, @"my great song");
}

- (void)testSingleLineTitleLeavesTaggedTitlesAlone {
    // Underscore replacement is a filename affordance; a real tag is verbatim.
    AudioTrack *track = TrackNamed(@"whatever.mp3");
    FakeTrackMetadata *both = [FakeTrackMetadata new];
    both.artist = @"A";
    both.title = @"under_score";
    Attach(track, both);

    XCTAssertEqualObjects(track.singleLineTitle, @"A - under_score");
}

#pragma mark - Duration

- (void)testDurationIsUnsetUntilPublished {
    // -1 is the sentinel; with no metadata the fake's 0 is what surfaces.
    AudioTrack *track = TrackNamed(@"song.mp3");
    XCTAssertEqualObjects(track.durationString, @"", @"no duration renders as empty, not 0:00");
}

- (void)testPublishedDurationRendersAndMemoizes {
    AudioTrack *track = TrackNamed(@"song.mp3");
    [track setDuration:125];
    XCTAssertEqual(track.duration, 125);
    XCTAssertEqualObjects(track.durationString, @"2:05");
    XCTAssertEqualObjects(track.durationString, @"2:05", @"second read hits the memo");
}

- (void)testDurationStringFollowsANewDuration {
    // The memo is keyed on the value, so a re-published length re-renders.
    AudioTrack *track = TrackNamed(@"song.mp3");
    [track setDuration:60];
    XCTAssertEqualObjects(track.durationString, @"1:00");
    [track setDuration:120];
    XCTAssertEqualObjects(track.durationString, @"2:00");
}

- (void)testPlayerDurationBeatsMetadataDuration {
    // The decoded length is authoritative over the tagged one.
    AudioTrack *track = TrackNamed(@"song.mp3");
    FakeTrackMetadata *tagged = [FakeTrackMetadata new];
    tagged.duration = 999;
    Attach(track, tagged);
    XCTAssertEqual(track.duration, 999, @"metadata answers until the decode publishes");

    [track setDuration:125];
    XCTAssertEqual(track.duration, 125);
}

#pragma mark - Metadata installation

- (void)testConcurrentMetadataInstallationPublishesOnlyTheWinner {
    AudioTrack *track = TrackNamed(@"song.flac");
    FakeTrackMetadata *cached = [FakeTrackMetadata new];
    cached.parsedOK = YES;
    FakeTrackMetadata *adopted = [FakeTrackMetadata new];
    adopted.parsedOK = YES;

    dispatch_semaphore_t cacheRead = dispatch_semaphore_create(0);
    dispatch_semaphore_t allowCacheInstall = dispatch_semaphore_create(0);
    XCTestExpectation *cacheAttemptFinished =
            [self expectationWithDescription:@"cache install attempted"];
    __block BOOL cacheInstalled = YES;
    __block NSUInteger publications = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_signal(cacheRead);
        dispatch_semaphore_wait(allowCacheInstall, DISPATCH_TIME_FOREVER);
        cacheInstalled = [track installMetadataIfUnresolved:
                (AudioTrackMetadata *)cached];
        if (cacheInstalled) {
            @synchronized (track) {
                publications++;
            }
        }
        [cacheAttemptFinished fulfill];
    });

    XCTAssertEqual(dispatch_semaphore_wait(
            cacheRead, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertTrue([track installMetadataIfUnresolved:(AudioTrackMetadata *)adopted]);
    @synchronized (track) {
        publications++;
    }
    dispatch_semaphore_signal(allowCacheInstall);
    [self waitForExpectations:@[cacheAttemptFinished] timeout:1];

    XCTAssertFalse(cacheInstalled);
    XCTAssertEqual(track.metadata, (AudioTrackMetadata *)adopted);
    XCTAssertEqual(publications, 1u);
}

- (void)testQueuedDeliveryDropsAfterMetadataReplacementBeforeMainRuns {
    XCTAssertTrue(NSThread.isMainThread);
    AudioTrack *track = TrackNamed(@"song.flac");
    FakeTrackMetadata *fallback = [FakeTrackMetadata new];
    FakeTrackMetadata *cached = [FakeTrackMetadata new];
    cached.parsedOK = YES;
    Attach(track, fallback);

    dispatch_semaphore_t fallbackEnqueued = dispatch_semaphore_create(0);
    XCTestExpectation *fallbackAttempted =
            [self expectationWithDescription:@"queued fallback checked on main"];
    XCTestExpectation *cacheDelivered =
            [self expectationWithDescription:@"cache winner delivered on main"];
    __block BOOL fallbackWasDelivered = YES;
    __block NSUInteger publications = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            fallbackWasDelivered = [track
                    deliverIfMetadataStillInstalled:(AudioTrackMetadata *)fallback
                                          usingBlock:^{ publications++; }];
            [fallbackAttempted fulfill];
        });
        dispatch_semaphore_signal(fallbackEnqueued);
    });

    XCTAssertEqual(dispatch_semaphore_wait(
            fallbackEnqueued, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertTrue([track installMetadataIfUnresolved:(AudioTrackMetadata *)cached]);
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL delivered = [track
                deliverIfMetadataStillInstalled:(AudioTrackMetadata *)cached
                                      usingBlock:^{ publications++; }];
        XCTAssertTrue(delivered);
        [cacheDelivered fulfill];
    });

    [self waitForExpectations:@[fallbackAttempted, cacheDelivered] timeout:1];
    XCTAssertFalse(fallbackWasDelivered);
    XCTAssertEqual(track.metadata, (AudioTrackMetadata *)cached);
    XCTAssertEqual(publications, 1u);
}

- (void)testDeliveryKeepsReplacementOutUntilObserverReturns {
    AudioTrack *track = TrackNamed(@"song.flac");
    FakeTrackMetadata *fallback = [FakeTrackMetadata new];
    FakeTrackMetadata *cached = [FakeTrackMetadata new];
    cached.parsedOK = YES;
    Attach(track, fallback);

    dispatch_semaphore_t installerStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t installerFinished = dispatch_semaphore_create(0);
    __block BOOL cacheInstalled = NO;
    BOOL fallbackDelivered = [track
            deliverIfMetadataStillInstalled:(AudioTrackMetadata *)fallback
                                  usingBlock:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_signal(installerStarted);
            cacheInstalled = [track
                    installMetadataIfUnresolved:(AudioTrackMetadata *)cached];
            dispatch_semaphore_signal(installerFinished);
        });
        XCTAssertEqual(dispatch_semaphore_wait(
                installerStarted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
        XCTAssertNotEqual(dispatch_semaphore_wait(installerFinished,
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)), 0);
        XCTAssertEqual(track.metadata, (AudioTrackMetadata *)fallback);
    }];

    XCTAssertTrue(fallbackDelivered);
    XCTAssertEqual(dispatch_semaphore_wait(
            installerFinished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertTrue(cacheInstalled);
    XCTAssertEqual(track.metadata, (AudioTrackMetadata *)cached);
}

@end
