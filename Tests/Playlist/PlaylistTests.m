#import <XCTest/XCTest.h>

#import "Playlist.h"
#import "PlaylistTestSupport.h"

@interface PlaylistTests : XCTestCase
@end

@implementation PlaylistTests

#pragma mark - Ordering

- (void)testCapturedTracksResolveByIdentityAfterMoveRemovalAndReplacement {
    Playlist *playlist = PlaylistWithFiles(@[@"same.mp3", @"b.mp3", @"same.mp3", @"d.mp3"]);
    NSArray *captured = @[[playlist trackAtIndex:0], [playlist trackAtIndex:2], [playlist trackAtIndex:2]];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSetOf(@[@0, @2]));
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(3)];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSetOf(@[@1, @3]));
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSet(2));
    [playlist replaceTrackAtIndex:2 withTrack:[TestRow withURL:URLNamed(@"same.mp3")]];
    XCTAssertEqual([playlist indexesOfTracks:captured].count, 0u);
    XCTAssertEqual([playlist indexesOfTracks:@[]].count, 0u);
}

- (void)testSameURLsInAReplacementDoNotReviveCapturedTargets {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    NSArray *captured = playlist.tracks;
    [playlist replaceAllWithTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3")]) startingAtIndex:NSNotFound];
    XCTAssertEqual([playlist indexesOfTracks:captured].count, 0u);
    XCTAssertEqualObjects([playlist indexesOfTracks:playlist.tracks], RowRange(0, 2));
}

// Every subset at every cursor. All rows share one URL, so only object
// identity can pass.
- (void)testRemovalForwardLandingAgreesWithEveryActualRemoval {
    for (NSUInteger cursor = 0; cursor < 5; cursor++) {
        for (NSUInteger mask = 1; mask < 32; mask++) {
            Playlist *playlist = PlaylistWithFiles(@[@"same.mp3", @"same.mp3", @"same.mp3", @"same.mp3", @"same.mp3"]);
            playlist.currentIndex = cursor;
            NSArray *before = playlist.tracks;
            NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
            TestRow *expectedForward = nil;
            for (NSUInteger i = 0; i < before.count; i++) {
                if (mask & (1u << i)) {
                    [rows addIndex:i];
                } else if (i > cursor && !expectedForward) {
                    expectedForward = before[i];
                }
            }
            if (!(mask & (1u << cursor))) expectedForward = nil;
            TestRow *forward = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows];
            XCTAssertEqual(forward, expectedForward, @"cursor %lu mask %lu", cursor, mask);
            [playlist removeTracksAtIndexes:rows];
            if (forward) {
                XCTAssertEqual(playlist.currentTrack, forward);
            } else if (!(mask & (1u << cursor))) {
                XCTAssertEqual(playlist.currentTrack, before[cursor]);
            } else if (playlist.count) {
                XCTAssertLessThan([before indexOfObjectIdenticalTo:playlist.currentTrack], cursor);
            } else {
                XCTAssertNil(playlist.currentTrack);
            }
        }
    }
}

- (void)testInvalidRemovalHasNoForwardLanding {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:RowSetOf(@[@0, @2])]);
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:RowSet(NSNotFound - 1)]);
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:[NSIndexSet indexSet]]);
    [playlist clear];
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:RowSet(0)]);
}

- (void)testGaplessAdoptionAdvancesExactlyOnceAndNotifiesWithFinalCursor {
    Playlist *playlist = PlaylistWithFiles(@[@"same.mp3", @"same.mp3", @"c.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    TestRow *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
    XCTAssertTrue([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, started);
    XCTAssertEqualObjects(observer.events, (@[@"index 0->1"]));
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, started);
    XCTAssertEqual(observer.events.count, 1u);
}

- (void)testGaplessAdoptionRefusesAReplacedSuccessorWithTheSameURL {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    TestRow *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
    [playlist replaceTrackAtIndex:1 withTrack:[TestRow withURL:started.url]];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, finished);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testGaplessAdoptionRefusesChangedCursorReorderedSuccessorAndEmptyList {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    TestRow *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
    playlist.currentIndex = 2;
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentIndex, 2u);
    playlist.currentIndex = 0;
    [playlist moveTracksAtIndexes:RowSet(1) toIndexes:RowSet(2)];
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, finished);
    [playlist clear];
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.count, 0u);
}

- (void)testStructureGenerationSurvivesEditsButRetiresBeforeReplacementNotification {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    NSUInteger generation = playlist.structureGeneration;
    [playlist next];
    [playlist appendTracks:Rows(@[URLNamed(@"d.mp3")])];
    [playlist replaceTrackAtIndex:3 withTrack:[TestRow withURL:URLNamed(@"e.mp3")]];
    NSArray *removed = [playlist removeTracksAtIndexes:RowSet(0)];
    [playlist insertTracks:removed atIndexes:RowSet(0)];
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(2)];
    [playlist moveTracksAtIndexes:RowSet(2) toIndexes:RowSet(0)];
    XCTAssertEqual(playlist.structureGeneration, generation);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    NSArray *urls = [playlist.tracks valueForKey:@"url"];
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    XCTAssertGreaterThan(playlist.structureGeneration, generation);
    XCTAssertEqual(observer.lastReplacementGeneration, playlist.structureGeneration);
    generation = playlist.structureGeneration;
    [playlist clear];
    XCTAssertGreaterThan(playlist.structureGeneration, generation);
    XCTAssertEqual(observer.lastReplacementGeneration, playlist.structureGeneration);
}

- (void)testReplaceAllOrdersTracksAndResetsCursor {
    Playlist<TestRow *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects([playlist trackAtIndex:0].url, URLNamed(@"a.mp3"));
    XCTAssertEqualObjects([playlist trackAtIndex:1].url, URLNamed(@"b.mp3"));
    XCTAssertEqualObjects([playlist trackAtIndex:2].url, URLNamed(@"c.mp3"));
    XCTAssertNil([playlist trackAtIndex:3]);
}

- (void)testAppendExtendsWithoutTouchingCursor {
    Playlist<TestRow *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    XCTAssertEqual(playlist.currentIndex, 1u);
    [playlist appendTracks:Rows(@[URLNamed(@"c.mp3")])];
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqualObjects([playlist trackAtIndex:2].url, URLNamed(@"c.mp3"));
}

- (void)testAppendToEmptyPlaylist {
    Playlist<TestRow *> *playlist = NewPlaylist();
    [playlist appendTracks:Rows(@[URLNamed(@"a.mp3")])];
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
    NSArray<TestRow *> *snapshot = playlist.tracks;
    [playlist appendTracks:Rows(@[URLNamed(@"b.mp3")])];
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
    Playlist *empty = NewPlaylist();
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
    TestRow *found = [playlist trackForURL:URLNamed(@"a.mp3")];
    XCTAssertEqual(found, [playlist trackAtIndex:0]);
    XCTAssertNil([playlist trackForURL:URLNamed(@"missing.mp3")]);
}

- (void)testGetIndexForTrackIsAnIdentityLookup {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"a.mp3"]);
    XCTAssertEqual([playlist getIndexForTrack:[playlist trackAtIndex:0]], 0);
    XCTAssertEqual([playlist getIndexForTrack:[playlist trackAtIndex:1]], 1);
    // A different row object for the same file is a different row.
    XCTAssertEqual([playlist getIndexForTrack:[TestRow withURL:URLNamed(@"a.mp3")]], -1);
    XCTAssertEqual([playlist getIndexForTrack:nil], -1);
}

- (void)testStampingReachesEveryRowSoundingTheWindowAndNoOtherRowOfTheFile {
    Playlist *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:@[CueRowOf(@"mix.flac", 0, 4500), CueRowOf(@"mix.flac", 4500, 0),
                                     [TestRow withURL:URLNamed(@"mix.flac")], CueRowOf(@"mix.flac", 0, 4500)]
                   startingAtIndex:NSNotFound];
    NSMutableIndexSet *stamped = [NSMutableIndexSet indexSet];
    BOOL current = [playlist stampTracksSounding:CueRowOf(@"mix.flac", 0, 4500) usingBlock:^(TestRow *track) {
        [stamped addIndex:(NSUInteger)[playlist getIndexForTrack:track]];
    }];
    XCTAssertEqualObjects(RowsString(stamped), RowsString(RowSetOf(@[@0, @3])));
    XCTAssertTrue(current);

    [stamped removeAllIndexes];
    current = [playlist stampTracksSounding:[TestRow withURL:URLNamed(@"mix.flac")] usingBlock:^(TestRow *track) {
        [stamped addIndex:(NSUInteger)[playlist getIndexForTrack:track]];
    }];
    XCTAssertEqualObjects(RowsString(stamped), RowsString(RowSet(2)));
    XCTAssertFalse(current);
}

- (void)testIsCurrentTrackComparesIdentity {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    XCTAssertTrue([playlist isCurrentTrack:[playlist trackAtIndex:0]]);
    XCTAssertFalse([playlist isCurrentTrack:[playlist trackAtIndex:1]]);
}

#pragma mark - Replace

- (void)testReplaceRefusesOutOfRange {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    XCTAssertFalse([playlist replaceTrackAtIndex:1 withTrack:[TestRow withURL:URLNamed(@"b.mp3")]]);
    XCTAssertEqual(playlist.count, 1u);
}

// An entry already in the list would sit in two rows, and the track-to-row map
// can name only one of them.
- (void)testReplaceRefusesAnEntryAlreadyInTheList {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    TestRow *first = [playlist trackAtIndex:0], *second = [playlist trackAtIndex:1];
    XCTAssertFalse([playlist replaceTrackAtIndex:1 withTrack:first]);
    XCTAssertFalse([playlist replaceTrackAtIndex:1 withTrack:second]);
    XCTAssertEqual([playlist trackAtIndex:1], second);
    XCTAssertEqual([playlist getIndexForTrack:first], 0);
    XCTAssertEqual(observer.events.count, 0u);

    // Every row of a file given one replacement: the first row takes it, and
    // the second keeps its entry.
    NSURL *output = URLNamed(@"same.flac");
    Playlist *duplicates = PlaylistWithFiles(@[@"same.mp3", @"same.mp3"]);
    TestRow *kept = [duplicates trackAtIndex:1];
    TestRow *shared = [TestRow withURL:output];
    NSIndexSet *rows = [duplicates replaceTracksMatchingTrack:kept usingBlock:^TestRow *(TestRow *outgoing) {
        return shared;
    }];
    XCTAssertEqualObjects(RowsString(rows), @"0");
    XCTAssertEqual([duplicates trackAtIndex:0], shared);
    XCTAssertEqual([duplicates trackAtIndex:1], kept);
}

- (void)testAPlaylistMadeWithoutKeysHasNoLookupByFile {
    Playlist *playlist = [[Playlist alloc] init];
    TestRow *track = [TestRow withURL:URLNamed(@"a.mp3")];
    [playlist replaceAllWithTracks:@[track] startingAtIndex:NSNotFound];
    XCTAssertEqual([playlist indexesOfTracksWithURL:track.url].count, 0u);
    XCTAssertNil([playlist trackForURL:track.url]);
    __block NSUInteger stamped = 0;
    XCTAssertFalse([playlist stampTracksSounding:track usingBlock:^(id row) {
        stamped += 1;
    }]);
    XCTAssertEqual(stamped, 0u);
    XCTAssertEqual([playlist replaceTracksMatchingTrack:track usingBlock:ReplacementAt(URLNamed(@"a.flac"))].count, 0u);
    XCTAssertEqual([playlist getIndexForTrack:track], 0);
}

- (void)testReplaceLeavesTheCursorAlone {
    Playlist<TestRow *> *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    [playlist next];
    [playlist replaceTrackAtIndex:1 withTrack:[TestRow withURL:URLNamed(@"b.flac")]];
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
    [playlist appendTracks:Rows(@[URLNamed(@"c.mp3"), URLNamed(@"d.mp3")])];
    [playlist replaceTrackAtIndex:0 withTrack:[TestRow withURL:URLNamed(@"a.flac")]];
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(1)];
    [playlist clear];

    NSArray *expected = @[@"index 0->1", @"index 1->0", @"append 2-3", @"replace 0",
                          @"move 0->1 cursor 1 count 4", @"replaceAll"];
    XCTAssertEqualObjects(observer.events, expected);
}

- (void)testSettingTheSameCurrentIndexStillNotifies {
    // A double-click on the playing row must re-render it.
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    playlist.currentIndex = 0;
    XCTAssertEqualObjects(observer.events, @[@"index 0->0"]);
}

// The cursor callback must not also fire, or a table would reconcile the
// same edit twice.
- (void)testRemovalSendsExactlyOneEventCarryingTheFinalState {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    [playlist next];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;

    [playlist removeTracksAtIndexes:RowSet(0)];
    XCTAssertEqualObjects(observer.events, @[@"remove 0 cursor 0 count 2"]);

    // The removed row is the current one.
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
    [playlist appendTracks:Rows(@[])];
    [playlist removeTracksAtIndexes:RowSet(1)];
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(0)];
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testConversionReplacesAllDuplicateURLsWithFreshRowsAndPreservesCursor {
    NSURL *source = [NSURL fileURLWithPath:@"/tests/source.wav"];
    NSURL *output = [NSURL fileURLWithPath:@"/tests/source.flac"];
    NSURL *other = [NSURL fileURLWithPath:@"/tests/other.wav"];
    Playlist<TestRow *> *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(@[source, other, source]) startingAtIndex:NSNotFound];
    playlist.currentIndex = 2;
    NSArray *before = playlist.tracks;
    RecordingObserver *observer = RecordingObserver.new;
    playlist.observer = observer;
    NSIndexSet *rows = [playlist replaceTracksMatchingTrack:before[0] usingBlock:ReplacementAt(output)];
    XCTAssertEqualObjects(RowsString(rows), @"0,2");
    XCTAssertEqual(playlist.currentIndex, 2u);
    XCTAssertEqualObjects(playlist.currentTrack.url, output);
    XCTAssertNotEqual([playlist trackAtIndex:0], before[0]);
    XCTAssertNotEqual([playlist trackAtIndex:2], before[2]);
    XCTAssertEqual([playlist trackAtIndex:1], before[1]);
    XCTAssertEqual([playlist indexesOfTracksWithURL:source].count, 0u);
    XCTAssertEqualObjects([playlist indexesOfTracksWithURL:output], rows);
    XCTAssertEqualObjects(observer.events, (@[@"replace 0", @"replace 2"]));
}

- (void)testConversionCompletionReplacesSourceRowsAfterPlaylistReplacement {
    NSURL *source = [NSURL fileURLWithPath:@"/tests/source.wav"];
    NSURL *output = [NSURL fileURLWithPath:@"/tests/output.flac"];
    Playlist *playlist = NewPlaylist();
    [playlist replaceAllWithTracks:Rows(@[source]) startingAtIndex:NSNotFound];
    TestRow *departed = playlist.currentTrack;
    [playlist replaceAllWithTracks:Rows(@[source, source]) startingAtIndex:NSNotFound];
    XCTAssertEqualObjects([playlist replaceTracksMatchingTrack:departed usingBlock:ReplacementAt(output)], RowSetOf(@[@0, @1]));
    XCTAssertEqual([playlist indexesOfTracksWithURL:source].count, 0u);
    XCTAssertEqual([playlist indexesOfTracksWithURL:output].count, 2u);
}

- (void)testConversionCompletionReplacesSurvivingDuplicateAfterOriginalRowRemoval {
    Playlist<TestRow *> *playlist = PlaylistWithFiles(@[@"source.wav", @"other.wav", @"source.wav"]);
    TestRow *departed = playlist.currentTrack;
    [playlist removeTracksAtIndexes:RowSet(0)];
    TestRow *other = playlist.currentTrack;
    NSURL *output = [NSURL fileURLWithPath:@"/tests/output.flac"];
    XCTAssertEqualObjects([playlist replaceTracksMatchingTrack:departed usingBlock:ReplacementAt(output)], RowSet(1));
    XCTAssertEqual(playlist.currentTrack, other);
    XCTAssertEqualObjects([playlist trackAtIndex:1].url, output);
    // Once all source rows have left, a late completion changes nothing.
    XCTAssertEqual([playlist replaceTracksMatchingTrack:departed usingBlock:ReplacementAt(output)].count, 0u);
}

@end
