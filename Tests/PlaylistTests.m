//
// The Playlist model: ordering, the current-index cursor and its boundary
// predicates, URL lookup with duplicate rows, the replace-row rule — a fresh
// AudioTrack carrying the old row's duration and detected BPM — and the three
// structural edits that move rows (remove, insert, move) and so rebuild the
// two indexes rather than patching them.
//

#import <XCTest/XCTest.h>

#import "Playlist.h"

// A compact index-set spelling for event strings: "1" or "0,2". A one-index
// set prints as the bare number, so single-row expectations read unchanged.
static NSString *RowsString(NSIndexSet *indexes) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
    }];
    return [parts componentsJoinedByString:@","];
}

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

- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes {
    // The final state is recorded alongside the payload, because the model's
    // contract is that everything is coherent BEFORE the observer is called.
    [self.events addObject:[NSString stringWithFormat:@"remove %@ cursor %lu count %lu",
                            RowsString(indexes),
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes {
    [self.events addObject:[NSString stringWithFormat:@"insert %@ cursor %lu count %lu",
                            RowsString(indexes),
                            (unsigned long)playlist.currentIndex,
                            (unsigned long)playlist.count]];
}

- (void)playlist:(Playlist *)playlist
        didMoveTracksFromIndexes:(NSIndexSet *)sourceIndexes
                       toIndexes:(NSIndexSet *)destinationIndexes {
    [self.events addObject:[NSString stringWithFormat:@"move %@->%@ cursor %lu count %lu",
                            RowsString(sourceIndexes),
                            RowsString(destinationIndexes),
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

static NSIndexSet *RowSet(NSUInteger index) {
    return [NSIndexSet indexSetWithIndex:index];
}

static NSIndexSet *RowRange(NSUInteger location, NSUInteger length) {
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(location, length)];
}

static NSIndexSet *RowSetOf(NSArray<NSNumber *> *rows) {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    for (NSNumber *row in rows) {
        [indexes addIndex:row.unsignedIntegerValue];
    }
    return indexes;
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
    XCTAssertNil([playlist removeTracksAtIndexes:RowSet(2)]);
    XCTAssertEqual(playlist.count, 2u);

    Playlist *empty = [Playlist new];
    empty.observer = observer;
    XCTAssertNil([empty removeTracksAtIndexes:RowSet(0)]);
    XCTAssertEqual(empty.count, 0u);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testRemoveReturnsTheExactRowObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    AudioTrack *b = [playlist trackAtIndex:1];
    XCTAssertEqual([playlist removeTracksAtIndexes:RowSet(1)].firstObject, b);
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
        [playlist removeTracksAtIndexes:RowSet(index)];
        XCTAssertEqualObjects(playlist.tracks, expected, @"removing row %lu", (unsigned long)index);
    }
}

- (void)testRemovingBeforeCurrentKeepsTheSameCurrentObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist removeTracksAtIndexes:RowSet(0)];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testRemovingAfterCurrentLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist removeTracksAtIndexes:RowSet(2)];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testRemovingCurrentLandsOnTheSuccessorThatSlidIn {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    AudioTrack *successor = [playlist trackAtIndex:2];
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, successor);
}

- (void)testRemovingTheCurrentLastRowStepsBackOntoTheNewLastRow {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *previous = [playlist trackAtIndex:1];
    [playlist removeTracksAtIndexes:RowSet(2)];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, previous);
    XCTAssertFalse(playlist.hasNextTrack);
}

- (void)testRemovingTheSoleRowEmptiesAndResetsTheCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    XCTAssertNotNil([playlist removeTracksAtIndexes:RowSet(0)]);
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
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqual([playlist getIndexForTrack:before[1]], -1);
    XCTAssertEqual([playlist getIndexForTrack:before[0]], 0);
    XCTAssertEqual([playlist getIndexForTrack:before[2]], 1);
    XCTAssertEqual([playlist getIndexForTrack:before[3]], 2);
}

- (void)testRemovalDropsExactlyTheRemovedDuplicateOccurrence {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3"]);
    [playlist removeTracksAtIndexes:RowSet(0)];

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
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqual([playlist indexesOfTracksWithURL:URLNamed(@"b.mp3")].count, 0u);
    XCTAssertNil([playlist trackForURL:URLNamed(@"b.mp3")]);
}

#pragma mark - Insert (the removal's inverse)

- (void)testInsertRefusesEmptyAndMismatchedInputsAndClampsPastTheEnd {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    AudioTrack *track = [AudioTrack withURL:URLNamed(@"z.mp3")];
    // Nothing to insert, and a track list that does not pair one-to-one with
    // its index set, are both refused whole: no mutation, no event.
    [playlist insertTracks:@[] atIndexes:RowSet(0)];
    [playlist insertTracks:@[track] atIndexes:RowSetOf(@[@0u, @1u])];
    XCTAssertEqual(playlist.count, 2u);
    XCTAssertEqual(observer.events.count, 0u);

    [playlist insertTracks:@[track] atIndexes:RowSet(99)];
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual([playlist trackAtIndex:2], track);
}

- (void)testInsertBeforeCurrentKeepsTheSameCurrentObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist insertTracks:@[[AudioTrack withURL:URLNamed(@"z.mp3")]] atIndexes:RowSet(0)];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testInsertAtCurrentBumpsTheCursorToKeepItsObject {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist insertTracks:@[[AudioTrack withURL:URLNamed(@"z.mp3")]] atIndexes:RowSet(1)];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testInsertAfterCurrentLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist insertTracks:@[[AudioTrack withURL:URLNamed(@"z.mp3")]] atIndexes:RowSet(1)];
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"a.mp3"));
}

- (void)testInsertIntoEmptyLeavesTheCursorOnTheNewRow {
    Playlist *playlist = [Playlist new];
    AudioTrack *track = [AudioTrack withURL:URLNamed(@"a.mp3")];
    [playlist insertTracks:@[track] atIndexes:RowSet(0)];
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
    AudioTrack *removed = [playlist removeTracksAtIndexes:RowSet(2)].firstObject;
    [playlist insertTracks:@[removed] atIndexes:RowSet(2)];
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
    AudioTrack *removed = [playlist removeTracksAtIndexes:RowSet(1)].firstObject;
    [playlist insertTracks:@[removed] atIndexes:RowSet(1)];
    XCTAssertEqual(playlist.currentIndex, 2u);
    XCTAssertEqual(playlist.currentTrack, successor);
    XCTAssertEqual([playlist trackAtIndex:1], removed);
}

- (void)testInsertSendsExactlyOneEventCarryingTheFinalState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    [playlist insertTracks:@[[AudioTrack withURL:URLNamed(@"z.mp3")]] atIndexes:RowSet(0)];
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
    [playlist removeTracksAtIndexes:RowSet(0)];
    XCTAssertEqual([playlist trackAtIndex:0], survivor);
    XCTAssertEqual(survivor.duration, 321.5);
    XCTAssertEqual(survivor.detectedBPM, 174.0f);
}

#pragma mark - Batch remove

- (void)testRemovingNonContiguousRowsClosesEveryGap {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    NSArray<AudioTrack *> *before = playlist.tracks;
    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:RowSetOf(@[@0u, @2u])];
    // The exact objects, in ascending row order.
    XCTAssertEqual(removed.count, 2u);
    XCTAssertEqual(removed[0], before[0]);
    XCTAssertEqual(removed[1], before[2]);
    XCTAssertEqualObjects(playlist.tracks, (@[before[1], before[3]]));
    XCTAssertEqual([playlist getIndexForTrack:before[1]], 0);
    XCTAssertEqual([playlist getIndexForTrack:before[3]], 1);
    XCTAssertEqual([playlist getIndexForTrack:before[0]], -1);
    XCTAssertEqual([playlist getIndexForTrack:before[2]], -1);
}

- (void)testBatchRemovalRefusesAnyOutOfRangeMemberWhole {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertNil([playlist removeTracksAtIndexes:RowSetOf(@[@1u, @5u])]);
    XCTAssertNil([playlist removeTracksAtIndexes:[NSIndexSet indexSet]]);
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testRemovingRowsStraddlingCurrentSubtractsOnlyThoseAbove {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3", @"e.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    [playlist removeTracksAtIndexes:RowSetOf(@[@0u, @4u])];
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
}

- (void)testRemovingCurrentAmongOthersLandsOnTheSlidInSuccessor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    [playlist next];
    AudioTrack *survivor = [playlist trackAtIndex:3];
    // The current row and its immediate successor both go; the first survivor
    // after them slides into the current position.
    [playlist removeTracksAtIndexes:RowSetOf(@[@1u, @2u])];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, survivor);
}

- (void)testRemovingCurrentAndEverythingAfterStepsBackOntoTheNewLastRow {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *previous = [playlist trackAtIndex:1];
    [playlist removeTracksAtIndexes:RowSetOf(@[@2u, @3u])];
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqual(playlist.currentTrack, previous);
    XCTAssertFalse(playlist.hasNextTrack);
}

- (void)testRemovingEveryRowEmptiesAndResetsTheCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    NSArray<AudioTrack *> *removed =
            [playlist removeTracksAtIndexes:RowSetOf(@[@0u, @1u, @2u])];
    XCTAssertEqual(removed.count, 3u);
    XCTAssertEqual(playlist.count, 0u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertNil(playlist.currentTrack);
}

- (void)testBatchRemovalDropsExactlyTheRemovedDuplicateOccurrences {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3", @"b.mp3"]);
    [playlist removeTracksAtIndexes:RowSetOf(@[@0u, @1u])];
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"a.mp3")],
                          [NSIndexSet indexSetWithIndex:0]);
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"b.mp3")],
                          [NSIndexSet indexSetWithIndex:1]);
    XCTAssertEqual([playlist trackForURL:URLNamed(@"a.mp3")], [playlist trackAtIndex:0]);
}

#pragma mark - Batch insert

// The undo shape: removeTracksAtIndexes:'s returned array and index set,
// handed back, must restore rows, identity map and URL buckets exactly.
- (void)testBatchInsertRestoresANonContiguousRemoval {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    [playlist next];
    NSArray<AudioTrack *> *original = playlist.tracks;
    NSIndexSet *rows = RowSetOf(@[@0u, @2u]);
    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
    [playlist insertTracks:removed atIndexes:rows];
    XCTAssertEqualObjects(playlist.tracks, original);
    XCTAssertEqual(playlist.currentIndex, 1u);
    for (NSUInteger i = 0; i < original.count; i++) {
        XCTAssertEqual([playlist getIndexForTrack:original[i]], (NSInteger)i);
    }
}

#pragma mark - Move

- (void)testMoveRefusesInvalidInputs {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    NSArray<AudioTrack *> *original = playlist.tracks;
    XCTAssertFalse([playlist moveTracksAtIndexes:[NSIndexSet indexSet] toIndexes:[NSIndexSet indexSet]]);
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSet(3) toIndexes:RowSet(0)]);
    // Both sets are final positions in the same-count list, so a two-row block
    // whose range would run past the end is out of range, not clamped.
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @1u]) toIndexes:RowRange(2, 2)]);
    // The sets must pair one-to-one.
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @1u]) toIndexes:RowSet(0)]);
    XCTAssertEqualObjects(playlist.tracks, original);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testMoveTreatsABlockDroppedOnItsOwnPositionAsANoOp {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSet(1) toIndexes:RowSet(1)]);
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@1u, @2u]) toIndexes:RowRange(1, 2)]);
    // Every row selected: no destination changes anything.
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @1u, @2u, @3u]) toIndexes:RowRange(0, 4)]);
    XCTAssertEqual(observer.events.count, 0u);
    // A non-contiguous set landing on its own first row is NOT a no-op: the
    // survivor between its members has to move out from between them.
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @2u]) toIndexes:RowRange(0, 2)]);
}

- (void)testMovingSingleRowsInEveryDirection {
    // (source, destination) covering first-to-last, last-to-first and both
    // middle directions, each checked against a reference splice.
    for (NSArray<NSNumber *> *pair in @[@[@0u, @3u], @[@3u, @0u], @[@1u, @2u], @[@2u, @1u]]) {
        NSUInteger source = pair[0].unsignedIntegerValue;
        NSUInteger destination = pair[1].unsignedIntegerValue;
        Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
        NSMutableArray<AudioTrack *> *expected = [playlist.tracks mutableCopy];
        AudioTrack *moved = expected[source];
        [expected removeObjectAtIndex:source];
        [expected insertObject:moved atIndex:destination];
        XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(source) toIndexes:RowSet(destination)]);
        XCTAssertEqualObjects(playlist.tracks, expected,
                              @"moving %lu to %lu", (unsigned long)source, (unsigned long)destination);
    }
}

- (void)testMovingANonContiguousSetGathersItAtTheDestination {
    // Each case checked against the same reference: extract ascending, then
    // splice back contiguously at the destination.
    for (NSArray *testCase in @[@[@[@1u, @3u], @0u], @[@[@0u, @4u], @2u], @[@[@0u, @2u, @4u], @1u]]) {
        NSIndexSet *sources = RowSetOf(testCase[0]);
        NSUInteger destination = [testCase[1] unsignedIntegerValue];
        Playlist *playlist =
                PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3", @"e.mp3"]);
        NSMutableArray<AudioTrack *> *expected = [playlist.tracks mutableCopy];
        NSArray<AudioTrack *> *moved = [expected objectsAtIndexes:sources];
        [expected removeObjectsAtIndexes:sources];
        [expected insertObjects:moved
                      atIndexes:[NSIndexSet indexSetWithIndexesInRange:
                                 NSMakeRange(destination, moved.count)]];
        XCTAssertTrue([playlist moveTracksAtIndexes:sources toIndexes:RowRange(destination, sources.count)]);
        XCTAssertEqualObjects(playlist.tracks, expected,
                              @"moving %@ to %lu", RowsString(sources), (unsigned long)destination);
    }
}

- (void)testMovedTracksKeepTheirIdentityAndState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    AudioTrack *moved = [playlist trackAtIndex:0];
    moved.duration = 321.5;
    moved.detectedBPM = 174.0f;
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(2)];
    XCTAssertEqual([playlist trackAtIndex:2], moved);
    XCTAssertEqual(moved.duration, 321.5);
    XCTAssertEqual(moved.detectedBPM, 174.0f);
}

- (void)testMovingTheCurrentRowCarriesTheCursorWithIt {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(1) toIndexes:RowSet(3)]);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 3u);
}

- (void)testMovingRowsAcrossTheCurrentShiftsTheCursorEitherWay {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3", @"e.mp3"]);
    [playlist next];
    [playlist next];
    AudioTrack *current = playlist.currentTrack;
    // A row from above lands below: the cursor slides up.
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(4)]);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
    // And back across: the cursor slides down again.
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(4) toIndexes:RowSet(0)]);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 2u);
}

- (void)testMoveWhollyOnOneSideLeavesTheCursorAlone {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    AudioTrack *current = playlist.currentTrack;
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSetOf(@[@2u, @3u]) toIndexes:RowRange(1, 2)]);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 0u);
}

- (void)testMoveRebuildsTheIdentityMap {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3", @"e.mp3"]);
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSetOf(@[@1u, @3u]) toIndexes:RowRange(0, 2)]);
    NSArray<AudioTrack *> *after = playlist.tracks;
    for (NSUInteger i = 0; i < after.count; i++) {
        XCTAssertEqual([playlist getIndexForTrack:after[i]], (NSInteger)i);
    }
}

// The undo shape: hand the two sets back swapped and the move inverts itself,
// scattering the gathered block onto the original positions.
- (void)testMoveInvertsItselfWithTheSetsSwapped {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3", @"e.mp3"]);
    [playlist next];
    NSArray<AudioTrack *> *original = playlist.tracks;
    AudioTrack *current = playlist.currentTrack;
    NSIndexSet *sources = RowSetOf(@[@1u, @3u]);
    NSIndexSet *landed = RowRange(0, 2);
    XCTAssertTrue([playlist moveTracksAtIndexes:sources toIndexes:landed]);
    XCTAssertTrue([playlist moveTracksAtIndexes:landed toIndexes:sources]);
    XCTAssertEqualObjects(playlist.tracks, original);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
    for (NSUInteger i = 0; i < original.count; i++) {
        XCTAssertEqual([playlist getIndexForTrack:original[i]], (NSInteger)i);
    }
}

- (void)testMoveScattersAContiguousBlockOntoItsDestinations {
    // The general form directly: rows 0-1 land at {1, 3}, checked against the
    // remove-then-insert reference.
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    NSMutableArray<AudioTrack *> *expected = [playlist.tracks mutableCopy];
    NSIndexSet *sources = RowRange(0, 2);
    NSIndexSet *destinations = RowSetOf(@[@1u, @3u]);
    NSArray<AudioTrack *> *moved = [expected objectsAtIndexes:sources];
    [expected removeObjectsAtIndexes:sources];
    [expected insertObjects:moved atIndexes:destinations];
    XCTAssertTrue([playlist moveTracksAtIndexes:sources toIndexes:destinations]);
    XCTAssertEqualObjects(playlist.tracks, expected);
}

- (void)testMoveKeepsDuplicateURLBucketsCoherent {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"a.mp3"]);
    AudioTrack *secondOccurrence = [playlist trackAtIndex:2];
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(2) toIndexes:RowSet(0)]);
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"a.mp3")],
                          RowSetOf(@[@0u, @1u]));
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:URLNamed(@"b.mp3")],
                          [NSIndexSet indexSetWithIndex:2]);
    // trackForURL: answers the first occurrence in the NEW order.
    XCTAssertEqual([playlist trackForURL:URLNamed(@"a.mp3")], secondOccurrence);
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
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(1)];
    [playlist clear];

    NSArray *expected = @[@"index 0->1", @"index 1->0", @"append 2-3", @"replace 0",
                          @"move 0->1 cursor 1 count 4", @"replaceAll"];
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

    [playlist removeTracksAtIndexes:RowSet(0)];
    XCTAssertEqualObjects(observer.events, @[@"remove 0 cursor 0 count 2"]);

    // And again where the removed row IS the current one, at the end.
    [playlist next];
    [observer.events removeAllObjects];
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqualObjects(observer.events, @[@"remove 1 cursor 0 count 1"]);
}

- (void)testBatchEditsSendExactlyOneEventCarryingTheFinalState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3", @"d.mp3"]);
    [playlist next];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;

    [playlist moveTracksAtIndexes:RowSetOf(@[@1u, @3u]) toIndexes:RowRange(0, 2)];
    XCTAssertEqualObjects(observer.events, @[@"move 1,3->0,1 cursor 0 count 4"]);

    [observer.events removeAllObjects];
    [playlist removeTracksAtIndexes:RowSetOf(@[@0u, @2u])];
    XCTAssertEqualObjects(observer.events, @[@"remove 0,2 cursor 0 count 2"]);
}

- (void)testBoundaryRefusalsDoNotNotify {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    [playlist next];
    [playlist previous];
    [playlist appendURLs:@[]];
    [playlist removeTracksAtIndexes:RowSet(1)];
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(0)];
    XCTAssertEqual(observer.events.count, 0u);
}

@end
