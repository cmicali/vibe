
#import <XCTest/XCTest.h>

#import "Playlist.h"
#import "PlaylistTestSupport.h"

@interface PlaylistEditTests : XCTestCase
@end

@implementation PlaylistEditTests

#pragma mark - Remove

// Seeded edits over rows that share files: after each, both indexes answer
// what a scan of the rows does.
- (void)testIndexesStayExactThroughRandomRemovesInsertsAndMoves {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < 40; i++) {
        [urls addObject:URLNamed([NSString stringWithFormat:@"%lu.mp3", (unsigned long)(i % 13)])];
    }
    Playlist *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    NSMutableArray<AudioTrack *> *departed = [NSMutableArray array];
    __block uint32_t state = 7;
    uint32_t (^next)(uint32_t) = ^uint32_t(uint32_t bound) {
        state = state * 1664525u + 1013904223u;
        return bound ? (state >> 8) % bound : 0;
    };
    for (int step = 0; step < 400; step++) {
        NSUInteger count = playlist.count;
        uint32_t kind = next(3);
        if (kind == 0 && count > 1) {
            NSUInteger at = next((uint32_t)count);
            NSIndexSet *rows = RowRange(at, MIN(1 + next(3), count - at));
            [departed addObjectsFromArray:[playlist removeTracksAtIndexes:rows]];
        } else if (kind == 1 && departed.count > 0) {
            AudioTrack *back = departed.lastObject;
            [departed removeLastObject];
            [playlist insertTracks:@[back] atIndexes:RowSet(next((uint32_t)count + 3))];
        } else if (count > 1) {
            NSUInteger moving = 1 + next((uint32_t)MIN(count, 5));
            NSMutableIndexSet *from = [NSMutableIndexSet indexSet];
            NSMutableIndexSet *to = [NSMutableIndexSet indexSet];
            while (from.count < moving) [from addIndex:next((uint32_t)count)];
            while (to.count < moving) [to addIndex:next((uint32_t)count)];
            [playlist moveTracksAtIndexes:from toIndexes:to];
        }
        NSMutableDictionary<NSURL *, NSMutableIndexSet *> *expected = [NSMutableDictionary dictionary];
        for (NSUInteger row = 0; row < playlist.count; row++) {
            AudioTrack *track = [playlist trackAtIndex:row];
            XCTAssertEqual([playlist getIndexForTrack:track], (NSInteger)row, @"step %d", step);
            NSMutableIndexSet *rows = expected[track.url] ?: [NSMutableIndexSet indexSet];
            [rows addIndex:row];
            expected[track.url] = rows;
        }
        for (NSURL *url in [NSSet setWithArray:urls]) {
            XCTAssertEqualObjects([playlist indexesOfTracksWithURL:url],
                                  expected[url] ?: [NSIndexSet indexSet], @"step %d", step);
        }
        for (AudioTrack *gone in departed) {
            XCTAssertEqual([playlist getIndexForTrack:gone], -1, @"step %d", step);
        }
    }
}

- (void)testRemoveRefusesOutOfRangeAndAnEmptyPlaylist {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertNil([playlist removeTracksAtIndexes:RowSet(2)]);
    XCTAssertEqual(playlist.count, 2u);

    Playlist *empty = NewPlaylist();
    empty.observer = observer;
    XCTAssertNil([empty removeTracksAtIndexes:RowSet(0)]);
    XCTAssertEqual(empty.count, 0u);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testRemoveReturnsTheExactRowObject {
    Playlist<AudioTrack *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
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
    XCTAssertEqual([playlist trackForURL:URLNamed(@"a.mp3")], [playlist trackAtIndex:1]);
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
    // Refused whole: no mutation, no event.
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
    Playlist<AudioTrack *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist insertTracks:@[[AudioTrack withURL:URLNamed(@"z.mp3")]] atIndexes:RowSet(1)];
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects(playlist.currentTrack.url, URLNamed(@"a.mp3"));
}

- (void)testInsertIntoEmptyLeavesTheCursorOnTheNewRow {
    Playlist *playlist = NewPlaylist();
    AudioTrack *track = [AudioTrack withURL:URLNamed(@"a.mp3")];
    [playlist insertTracks:@[track] atIndexes:RowSet(0)];
    XCTAssertEqual(playlist.count, 1u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqual(playlist.currentTrack, track);
}

- (void)testRemoveThenInsertRoundTripsRowsAndIndexes {
    Playlist<AudioTrack *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
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

// The cursor keeps naming the successor the shell started playing: a
// restore is a list edit, never a replay.
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

// A fresh AudioTrack would drop installed metadata and fail every identity
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

// The undo shape: removeTracksAtIndexes:'s array and index set, handed back.
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
    // Both sets are final positions, so a block running past the end is
    // refused, not clamped.
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @1u]) toIndexes:RowRange(2, 2)]);
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
    XCTAssertFalse([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @1u, @2u, @3u]) toIndexes:RowRange(0, 4)]);
    XCTAssertEqual(observer.events.count, 0u);
    // Not a no-op: the survivor between the members must move out.
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSetOf(@[@0u, @2u]) toIndexes:RowRange(0, 2)]);
}

- (void)testMovingSingleRowsInEveryDirection {
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
    XCTAssertTrue([playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(4)]);
    XCTAssertEqual(playlist.currentTrack, current);
    XCTAssertEqual(playlist.currentIndex, 1u);
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

// The undo shape: the two sets handed back swapped.
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

@end
