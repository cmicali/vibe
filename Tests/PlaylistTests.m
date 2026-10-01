#import <XCTest/XCTest.h>

#import "Playlist.h"

// "1" or "0,2".
static NSString *RowsString(NSIndexSet *indexes) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [parts addObject:[NSString stringWithFormat:@"%lu", (unsigned long)index]];
    }];
    return [parts componentsJoinedByString:@","];
}

@interface RecordingObserver : NSObject <PlaylistObserver>
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic) NSUInteger lastReplacementGeneration;
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
    self.lastReplacementGeneration = playlist.structureGeneration;
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
    // Records the final state: the model is coherent BEFORE the observer is called.
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

static NSArray<AudioTrack *> *Rows(NSArray<NSURL *> *urls) {
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        [rows addObject:[AudioTrack withURL:url]];
    }
    return rows;
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

static AudioTrack *CueRowOf(NSString *filename, NSUInteger start, NSUInteger end) {
    return [[AudioTrack alloc] initWithURL:URLNamed(filename) cueStart:start cueEnd:end
                                     title:@"Row" performer:nil sheet:URLNamed(@"album.cue")
                               trackNumber:1];
}

static Playlist *PlaylistWithFiles(NSArray<NSString *> *filenames) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in filenames) {
        [urls addObject:URLNamed(name)];
    }
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
    return playlist;
}

#pragma mark - Ordering

- (void)testCapturedTracksResolveByIdentityAfterMoveRemovalAndReplacement {
    Playlist *playlist = PlaylistWithFiles(@[@"same.mp3", @"b.mp3", @"same.mp3", @"d.mp3"]);
    NSArray *captured = @[[playlist trackAtIndex:0], [playlist trackAtIndex:2], [playlist trackAtIndex:2]];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSetOf(@[@0, @2]));
    [playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(3)];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSetOf(@[@1, @3]));
    [playlist removeTracksAtIndexes:RowSet(1)];
    XCTAssertEqualObjects([playlist indexesOfTracks:captured], RowSet(2));
    [playlist replaceTrackAtIndex:2 withURL:URLNamed(@"same.mp3")];
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
            AudioTrack *expectedForward = nil;
            for (NSUInteger i = 0; i < before.count; i++) {
                if (mask & (1u << i)) {
                    [rows addIndex:i];
                } else if (i > cursor && !expectedForward) {
                    expectedForward = before[i];
                }
            }
            if (!(mask & (1u << cursor))) expectedForward = nil;
            AudioTrack *forward = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows];
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
    AudioTrack *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
    XCTAssertTrue([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, started);
    XCTAssertEqualObjects(observer.events, (@[@"index 0->1"]));
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, started);
    XCTAssertEqual(observer.events.count, 1u);
}

- (void)testGaplessAdoptionRefusesAReplacedSuccessorWithTheSameURL {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    AudioTrack *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
    [playlist replaceTrackAtIndex:1 withURL:started.url];
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    XCTAssertFalse([playlist advanceFromTrack:finished toTrack:started]);
    XCTAssertEqual(playlist.currentTrack, finished);
    XCTAssertEqual(observer.events.count, 0u);
}

- (void)testGaplessAdoptionRefusesChangedCursorReorderedSuccessorAndEmptyList {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3", @"c.mp3"]);
    AudioTrack *finished = playlist.currentTrack, *started = [playlist trackAtIndex:1];
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
    [playlist replaceTrackAtIndex:3 withURL:URLNamed(@"e.mp3")];
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
    [playlist appendTracks:Rows(@[URLNamed(@"c.mp3")])];
    XCTAssertEqual(playlist.count, 3u);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertEqualObjects([playlist trackAtIndex:2].url, URLNamed(@"c.mp3"));
}

- (void)testAppendToEmptyPlaylist {
    Playlist *playlist = [Playlist new];
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
    NSArray<AudioTrack *> *snapshot = playlist.tracks;
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

// A tempo belongs to what was analyzed: every row sounding the same window —
// a duplicate included — and no other row of the file.
- (void)testStampingReachesEveryRowSoundingTheWindowAndNoOtherRowOfTheFile {
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithTracks:@[CueRowOf(@"mix.flac", 0, 4500), CueRowOf(@"mix.flac", 4500, 0),
                                     [AudioTrack withURL:URLNamed(@"mix.flac")], CueRowOf(@"mix.flac", 0, 4500)]
                   startingAtIndex:NSNotFound];
    NSMutableIndexSet *stamped = [NSMutableIndexSet indexSet];
    BOOL current = [playlist stampTracksSounding:CueRowOf(@"mix.flac", 0, 4500) usingBlock:^(AudioTrack *track) {
        [stamped addIndex:(NSUInteger)[playlist getIndexForTrack:track]];
    }];
    XCTAssertEqualObjects(RowsString(stamped), RowsString(RowSetOf(@[@0, @3])));
    XCTAssertTrue(current);

    [stamped removeAllIndexes];
    current = [playlist stampTracksSounding:[AudioTrack withURL:URLNamed(@"mix.flac")] usingBlock:^(AudioTrack *track) {
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

- (void)testReplaceMintsAFreshTrackAndCarriesDurationBPMAndKey {
    Playlist *playlist = PlaylistWithFiles(@[@"a.wav", @"b.mp3"]);
    AudioTrack *outgoing = [playlist trackAtIndex:0];
    outgoing.duration = 123.5;
    outgoing.detectedBPM = 128.0f;
    outgoing.detectedKey = 18; // F#m

    AudioTrack *incoming = [playlist replaceTrackAtIndex:0 withURL:URLNamed(@"a.flac")];
    XCTAssertNotNil(incoming);
    XCTAssertNotEqual(incoming, outgoing);
    XCTAssertEqualObjects(incoming.url, URLNamed(@"a.flac"));
    XCTAssertEqual(incoming.duration, 123.5);
    XCTAssertEqual(incoming.detectedBPM, 128.0f);
    XCTAssertEqual(incoming.detectedKey, 18);
    XCTAssertEqual([playlist trackAtIndex:0], incoming);

    XCTAssertEqual([playlist getIndexForTrack:incoming], 0);
    XCTAssertEqual([playlist getIndexForTrack:outgoing], -1);
}

// Converting a sheet's image moves each row to the new file with its window
// and names, so the rows still sound what they did.
- (void)testReplaceCarriesACueRowsWindowAndNames {
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithTracks:@[CueRowOf(@"mix.wav", 4500, 9000)] startingAtIndex:NSNotFound];
    AudioTrack *incoming = [playlist replaceTrackAtIndex:0 withURL:URLNamed(@"mix.flac")];
    XCTAssertEqual(incoming.cueStart, 4500u);
    XCTAssertEqual(incoming.cueEnd, 9000u);
    XCTAssertEqualObjects(incoming.cueTitle, @"Row");
    XCTAssertEqualObjects(incoming.cueSheetURL, URLNamed(@"album.cue"));
    XCTAssertEqual(incoming.cueTrackNumber, 1);
    XCTAssertEqualObjects(incoming.url, URLNamed(@"mix.flac"));
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

// Seeded edits over rows that share files: after each, both indexes answer
// what a scan of the rows does.
- (void)testIndexesStayExactThroughRandomRemovesInsertsAndMoves {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < 40; i++) {
        [urls addObject:URLNamed([NSString stringWithFormat:@"%lu.mp3", (unsigned long)(i % 13)])];
    }
    Playlist *playlist = [[Playlist alloc] init];
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
            NSUInteger from = next((uint32_t)count);
            NSUInteger to = next((uint32_t)count);
            [playlist moveTracksAtIndexes:RowSet(from) toIndexes:RowSet(to)];
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

#pragma mark - Observer

- (void)testMutationsNotifyTheObserverWithTheAffectedRows {
    Playlist *playlist = PlaylistWithFiles(@[@"a.mp3", @"b.mp3"]);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;

    [playlist next];
    [playlist previous];
    [playlist appendTracks:Rows(@[URLNamed(@"c.mp3"), URLNamed(@"d.mp3")])];
    [playlist replaceTrackAtIndex:0 withURL:URLNamed(@"a.flac")];
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
    Playlist *playlist = Playlist.new;
    [playlist replaceAllWithTracks:Rows(@[source, other, source]) startingAtIndex:NSNotFound];
    playlist.currentIndex = 2;
    NSArray *before = playlist.tracks;
    RecordingObserver *observer = RecordingObserver.new;
    playlist.observer = observer;
    NSIndexSet *rows = [playlist replaceTracksMatchingTrack:before[0] withURL:output];
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
    Playlist *playlist = Playlist.new;
    [playlist replaceAllWithTracks:Rows(@[source]) startingAtIndex:NSNotFound];
    AudioTrack *departed = playlist.currentTrack;
    [playlist replaceAllWithTracks:Rows(@[source, source]) startingAtIndex:NSNotFound];
    XCTAssertEqualObjects([playlist replaceTracksMatchingTrack:departed withURL:output], RowSetOf(@[@0, @1]));
    XCTAssertEqual([playlist indexesOfTracksWithURL:source].count, 0u);
    XCTAssertEqual([playlist indexesOfTracksWithURL:output].count, 2u);
}

- (void)testConversionCompletionReplacesSurvivingDuplicateAfterOriginalRowRemoval {
    Playlist *playlist = PlaylistWithFiles(@[@"source.wav", @"other.wav", @"source.wav"]);
    AudioTrack *departed = playlist.currentTrack;
    [playlist removeTracksAtIndexes:RowSet(0)];
    AudioTrack *other = playlist.currentTrack;
    NSURL *output = [NSURL fileURLWithPath:@"/tests/output.flac"];
    XCTAssertEqualObjects([playlist replaceTracksMatchingTrack:departed withURL:output], RowSet(1));
    XCTAssertEqual(playlist.currentTrack, other);
    XCTAssertEqualObjects([playlist trackAtIndex:1].url, output);
    // Once all source rows have left, a late completion changes nothing.
    XCTAssertEqual([playlist replaceTracksMatchingTrack:departed withURL:output].count, 0u);
}

#pragma mark - Repeat

static Playlist *NumberedPlaylist(NSUInteger count) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [names addObject:[NSString stringWithFormat:@"%02lu.mp3", (unsigned long)i]];
    }
    return PlaylistWithFiles(names);
}

- (void)testRepeatModesAnswerNextAndTrackEndAtTheLastRow {
    Playlist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 2;
    AudioTrack *last = playlist.currentTrack;

    XCTAssertNil(playlist.nextTrack);
    XCTAssertNil(playlist.trackEndSuccessor);
    XCTAssertFalse(playlist.hasNextTrack);

    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertEqual(playlist.nextTrack, [playlist trackAtIndex:0]);
    XCTAssertEqual(playlist.trackEndSuccessor, [playlist trackAtIndex:0]);
    XCTAssertTrue(playlist.hasNextTrack);

    // One changes only the track end: Next behaves as under Off.
    playlist.repeatMode = VibeRepeatModeOne;
    XCTAssertNil(playlist.nextTrack);
    XCTAssertFalse(playlist.hasNextTrack);
    XCTAssertEqual(playlist.trackEndSuccessor, last);
}

- (void)testPreviousNeverWraps {
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        Playlist *playlist = NumberedPlaylist(3);
        playlist.repeatMode = mode.integerValue;
        XCTAssertFalse(playlist.hasPreviousTrack);
        XCTAssertFalse([playlist previous]);
        XCTAssertEqual(playlist.currentIndex, 0u);
    }
}

- (void)testAdvanceAtTrackEndParksWrapsOrReplays {
    Playlist *playlist = NumberedPlaylist(2);
    RecordingObserver *observer = [RecordingObserver new];
    playlist.observer = observer;
    playlist.currentIndex = 1;
    [observer.events removeAllObjects];

    XCTAssertFalse([playlist advanceAtTrackEnd]);
    XCTAssertEqual(observer.events.count, 0u);

    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertTrue([playlist advanceAtTrackEnd]);
    XCTAssertEqual(playlist.currentIndex, 0u);

    // One stays on the row and still notifies, as a replay of a row does.
    playlist.repeatMode = VibeRepeatModeOne;
    [observer.events removeAllObjects];
    XCTAssertTrue([playlist advanceAtTrackEnd]);
    XCTAssertEqual(playlist.currentIndex, 0u);
    XCTAssertEqualObjects(observer.events, @[@"index 0->0"]);

    // Next under One walks on, and parks at the end.
    XCTAssertTrue([playlist next]);
    XCTAssertEqual(playlist.currentIndex, 1u);
    XCTAssertFalse([playlist next]);
}

- (void)testGaplessAdoptionFollowsTheTrackEndSuccessor {
    Playlist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 2;
    AudioTrack *last = playlist.currentTrack;
    AudioTrack *first = [playlist trackAtIndex:0];

    XCTAssertFalse([playlist advanceFromTrack:last toTrack:first]);
    playlist.repeatMode = VibeRepeatModeAll;
    XCTAssertTrue([playlist advanceFromTrack:last toTrack:first]);
    XCTAssertEqual(playlist.currentTrack, first);

    // Under One the splice is into the track itself, never its neighbor.
    playlist.repeatMode = VibeRepeatModeOne;
    XCTAssertFalse([playlist advanceFromTrack:first toTrack:[playlist trackAtIndex:1]]);
    XCTAssertTrue([playlist advanceFromTrack:first toTrack:first]);
    XCTAssertEqual(playlist.currentTrack, first);
}

- (void)testRepeatOnEmptyAndSingleRowPlaylists {
    Playlist *empty = [Playlist new];
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        empty.repeatMode = mode.integerValue;
        XCTAssertNil(empty.nextTrack);
        XCTAssertNil(empty.trackEndSuccessor);
        XCTAssertFalse([empty advanceAtTrackEnd]);
    }
    Playlist *single = NumberedPlaylist(1);
    AudioTrack *only = single.currentTrack;
    single.repeatMode = VibeRepeatModeAll;
    XCTAssertEqual(single.nextTrack, only);
    XCTAssertTrue([single next]);
    XCTAssertEqual(single.currentTrack, only);
}

// A removal is not a track end: the landing never wraps.
- (void)testRemovingThePlayingLastRowUnderRepeatAllParksBackward {
    Playlist *playlist = NumberedPlaylist(3);
    playlist.repeatMode = VibeRepeatModeAll;
    playlist.currentIndex = 2;
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:RowSet(2)]);
    [playlist removeTracksAtIndexes:RowSet(2)];
    XCTAssertEqual(playlist.currentIndex, 1u);
}

#pragma mark - Shuffle

// A deterministic stream for the order: a 64-bit LCG, high bits out.
static uint32_t (^SeededRandom(uint64_t seed))(uint32_t) {
    __block uint64_t state = seed * 2654435761u + 1;
    return ^uint32_t(uint32_t upperBound) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        return (uint32_t)((state >> 33) % upperBound);
    };
}

static Playlist *ShuffledPlaylist(NSUInteger count, uint64_t seed) {
    Playlist *playlist = NumberedPlaylist(count);
    playlist.randomBelow = SeededRandom(seed);
    playlist.shuffleEnabled = YES;
    return playlist;
}

// The current track, then every track next lands on, up to limit.
static NSArray<AudioTrack *> *WalkNext(Playlist *playlist, NSUInteger limit) {
    NSMutableArray<AudioTrack *> *walk = [NSMutableArray arrayWithObject:playlist.currentTrack];
    while (walk.count < limit) {
        AudioTrack *peek = playlist.nextTrack;
        if (![playlist next]) {
            XCTAssertNil(peek);
            break;
        }
        // The peek is where next lands: the gapless splice arms on it.
        XCTAssertEqual(playlist.currentTrack, peek);
        [walk addObject:playlist.currentTrack];
    }
    return walk;
}

static void AssertPermutation(Playlist *playlist, NSArray<AudioTrack *> *walk) {
    XCTAssertEqual(walk.count, playlist.count);
    XCTAssertEqual([NSSet setWithArray:walk].count, playlist.count);
    XCTAssertTrue([[NSSet setWithArray:walk] isEqualToSet:[NSSet setWithArray:playlist.tracks]]);
}

- (void)testShuffleVisitsEveryRowOnceFromTheCurrentOneThenParks {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = NumberedPlaylist(12);
        playlist.randomBelow = SeededRandom(seed);
        playlist.currentIndex = 5;
        AudioTrack *playing = playlist.currentTrack;
        playlist.shuffleEnabled = YES;
        XCTAssertEqual(playlist.currentTrack, playing);
        XCTAssertFalse(playlist.hasPreviousTrack);
        NSArray<AudioTrack *> *walk = WalkNext(playlist, 100);
        AssertPermutation(playlist, walk);
        XCTAssertEqual(walk.firstObject, playing);
        XCTAssertFalse(playlist.hasNextTrack);
        XCTAssertNil(playlist.trackEndSuccessor);
    }
}

- (void)testShuffleLeavesTheRowsInTheirOrder {
    Playlist *playlist = NumberedPlaylist(8);
    NSArray<AudioTrack *> *rows = playlist.tracks;
    playlist.randomBelow = SeededRandom(3);
    playlist.shuffleEnabled = YES;
    WalkNext(playlist, 4);
    XCTAssertEqualObjects(playlist.tracks, rows);
}

- (void)testRepeatAllReshufflesEachCycleWithoutRepeatingAcrossTheSeam {
    for (NSUInteger count = 1; count <= 6; count++) {
        for (uint64_t seed = 1; seed <= 40; seed++) {
            Playlist *playlist = ShuffledPlaylist(count, seed);
            playlist.repeatMode = VibeRepeatModeAll;
            NSArray<AudioTrack *> *walk = WalkNext(playlist, count * 4);
            XCTAssertEqual(walk.count, count * 4);
            for (NSUInteger cycle = 0; cycle < 4; cycle++) {
                AssertPermutation(playlist, [walk subarrayWithRange:NSMakeRange(cycle * count, count)]);
            }
            for (NSUInteger i = 1; count > 1 && i < walk.count; i++) {
                XCTAssertNotEqual(walk[i], walk[i - 1], @"back-to-back at %lu, %lu rows, seed %llu",
                                  (unsigned long)i, (unsigned long)count, seed);
            }
        }
    }
}

- (void)testTheNextCycleIsKeptOnceAsked {
    Playlist *playlist = ShuffledPlaylist(5, 7);
    playlist.repeatMode = VibeRepeatModeAll;
    WalkNext(playlist, 5);
    AudioTrack *peek = playlist.nextTrack;
    XCTAssertEqual(playlist.nextTrack, peek);
    XCTAssertEqual(playlist.trackEndSuccessor, peek);
    XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:peek]);
    XCTAssertEqual(playlist.currentTrack, peek);
}

- (void)testShufflePreviousRetracesThePlayedOrder {
    Playlist *playlist = ShuffledPlaylist(6, 11);
    NSArray<AudioTrack *> *walk = WalkNext(playlist, 4);
    for (NSInteger i = (NSInteger)walk.count - 2; i >= 0; i--) {
        XCTAssertTrue([playlist previous]);
        XCTAssertEqual(playlist.currentTrack, walk[(NSUInteger)i]);
    }
    XCTAssertFalse([playlist previous]);
    // Forward again retraces the same order.
    XCTAssertEqualObjects(WalkNext(playlist, 4), walk);
}

- (void)testPickingAnUnplayedRowContinuesWithoutRepeats {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(10, seed);
        NSMutableArray<AudioTrack *> *heard = [WalkNext(playlist, 3) mutableCopy];
        NSUInteger unplayed = 0;
        while ([heard containsObject:[playlist trackAtIndex:unplayed]]) {
            unplayed++;
        }
        playlist.currentIndex = unplayed;
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testPickingAPlayedRowReplaysItAndStillPlaysTheRest {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(10, seed);
        NSArray<AudioTrack *> *played = WalkNext(playlist, 4);
        playlist.currentIndex = (NSUInteger)[playlist getIndexForTrack:played[1]];
        NSArray<AudioTrack *> *rest = WalkNext(playlist, 100);
        XCTAssertEqual(rest.firstObject, played[1]);
        NSMutableSet<AudioTrack *> *heard = [NSMutableSet setWithArray:played];
        [heard addObjectsFromArray:rest];
        XCTAssertEqual(heard.count, playlist.count);
        // Only the replayed row is heard twice.
        XCTAssertEqual(played.count + rest.count, playlist.count + 1);
        // The history keeps the replay, not the slot it left.
        XCTAssertTrue([playlist previous]);
        XCTAssertNotEqual(playlist.currentTrack, played[1]);
    }
}

- (void)testAnOpenUnderShuffleStartsOnTheOrdersFirstRowAndMarksNothingPlayed {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = NumberedPlaylist(0);
        playlist.randomBelow = SeededRandom(seed);
        playlist.shuffleEnabled = YES;
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        for (NSUInteger i = 0; i < 9; i++) {
            [urls addObject:URLNamed([NSString stringWithFormat:@"%lu.mp3", (unsigned long)i])];
        }
        [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:NSNotFound];
        XCTAssertFalse(playlist.hasPreviousTrack);
        AssertPermutation(playlist, WalkNext(playlist, 100));

        [playlist replaceAllWithTracks:Rows(urls) startingAtIndex:4];
        XCTAssertEqual(playlist.currentIndex, 4u);
        XCTAssertFalse(playlist.hasPreviousTrack);
        AssertPermutation(playlist, WalkNext(playlist, 100));
    }
}

- (void)testAnOpenWithShuffleOffLandsOnTheGivenRowOrTheFirst {
    Playlist *playlist = [Playlist new];
    [playlist replaceAllWithTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3")]) startingAtIndex:1];
    XCTAssertEqual(playlist.currentIndex, 1u);
    [playlist replaceAllWithTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3")]) startingAtIndex:7];
    XCTAssertEqual(playlist.currentIndex, 0u);
}

- (void)testAppendedRowsJoinTheUnplayedPart {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(6, seed);
        NSMutableArray<AudioTrack *> *heard = [WalkNext(playlist, 3) mutableCopy];
        [playlist appendTracks:Rows(@[URLNamed(@"x.mp3"), URLNamed(@"y.mp3"), URLNamed(@"z.mp3")])];
        [heard removeLastObject];
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testRemovingThePlayingRowLandsOnTheNextUnplayedOne {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(8, seed);
        NSMutableArray<AudioTrack *> *heard = [WalkNext(playlist, 3) mutableCopy];
        NSIndexSet *rows = RowSet(playlist.currentIndex);
        AudioTrack *forward = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows];
        AudioTrack *peek = playlist.nextTrack;
        XCTAssertEqual(forward, peek);
        [playlist removeTracksAtIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, forward);
        [heard removeLastObject];
        [heard addObjectsFromArray:WalkNext(playlist, 100)];
        AssertPermutation(playlist, heard);
    }
}

- (void)testRemovingThePlayingLastEntryLandsOnTheLastPlayed {
    Playlist *playlist = ShuffledPlaylist(4, 5);
    NSArray<AudioTrack *> *walk = WalkNext(playlist, 100);
    NSIndexSet *rows = RowSet(playlist.currentIndex);
    XCTAssertNil([playlist forwardTrackAfterRemovingTracksAtIndexes:rows]);
    [playlist removeTracksAtIndexes:rows];
    XCTAssertEqual(playlist.currentTrack, walk[2]);
    XCTAssertFalse(playlist.hasNextTrack);
}

- (void)testRemovingOtherRowsAndUndoingKeepsEveryRowPlayingOnce {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(9, seed);
        NSMutableArray<AudioTrack *> *heard = [WalkNext(playlist, 4) mutableCopy];
        AudioTrack *playing = playlist.currentTrack;
        NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
        for (NSUInteger row = 0; row < playlist.count; row++) {
            if (row % 3 == 0 && row != playlist.currentIndex) {
                [rows addIndex:row];
            }
        }
        NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, playing);
        [playlist insertTracks:removed atIndexes:rows];
        XCTAssertEqual(playlist.currentTrack, playing);
        // A restored row plays again only if it had not been heard.
        [heard removeLastObject];
        NSArray<AudioTrack *> *rest = WalkNext(playlist, 100);
        NSMutableSet<AudioTrack *> *all = [NSMutableSet setWithArray:heard];
        [all addObjectsFromArray:rest];
        XCTAssertEqual(all.count, playlist.count);
        for (AudioTrack *track in rest) {
            XCTAssertFalse([heard containsObject:track] && ![removed containsObject:track]);
        }
    }
}

- (void)testAMoveLeavesThePlayOrderAlone {
    Playlist *a = ShuffledPlaylist(7, 9);
    Playlist *b = ShuffledPlaylist(7, 9);
    WalkNext(a, 2);
    WalkNext(b, 2);
    XCTAssertTrue([a moveTracksAtIndexes:RowRange(0, 2) toIndexes:RowRange(5, 2)]);
    NSArray<AudioTrack *> *moved = WalkNext(a, 100);
    NSArray<AudioTrack *> *unmoved = WalkNext(b, 100);
    XCTAssertEqual(moved.count, unmoved.count);
    for (NSUInteger i = 0; i < moved.count; i++) {
        XCTAssertEqualObjects(moved[i].url, unmoved[i].url);
    }
}

- (void)testTheConvertSwapKeepsTheRowsPlaceInTheOrder {
    Playlist *playlist = ShuffledPlaylist(6, 4);
    WalkNext(playlist, 2);
    AudioTrack *next = playlist.nextTrack;
    NSUInteger row = (NSUInteger)[playlist getIndexForTrack:next];
    AudioTrack *incoming = [playlist replaceTrackAtIndex:row withURL:URLNamed(@"converted.flac")];
    XCTAssertEqual(playlist.nextTrack, incoming);
    NSArray<AudioTrack *> *rest = WalkNext(playlist, 100);
    XCTAssertEqual(rest.count, 5u);
    XCTAssertTrue([rest containsObject:incoming]);
}

// At a cycle's last entry under Repeat All the gapless splice is armed on the
// next cycle's first; a convert swap anywhere must not reshuffle that cycle out
// from under it, and swapping the armed row itself hands its slot on.
- (void)testTheConvertSwapKeepsTheNextCycleTheSpliceArmedOn {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(6, seed);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 6);
        AudioTrack *armed = playlist.trackEndSuccessor;
        NSUInteger other = 0;
        while ([playlist trackAtIndex:other] == armed || other == playlist.currentIndex) {
            other++;
        }
        AudioTrack *converted = [playlist replaceTrackAtIndex:other withURL:URLNamed(@"other.flac")];
        XCTAssertEqual(playlist.trackEndSuccessor, armed, @"seed %llu", seed);

        AudioTrack *incoming = [playlist replaceTrackAtIndex:(NSUInteger)[playlist getIndexForTrack:armed]
                                                     withURL:URLNamed(@"armed.flac")];
        XCTAssertEqual(playlist.trackEndSuccessor, incoming, @"seed %llu", seed);
        XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:incoming], @"seed %llu", seed);
        NSArray<AudioTrack *> *cycle = WalkNext(playlist, 6);
        AssertPermutation(playlist, cycle);
        XCTAssertTrue([cycle containsObject:converted], @"seed %llu", seed);
    }
}

// Shuffle off holds no order, so nothing keeps a row of a past one alive.
- (void)testShuffleOffKeepsNoRowOfThePastOrders {
    Playlist *playlist = nil;
    __weak AudioTrack *departed = nil;
    @autoreleasepool {
        playlist = ShuffledPlaylist(4, 3);
        playlist.repeatMode = VibeRepeatModeAll;
        WalkNext(playlist, 4);
        departed = playlist.nextTrack;
        XCTAssertNotNil(departed);
        playlist.shuffleEnabled = NO;
        [playlist replaceAllWithTracks:Rows(@[URLNamed(@"new.mp3")]) startingAtIndex:0];
    }
    XCTAssertNil(departed);
    XCTAssertEqual(playlist.count, 1u);
}

- (void)testShuffleOffResumesTheRowOrderFromTheCurrentRow {
    Playlist *playlist = ShuffledPlaylist(8, 2);
    WalkNext(playlist, 3);
    NSUInteger row = playlist.currentIndex;
    playlist.shuffleEnabled = NO;
    XCTAssertEqual(playlist.currentIndex, row);
    XCTAssertEqual(playlist.nextTrack, [playlist trackAtIndex:row + 1]);
    XCTAssertEqual(playlist.hasPreviousTrack, row > 0);
}

- (void)testEnablingShuffleAgainKeepsTheOrder {
    Playlist *playlist = ShuffledPlaylist(8, 6);
    AudioTrack *next = playlist.nextTrack;
    playlist.shuffleEnabled = YES;
    XCTAssertEqual(playlist.nextTrack, next);
}

- (void)testShuffledGaplessAdoptionRefusesTheRowNeighbor {
    for (uint64_t seed = 1; seed <= 20; seed++) {
        Playlist *playlist = ShuffledPlaylist(6, seed);
        AudioTrack *current = playlist.currentTrack;
        AudioTrack *next = playlist.nextTrack;
        AudioTrack *neighbor = [playlist trackAtIndex:(playlist.currentIndex + 1) % 6];
        if (neighbor != next) {
            XCTAssertFalse([playlist advanceFromTrack:current toTrack:neighbor]);
        }
        XCTAssertTrue([playlist advanceFromTrack:current toTrack:next]);
        XCTAssertEqual(playlist.currentTrack, next);
    }
}

- (void)testAClearUnderShuffleStartsTheNextOpenFresh {
    Playlist *playlist = ShuffledPlaylist(5, 8);
    WalkNext(playlist, 3);
    [playlist clear];
    XCTAssertNil(playlist.nextTrack);
    [playlist appendTracks:Rows(@[URLNamed(@"a.mp3"), URLNamed(@"b.mp3"), URLNamed(@"c.mp3")])];
    XCTAssertEqual(playlist.currentIndex, 0u);
    AssertPermutation(playlist, WalkNext(playlist, 100));
}

@end
