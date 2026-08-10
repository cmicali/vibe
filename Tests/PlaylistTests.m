//
// The Playlist model: ordering, the current-index cursor and its boundary
// predicates, URL lookup with duplicate rows, and the replace-row rule —
// a fresh AudioTrack carrying the old row's duration and detected BPM.
//

#import <XCTest/XCTest.h>

#import "Playlist.h"

// Records every observer notification in order, so the tests can assert both
// that mutations notify and what rows they name.
@interface RecordingObserver : NSObject <PlaylistObserver>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@end

@implementation RecordingObserver

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    [self.events addObject:@"replaceAll"];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    [self.events addObject:[NSString stringWithFormat:@"append %lu-%lu",
                            (unsigned long)indexes.firstIndex, (unsigned long)indexes.lastIndex]];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [self.events addObject:[NSString stringWithFormat:@"replace %lu", (unsigned long)index]];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [self.events addObject:[NSString stringWithFormat:@"index %lu->%lu",
                            (unsigned long)previousIndex, (unsigned long)playlist.currentIndex]];
}

@end

@interface PlaylistTests : XCTestCase
@end

@implementation PlaylistTests

static NSURL *URLNamed(NSString *filename) {
    NSString *path = [@"/private/tmp/vibe-tests/" stringByAppendingString:filename];
    return [NSURL fileURLWithPath:path];
}

static Playlist *PlaylistWithFiles(NSArray<NSString *> *filenames) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in filenames) {
        [urls addObject:URLNamed(name)];
    }
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithURLs:urls];
    return playlist;
}

#pragma mark - Ordering

- (void)testReplaceAllOrdersTracksAndResetsCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects([playlist trackAtIndex:0].url, URLNamed(@"a.mp3"));
    XCTAssertEqualObjects([playlist trackAtIndex:1].url, URLNamed(@"b.mp3"));
    XCTAssertEqualObjects([playlist trackAtIndex:2].url, URLNamed(@"c.mp3"));
    XCTAssertNil([playlist trackAtIndex:3]);
}

- (void)testAppendExtendsWithoutTouchingCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    XCTAssertEqual(playlist.currentIndex, 1u);
    [playlist appendURLs:@[URLNamed(@"c.mp3")]];
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqualObjects([playlist trackAtIndex:2].url, URLNamed(@"c.mp3"));
}

- (void)testAppendToEmptyPlaylist {
    Playlist *playlist = [Playlist new];
    [playlist appendURLs:@[URLNamed(@"a.mp3")]];
    XCTAssertEqual(playlist.count, 1u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"a.mp3"));
}

- (void)testClearEmptiesAndResetsCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    [playlist clear];
    XCTAssertEqual(playlist.count, 0u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertNil(playlist.currentTrack);
    XCTAssertFalse(playlist.hasNextTrack);
    XCTAssertFalse(playlist.hasPreviousTrack);
}

- (void)testTracksIsADefensiveCopy {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    NSArray<AudioTrack *> *snapshot = playlist.tracks;
    [playlist appendURLs:@[URLNamed(@"b.mp3")]];
    XCTAssertEqual(snapshot.count, 1u);
    XCTAssertEqual(playlist.count, 2u);
}

#pragma mark - next / previous boundaries

- (void)testNextAdvancesUntilTheEnd {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    XCTAssertTrue(playlist.hasNextTrack);
    XCTAssertFalse(playlist.hasPreviousTrack);
    XCTAssertTrue([playlist next]);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertFalse(playlist.hasNextTrack);
    // At the last track, next refuses and the cursor stays put.
    XCTAssertFalse([playlist next]);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testPreviousRetreatsUntilTheStart {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    XCTAssertTrue([playlist previous]);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertFalse([playlist previous]);
    XCTAssertEqual(playlist.currentIndex, 0u);
}

- (void)testBoundariesOnEmptyAndSingleTrackPlaylists {
    Playlist *empty = [Playlist new];
    XCTAssertFalse(empty.hasNextTrack);
    XCTAssertFalse(empty.hasPreviousTrack);
    XCTAssertFalse([empty next]);
    XCTAssertFalse([empty previous]);

    Playlist *single = PlaylistWithFiles(@[@"a.mp3"]);
    XCTAssertFalse(single.hasNextTrack);
    XCTAssertFalse(single.hasPreviousTrack);
}

#pragma mark - Lookup

- (void)testIndexesOfTracksWithURLFindsEveryDuplicateRow {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3"]);
    NSIndexSet *indexes = [playlist indexesOfTracksWithURL:URLNamed(@"a.mp3")];
    XCTAssertEqual(indexes.count, 2u);
    XCTAssertTrue([indexes containsIndex:0]);
    XCTAssertTrue([indexes containsIndex:2]);
    XCTAssertEqual([playlist indexesOfTracksWithURL:URLNamed(@"missing.mp3")].count, 0u);
}

- (void)testTrackForURLReturnsTheFirstMatch {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3"]);
    AudioTrack *found = [playlist trackForURL:URLNamed(@"a.mp3")];
    XCTAssertEqual(found, [playlist trackAtIndex:0]);
    XCTAssertNil([playlist trackForURL:URLNamed(@"missing.mp3")]);
}

- (void)testGetIndexForTrackIsAnIdentityLookup {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"a.mp3"]);
    XCTAssertEqual([playlist getIndexForTrack:[playlist trackAtIndex:0]], 0);
    XCTAssertEqual([playlist getIndexForTrack:[playlist trackAtIndex:1]], 1);
    // A different AudioTrack for the same file is a different row.
    XCTAssertEqual([playlist getIndexForTrack:[AudioTrack withURL:URLNamed(@"a.mp3")]], -1);
    XCTAssertEqual([playlist getIndexForTrack:nil], -1);
}

- (void)testIsCurrentTrackComparesIdentity {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    XCTAssertTrue([playlist isCurrentTrack:[playlist trackAtIndex:0]]);
    XCTAssertFalse([playlist isCurrentTrack:[playlist trackAtIndex:1]]);
}

#pragma mark - Replace

- (void)testReplaceMintsAFreshTrackAndCarriesDurationAndBPM {
    Playlist *playlist = PlaylistWithFiles(@[@"a.wav", @"b.mp3"]);
    AudioTrack *outgoing = [playlist trackAtIndex:0];
    outgoing.duration = 123.5;
    outgoing.detectedBPM = 128.0f;

    AudioTrack *incoming = [playlist replaceTrackAtIndex:0 withURL:URLNamed(@"a.flac")];
    XCTAssertNotNil(incoming);
    XCTAssertNotEqual(incoming, outgoing);
    XCTAssertEqualObjects(incoming.url, URLNamed(@"a.flac"));
    XCTAssertEqual(incoming.duration, 123.5);
    XCTAssertEqual(incoming.detectedBPM, 128.0f);
    XCTAssertEqual([playlist trackAtIndex:0], incoming);

    // The row map follows the swap: the departed track no longer resolves,
    // and the fresh one resolves to the row it took over.
    XCTAssertEqual([playlist getIndexForTrack:incoming], 0);
    XCTAssertEqual([playlist getIndexForTrack:outgoing], -1);
}

- (void)testReplaceRefusesOutOfRange {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    XCTAssertNil([playlist replaceTrackAtIndex:1 withURL:URLNamed(@"b.mp3")]);
    XCTAssertEqual(playlist.count, 1u);
}

- (void)testReplaceLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    [playlist replaceTrackAtIndex:1 withURL:URLNamed(@"b.flac")];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"b.flac"));
}

#pragma mark - Observer

- (void)testMutationsNotifyTheObserverWithTheAffectedRows {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;

    [playlist next];
    [playlist previous];
    [playlist appendURLs:@[URLNamed(@"c.mp3"), URLNamed(@"d.mp3")]];
    [playlist replaceTrackAtIndex:0 withURL:URLNamed(@"a.flac")];
    [playlist clear];

    NSArray *expected = @[@"index 0->1", @"index 1->0", @"append 2-3", @"replace 0", @"replaceAll"];
    XCTAssertEqualObjects(observer.events, expected);
}

- (void)testSettingTheSameCurrentIndexStillNotifies {
    // A double-click on the already-playing row re-renders it immediately.
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    playlist.currentIndex = 0;
    XCTAssertEqualObjects(observer.events, @[@"index 0->0"]);
}

- (void)testBoundaryRefusalsDoNotNotify {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    [playlist next];
    [playlist previous];
    [playlist appendURLs:@[]];
    XCTAssertEqual(observer.events.count, 0u);
}

@end
