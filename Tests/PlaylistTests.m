//
// The Playlist model: ordering, the current-index cursor and its boundary
// predicates, URL lookup with duplicate rows, the replace-row rule — a fresh
// AudioTrack carrying the old row's duration and detected BPM — and row
// removal, the one mutation that moves rows and so the one whose two indexes
// are rebuilt rather than patched.
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

- (void)playlist:(Playlist *)playlist didRemoveTrackAtIndex:(NSUInteger)index {
    // The final state is recorded alongside the payload, because the model's
    // contract is that everything is coherent BEFORE the observer is called.
    [self.events addObject:[NSString stringWithFormat:@"remove %lu cursor %lu count %lu",
                            (unsigned long)index,
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

- (void)playlist:(Playlist *)playlist didInsertTrackAtIndex:(NSUInteger)index {
    [self.events addObject:[NSString stringWithFormat:@"insert %lu cursor %lu count %lu",
                            (unsigned long)index,
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
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

#pragma mark - Remove

- (void)testRemoveRefusesOutOfRangeAndAnEmptyPlaylist {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertNil([playlist removeTrackAtIndex:2]);
    XCTAssertNil([playlist removeTrackAtIndex:NSNotFound]);
    XCTAssertEqual(playlist.count, 2u);

    Playlist *empty = [Playlist new];
    empty.observer = observer;
    XCTAssertNil([empty removeTrackAtIndex:0]);
    XCTAssertEqual(empty.count, 0u);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testRemoveReturnsTheExactRowObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    AudioTrack *b = [playlist trackAtIndex:1];
    XCTAssertEqual([playlist removeTrackAtIndex:1], b);
    XCTAssertEqual(playlist.count, 2u);
    XCTAssertEqualObjects([playlist trackAtIndex:0].url, URLNamed(@"a.mp3"));
    XCTAssertEqualObjects([playlist trackAtIndex:1].url, URLNamed(@"c.mp3"));
    XCTAssertNil([playlist trackAtIndex:2]);
}

- (void)testRemovingFirstMiddleAndLastOrdinaryRows {
    for (NSNumber *boxed in @[@0u, @1u, @2u]) {
        NSUInteger index = boxed.unsignedIntegerValue;
        Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
        NSMutableArray<AudioTrack *> *expected = [playlist.tracks mutableCopy];
        [expected removeObjectAtIndex:index];
        [playlist removeTrackAtIndex:index];
        XCTAssertEqualObjects(playlist.tracks, expected, @"removing row %lu", (unsigned long)index);
    }
}

- (void)testRemovingBeforeCurrentKeepsTheSameCurrentObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist removeTrackAtIndex:0];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testRemovingAfterCurrentLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist removeTrackAtIndex:2];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testRemovingCurrentLandsOnTheSuccessorThatSlidIn {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    AudioTrack *successor = [playlist trackAtIndex:2];
    [playlist removeTrackAtIndex:1];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, successor);
}

- (void)testRemovingTheCurrentLastRowStepsBackOntoTheNewLastRow {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *previous = [playlist trackAtIndex:1];
    [playlist removeTrackAtIndex:2];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, previous);
    XCTAssertFalse(playlist.hasNextTrack);
}

- (void)testRemovingTheSoleRowEmptiesAndResetsTheCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    XCTAssertNotNil([playlist removeTrackAtIndex:0]);
    XCTAssertEqual(playlist.count, 0u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertNil(playlist.currentTrack);
    XCTAssertFalse(playlist.hasNextTrack);
    XCTAssertFalse(playlist.hasPreviousTrack);
}

// The one mutation that moves rows, so the one whose indexes must be rebuilt
// rather than patched: every survivor has to resolve to its shifted row.
- (void)testRemovalRebuildsTheIdentityMap {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    NSArray<AudioTrack *> *before = playlist.tracks;
    [playlist removeTrackAtIndex:1];
    XCTAssertEqual([playlist getIndexForTrack:before[1]], -1);
    XCTAssertEqual([playlist getIndexForTrack:before[0]], 0);
    XCTAssertEqual([playlist getIndexForTrack:before[2]], 1);
    XCTAssertEqual([playlist getIndexForTrack:before[3]], 2);
}

- (void)testRemovalDropsExactlyTheRemovedDuplicateOccurrence {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3"]);
    [playlist removeTrackAtIndex:0];

    NSIndexSet *rows = [playlist indexesOfTracksWithURL:URLNamed(@"a.mp3")];
    XCTAssertEqual(rows.count, 1u);
    XCTAssertTrue([rows containsIndex:1]);
    // The surviving occurrence is now the first one the URL lookup answers.
    XCTAssertEqual([playlist trackForURL:URLNamed(@"a.mp3")], [playlist trackAtIndex:1]);
    // b.mp3's own bucket followed the shift too.
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"b.mp3")],
                          [NSIndexSet indexSetWithIndex:0]);
}

- (void)testRemovingTheLastRowHoldingAURLDropsItFromLookupEntirely {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist removeTrackAtIndex:1];
    XCTAssertEqual([playlist indexesOfTracksWithURL:URLNamed(@"b.mp3")].count, 0u);
    XCTAssertNil([playlist trackForURL:URLNamed(@"b.mp3")]);
}

#pragma mark - Insert (the removal's inverse)

- (void)testInsertRefusesNilAndClampsPastTheEnd {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [playlist insertTrack:nil atIndex:0];
#pragma clang diagnostic pop
    XCTAssertEqual(playlist.count, 2u);
    XCTAssertEqual(observer.events.count, 0u);

    AudioTrack *track = [AudioTrack withURL:URLNamed(@"z.mp3")];
    [playlist insertTrack:track atIndex:99];
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual([playlist trackAtIndex:2], track);
}

- (void)testInsertBeforeCurrentKeepsTheSameCurrentObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist insertTrack:[AudioTrack withURL:URLNamed(@"z.mp3")] atIndex:0];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testInsertAtCurrentBumpsTheCursorToKeepItsObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist insertTrack:[AudioTrack withURL:URLNamed(@"z.mp3")] atIndex:1];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testInsertAfterCurrentLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist insertTrack:[AudioTrack withURL:URLNamed(@"z.mp3")] atIndex:1];
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"a.mp3"));
}

- (void)testInsertIntoEmptyLeavesTheCursorOnTheNewRow {
    Playlist *playlist = [Playlist new];
    AudioTrack *track = [AudioTrack withURL:URLNamed(@"a.mp3")];
    [playlist insertTrack:track atIndex:0];
    XCTAssertEqual(playlist.count, 1u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqual(playlist.currentTrack, track);
}

// Remove then insert at the same index must round-trip the rows, the identity
// map and the URL buckets — and the cursor object, when the removed row was
// not the current one.
- (void)testRemoveThenInsertRoundTripsRowsAndIndexes {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    NSArray<AudioTrack *> *original = playlist.tracks;
    AudioTrack *removed = [playlist removeTrackAtIndex:2];
    [playlist insertTrack:removed atIndex:2];
    XCTAssertEqualObjects(playlist.tracks, original);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"b.mp3"));
    for (NSUInteger i = 0; i < original.count; i++) {
        XCTAssertEqual([playlist getIndexForTrack:original[i]], (NSInteger)i);
    }
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"c.mp3")],
                          [NSIndexSet indexSetWithIndex:2]);
}

// The cursor deliberately does NOT round-trip when the removed row WAS
// current: the removal moved it to the successor, whose audio the shell
// started, and the cursor keeps naming what is sounding — the restore is a
// list edit, never a replay.
- (void)testReinsertingARemovedCurrentRowKeepsTheSuccessorCurrent {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    AudioTrack *successor = [playlist trackAtIndex:2];
    AudioTrack *removed = [playlist removeTrackAtIndex:1];
    [playlist insertTrack:removed atIndex:1];
    XCTAssertEqual(playlist.currentIndex, 2u);
    XCTAssertEqual(playlist.currentTrack, successor);
    XCTAssertEqual([playlist trackAtIndex:1], removed);
}

- (void)testInsertSendsExactlyOneEventCarryingTheFinalState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    [playlist insertTrack:[AudioTrack withURL:URLNamed(@"z.mp3")] atIndex:0];
    XCTAssertEqualObjects(observer.events, @[@"insert 0 cursor 2 count 3"]);
}

// The rebuild must reuse the row objects, not recreate them from their URLs:
// a fresh AudioTrack would drop installed metadata and fail every identity
// check the async deliveries make.
- (void)testSurvivingTracksKeepTheirIdentityAndState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    AudioTrack *survivor = [playlist trackAtIndex:1];
    survivor.duration = 321.5;
    survivor.detectedBPM = 174.0f;
    [playlist removeTrackAtIndex:0];
    XCTAssertEqual([playlist trackAtIndex:0], survivor);
    XCTAssertEqual(survivor.duration, 321.5);
    XCTAssertEqual(survivor.detectedBPM, 174.0f);
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

// One structural edit, one event: the cursor callback deliberately does not
// also fire, or a table would reconcile the same action twice.
- (void)testRemovalSendsExactlyOneEventCarryingTheFinalState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;

    [playlist removeTrackAtIndex:0];
    XCTAssertEqualObjects(observer.events, @[@"remove 0 cursor 0 count 2"]);

    // And again where the removed row IS the current one, at the end.
    [playlist next];
    [observer.events removeAllObjects];
    [playlist removeTrackAtIndex:1];
    XCTAssertEqualObjects(observer.events, @[@"remove 1 cursor 0 count 1"]);
}

- (void)testBoundaryRefusalsDoNotNotify {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    [playlist next];
    [playlist previous];
    [playlist appendURLs:@[]];
    [playlist removeTrackAtIndex:1];
    XCTAssertEqual(observer.events.count, 0u);
}

@end
