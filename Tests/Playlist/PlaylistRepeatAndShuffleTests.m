
#import <XCTest/XCTest.h>

#import "Playlist.h"
#import "PlaylistTestSupport.h"

@interface PlaylistRepeatAndShuffleTests : XCTestCase
@end

@implementation PlaylistRepeatAndShuffleTests

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

- (void)testPauseAtTrackEndOutranksEveryMode {
    Playlist *playlist = NumberedPlaylist(3);
    playlist.currentIndex = 0;
    AudioTrack *first = playlist.currentTrack, *second = [playlist trackAtIndex:1];
    XCTAssertEqual(playlist.trackEndSuccessor, second);
    for (NSNumber *mode in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        playlist.repeatMode = mode.integerValue;
        playlist.pauseAtTrackEnd = YES;
        XCTAssertNil(playlist.trackEndSuccessor);
        XCTAssertFalse([playlist advanceAtTrackEnd]);
        XCTAssertFalse([playlist advanceFromTrack:first toTrack:second]);
        XCTAssertFalse([playlist advanceFromTrack:first toTrack:first]);
        XCTAssertEqual(playlist.currentIndex, 0u);
        playlist.pauseAtTrackEnd = NO;
        XCTAssertNotNil(playlist.trackEndSuccessor);
    }
    playlist.repeatMode = VibeRepeatModeOff;
    playlist.pauseAtTrackEnd = YES;
    XCTAssertTrue([playlist next]);
    XCTAssertEqual(playlist.currentTrack, second);
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
    Playlist *empty = NewPlaylist();
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
    Playlist *playlist = NewPlaylist();
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
    AudioTrack *incoming = [next replacementAtURL:URLNamed(@"converted.flac")];
    XCTAssertTrue([playlist replaceTrackAtIndex:row withTrack:incoming]);
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
        AudioTrack *converted = [AudioTrack withURL:URLNamed(@"other.flac")];
        [playlist replaceTrackAtIndex:other withTrack:converted];
        XCTAssertEqual(playlist.trackEndSuccessor, armed, @"seed %llu", seed);

        AudioTrack *incoming = [armed replacementAtURL:URLNamed(@"armed.flac")];
        [playlist replaceTrackAtIndex:(NSUInteger)[playlist getIndexForTrack:armed] withTrack:incoming];
        XCTAssertEqual(playlist.trackEndSuccessor, incoming, @"seed %llu", seed);
        XCTAssertTrue([playlist advanceFromTrack:playlist.currentTrack toTrack:incoming], @"seed %llu", seed);
        NSArray<AudioTrack *> *cycle = WalkNext(playlist, 6);
        AssertPermutation(playlist, cycle);
        XCTAssertTrue([cycle containsObject:converted], @"seed %llu", seed);
    }
}

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
