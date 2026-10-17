//
//  MainPlayerControllerTests.m
//
//  The shell's own guarantees, run through the real controller and its real
//  PlaylistController. Only the player, the metadata scan, the deferral's timer
//  and the window's occlusion are replaced (ShellTestFakes.h). AppKit groups
//  undo by event, so each user gesture here runs in an explicit undo group.
//

#import <XCTest/XCTest.h>

#import "ShellTestFakes.h"
#import "DrawnViewTestSupport.h"
#import "PlaylistTestSupport.h"
#import "AppSettings.h"
#import "MainPlayerController+NowPlaying.h"
#import "MainPlayerController+Playlist.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "MenuValidationRules.h"
#import "NowPlayingController.h"
#import "PlaylistController.h"
#import "VibeStrings.h"

@interface MainPlayerControllerTests : XCTestCase
@end

@implementation MainPlayerControllerTests {
    VibeShellTestPlayer *_player;
    VibeShellTestMetadataCache *_cache;
    NSMutableArray<dispatch_block_t> *_timers;
    MainPlayerController *_controller;
    NSUndoManager *_undo;
    BOOL _savedShuffle;
    VibeRepeatMode _savedRepeat;
    BOOL _savedPause;
}

- (void)setUp {
    [super setUp];
    AppSettings *settings = AppSettings.sharedInstance;
    _savedShuffle = settings.shuffleEnabled;
    _savedRepeat = settings.repeatMode;
    _savedPause = settings.pauseAtTrackEnd;
    settings.shuffleEnabled = NO;
    settings.repeatMode = VibeRepeatModeOff;
    settings.pauseAtTrackEnd = NO;
    MainPlayerController.testWindowVisible = YES;

    _player = [VibeShellTestPlayer new];
    _cache = [VibeShellTestMetadataCache new];
    _timers = [NSMutableArray array];
    NSMutableArray<dispatch_block_t> *timers = _timers;
    _controller = [[MainPlayerController alloc] initWithWindow:VibeOffscreenWindow(NSMakeSize(100, 100))
                                                   audioPlayer:(AudioPlayer *)_player
                                                 metadataCache:(AudioTrackMetadataCache *)_cache
                                             metadataScheduler:^(NSTimeInterval delay, dispatch_block_t block) {
        [timers addObject:block];
    }];
    [_controller buildPlaylistController];
    [_controller pushTransportModesToPlaylist];
    _undo = _controller.window.undoManager;
    _undo.groupsByEvent = NO;
}

- (void)tearDown {
    AppSettings *settings = AppSettings.sharedInstance;
    settings.shuffleEnabled = _savedShuffle;
    settings.repeatMode = _savedRepeat;
    settings.pauseAtTrackEnd = _savedPause;
    MainPlayerController.testWindowVisible = YES;
    [super tearDown];
}

#pragma mark - Helpers

- (PlaylistController *)playlist {
    return _controller.playlistController;
}

// An open of `names` landing on `row` in `state`, with the logs cleared.
- (NSArray<AudioTrack *> *)load:(NSString *)names row:(NSUInteger)row state:(VibeShellTestPlayerState)state {
    NSArray<AudioTrack *> *tracks = TracksNamed(names);
    [_controller loadTracks:tracks selectingIndex:row startPaused:state != VibeShellTestPlayerStatePlaying];
    _player.state = state;
    [_player.calls removeAllObjects];
    [_cache.calls removeAllObjects];
    return tracks;
}

- (void)gesture:(dispatch_block_t)block {
    [_undo beginUndoGrouping];
    block();
    [_undo endUndoGrouping];
}

- (void)assertParkedTheSuccessor:(NSString *)context {
    XCTAssertEqual(_player.parkedTrack, self.playlist.trackEndSuccessor, @"%@", context);
}

#pragma mark - The removal funnel

// Five rows, c current. Each case names the rows removed, the transport calls
// the funnel makes, and the row left current.
- (void)testRemovalDecidesTransportByWhetherTheCurrentRowLeft {
    NSArray *cases = @[
        // A surviving current row keeps its audio. Only the successor is re-parked.
        @[@"0",     @(VibeShellTestPlayerStatePlaying), @[@"prefetch d"], @"c"],
        @[@"4",     @(VibeShellTestPlayerStatePlaying), @[@"prefetch d"], @"c"],
        @[@"1,3",   @(VibeShellTestPlayerStatePlaying), @[@"prefetch e"], @"c"],
        @[@"1,3",   @(VibeShellTestPlayerStatePaused),  @[@"prefetch e"], @"c"],
        // A Stopped player prefetches nothing.
        @[@"1,3",   @(VibeShellTestPlayerStateStopped), @[],              @"c"],
        // A removed current row is replaced through the play funnel: sounding
        // only when it was playing and a forward row survives.
        @[@"2",     @(VibeShellTestPlayerStatePlaying), @[@"play d"],     @"d"],
        @[@"1,2,3", @(VibeShellTestPlayerStatePlaying), @[@"play e"],     @"e"],
        @[@"2",     @(VibeShellTestPlayerStatePaused),  @[@"park d"],     @"d"],
        @[@"2",     @(VibeShellTestPlayerStateStopped), @[@"park d"],     @"d"],
        // No forward row: the cursor moves back and never replays backward.
        @[@"2,3,4", @(VibeShellTestPlayerStatePlaying), @[@"park b"],     @"b"],
    ];
    for (NSArray *testCase in cases) {
        NSIndexSet *rows = RowSetOf([[testCase[0] componentsSeparatedByString:@","]
                                     valueForKey:@"integerValue"]);
        NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:2
                                             state:(VibeShellTestPlayerState)[testCase[1] integerValue]];
        NSUInteger generation = self.playlist.structureGeneration;
        NSArray<AudioTrack *> *removed = [_controller removePlaylistRows:rows];

        NSString *context = [NSString stringWithFormat:@"remove %@ while %@", testCase[0], testCase[1]];
        XCTAssertEqualObjects(removed, [tracks objectsAtIndexes:rows], @"%@", context);
        NSMutableArray<AudioTrack *> *left = [tracks mutableCopy];
        [left removeObjectsAtIndexes:rows];
        XCTAssertEqualObjects(self.playlist.playlist, left, @"%@", context);
        XCTAssertEqualObjects(_player.calls, testCase[2], @"%@", context);
        XCTAssertEqualObjects(NamesOf(@[self.playlist.currentTrack]), testCase[3], @"%@", context);
        XCTAssertEqual(self.playlist.structureGeneration, generation, @"%@: an edit, not a replacement", context);
        NSMutableArray<NSString *> *abandoned = [NSMutableArray array];
        for (AudioTrack *track in removed) {
            [abandoned addObject:[@"abandon " stringByAppendingString:NamesOf(@[track])]];
        }
        XCTAssertEqualObjects(_cache.calls, abandoned, @"%@", context);
        XCTAssertEqualObjects(_cache.neighborhood, self.playlist.neighborhoodTracks, @"%@", context);
    }
}

- (void)testASurvivingCurrentRowKeepsItsObject {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:2 state:VibeShellTestPlayerStatePlaying];
    [_controller removePlaylistRows:RowSetOf(@[@0, @1])];
    XCTAssertEqual(self.playlist.currentTrack, tracks[2]);
    XCTAssertEqual(self.playlist.currentIndex, 0u);
}

// TRAP: emptied as an edit, never a clear, so older undo registrations live.
- (void)testRemovingEveryRowInTheFunnelUnloadsAndKeepsTheGeneration {
    [self load:@"a b c" row:1 state:VibeShellTestPlayerStatePlaying];
    NSUInteger generation = self.playlist.structureGeneration;
    [_controller removePlaylistRows:RowRange(0, 3)];
    XCTAssertEqual(self.playlist.count, 0u);
    XCTAssertEqual(self.playlist.structureGeneration, generation);
    XCTAssertEqualObjects(_player.calls, @[@"stop"]);
    XCTAssertTrue([_cache.calls containsObject:@"cancel"]);
    for (dispatch_block_t timer in _timers) {
        timer();
    }
    XCTAssertFalse([_cache.calls containsObject:@"load 3"], @"the unload cancels the deferred sweep");
}

// Outside a group, a registration would raise: groupsByEvent is off.
- (void)testTheFunnelRegistersNoUndoOfItsOwn {
    [self load:@"a b c" row:1 state:VibeShellTestPlayerStatePlaying];
    XCTAssertNoThrow([_controller removePlaylistRows:RowSet(0)]);
    XCTAssertFalse(_undo.canUndo);
}

- (void)testRemoveRegistersItsUndoAndUndoRestoresTheExactRowsWithoutPlaying {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:2 state:VibeShellTestPlayerStatePlaying];
    [self gesture:^{
        [self->_controller removePlaylistTracks:@[tracks[1], tracks[3]]];
    }];
    XCTAssertEqualObjects(_undo.undoActionName, STR_MENU_EDIT_REMOVE_FROM_PLAYLIST);
    [_player.calls removeAllObjects];
    [_cache.calls removeAllObjects];

    [_undo undo];
    XCTAssertEqualObjects(self.playlist.playlist, tracks);
    XCTAssertEqual(self.playlist.currentTrack, tracks[2]);
    XCTAssertEqualObjects(_player.calls, @[@"prefetch d"]);
    [self assertParkedTheSuccessor:@"after undo"];
    NSArray *expected = @[@"now b", @"now d"];
    XCTAssertEqualObjects(_cache.calls, expected, @"undo asks again for the abandoned scan work");

    [_undo redo];
    XCTAssertEqualObjects(NamesOf(self.playlist.playlist), @"a c e");
    XCTAssertTrue(_undo.canUndo, @"redo registers the undo again");
}

- (void)testUndoOfARemovedCurrentRowRestoresTheRowAndNeverReplaysIt {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:2 state:VibeShellTestPlayerStatePlaying];
    [self gesture:^{
        [self->_controller removePlaylistTracks:@[tracks[2]]];
    }];
    XCTAssertEqualObjects(_player.calls, @[@"play d"]);
    [_player.calls removeAllObjects];

    [_undo undo];
    XCTAssertEqualObjects(self.playlist.playlist, tracks);
    XCTAssertEqual(self.playlist.currentTrack, tracks[3]);
    XCTAssertEqualObjects(_player.calls, @[@"prefetch e"]);
}

- (void)testUndoAfterAReplacementRestoresNothing {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    [self gesture:^{
        [self->_controller removePlaylistTracks:@[tracks[2]]];
    }];
    NSArray<AudioTrack *> *replacement = [self load:@"x y" row:0 state:VibeShellTestPlayerStatePlaying];
    [_undo undo];
    XCTAssertEqualObjects(self.playlist.playlist, replacement);
    XCTAssertEqualObjects(_player.calls, @[]);
}

- (void)testRemovingEveryRowIsCloseAndCannotBeUndone {
    NSArray<AudioTrack *> *tracks = [self load:@"a b" row:0 state:VibeShellTestPlayerStatePlaying];
    NSUInteger generation = self.playlist.structureGeneration;
    XCTAssertNoThrow([_controller removePlaylistTracks:tracks]);
    XCTAssertEqual(self.playlist.count, 0u);
    XCTAssertNotEqual(self.playlist.structureGeneration, generation, @"Close clears");
    XCTAssertEqualObjects(_player.calls, @[@"stop"]);
    XCTAssertFalse(_undo.canUndo);
}

- (void)testAHeldPlaylistRefusesRemoval {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    self.playlist.structureEditsHeld = YES;
    XCTAssertNoThrow([_controller removePlaylistTracks:@[tracks[1]]]);
    XCTAssertEqualObjects(self.playlist.playlist, tracks);
    XCTAssertFalse(_undo.canUndo);
}

- (void)testTheRowMenuEntersTheSameFunnel {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c" row:1 state:VibeShellTestPlayerStatePlaying];
    [self gesture:^{
        self.playlist.removeTracksRequestHandler(@[tracks[1]], NO);
    }];
    XCTAssertEqualObjects(NamesOf(self.playlist.playlist), @"a c");
    XCTAssertEqualObjects(_player.calls, @[@"play c"]);
    XCTAssertEqualObjects(_undo.undoActionName, STR_MENU_EDIT_REMOVE_FROM_PLAYLIST);
}

#pragma mark - The successor re-park

// Every re-park path, under every mode, parks exactly the playlist's
// trackEndSuccessor. Repeat One and Pause make a row-index guess visible: the
// successor is the current row itself, or nil.
- (void)testEveryReparkParksTheModesSuccessor {
    NSArray<NSArray *> *modes = @[
        @[@"off",     @(VibeRepeatModeOff), @NO,  @NO],
        @[@"all",     @(VibeRepeatModeAll), @NO,  @NO],
        @[@"one",     @(VibeRepeatModeOne), @NO,  @NO],
        @[@"pause",   @(VibeRepeatModeAll), @NO,  @YES],
        @[@"shuffle", @(VibeRepeatModeOff), @YES, @NO],
    ];
    for (NSArray *mode in modes) {
        AppSettings *settings = AppSettings.sharedInstance;
        settings.repeatMode = (VibeRepeatMode)[mode[1] integerValue];
        settings.shuffleEnabled = [mode[2] boolValue];
        settings.pauseAtTrackEnd = [mode[3] boolValue];
        [_controller pushTransportModesToPlaylist];
        NSArray<AudioTrack *> *tracks = [self load:@"a b c d e f" row:2 state:VibeShellTestPlayerStatePlaying];
        NSDictionary<NSString *, dispatch_block_t> *paths = @{
            @"1 remove": ^{
                [self gesture:^{
                    [self->_controller removePlaylistTracks:@[tracks[4]]];
                }];
            },
            @"2 restore": ^{
                [self->_undo undo];
            },
            @"3 append": ^{
                [self->_controller addTracks:TracksNamed(@"g h")];
            },
            @"4 move": ^{
                [self gesture:^{
                    [self.playlist moveTracksAtIndexes:RowSet(5) toIndexes:RowSet(3)];
                }];
            },
            @"5 end of track": ^{
                [self->_controller applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
            },
        };
        for (NSString *path in [paths.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSUInteger before = _player.prefetchCount;
            paths[path]();
            NSString *context = [NSString stringWithFormat:@"%@ under %@", path, mode[0]];
            XCTAssertEqual(_player.prefetchCount, before + 1, @"%@", context);
            [self assertParkedTheSuccessor:context];
        }
        XCTAssertEqual(self.playlist.currentTrack, tracks[2], @"%@", mode[0]);
    }
}

- (void)testAStoppedPlayerParksNothingOnAnyPath {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d" row:1 state:VibeShellTestPlayerStateStopped];
    [self gesture:^{
        [self->_controller removePlaylistTracks:@[tracks[3]]];
    }];
    [_undo undo];
    [_controller addTracks:TracksNamed(@"e")];
    [self gesture:^{
        [self.playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(2)];
    }];
    [_controller applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
    XCTAssertEqual(_player.prefetchCount, 0u);
}

// Each writer of Pause, repeat or shuffle pushes the modes and re-parks.
- (void)testEveryEndOfTrackWriterPushesAndReparks {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:4 state:VibeShellTestPlayerStatePaused];
    MainPlayerController *controller = _controller;
    NSMenuItem *repeatOne = [NSMenuItem new];
    repeatOne.identifier = VibeRepeatMenuIdentifier(VibeRepeatModeOne);
    NSArray *writers = @[
        // Off -> All: the last row wraps to the first.
        @[@"cycle repeat", ^{ [controller cycleRepeatMode:nil]; }, tracks[0]],
        // All -> One: the current row itself.
        @[@"cycle repeat again", ^{ [controller cycleRepeatMode:nil]; }, tracks[4]],
        @[@"Pause", ^{
            AppSettings.sharedInstance.pauseAtTrackEnd = YES;
            [controller applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
        }, NSNull.null],
        @[@"Continue", ^{
            AppSettings.sharedInstance.pauseAtTrackEnd = NO;
            [controller applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
        }, tracks[4]],
        @[@"Now Playing repeat off", ^{
            [controller nowPlayingController:(NowPlayingController *)NSNull.null setRepeatMode:VibeRepeatModeOff];
        }, NSNull.null],
        @[@"repeat menu", ^{ [controller selectRepeatMode:repeatOne]; }, tracks[4]],
        @[@"shuffle", ^{ [controller toggleShuffle:nil]; }, NSNull.null],
        @[@"Now Playing shuffle", ^{
            [controller nowPlayingController:(NowPlayingController *)NSNull.null setShuffleEnabled:NO];
        }, tracks[4]],
    ];
    for (NSArray *writer in writers) {
        NSUInteger before = _player.prefetchCount;
        ((dispatch_block_t)writer[1])();
        XCTAssertEqual(_player.prefetchCount, before + 1, @"%@", writer[0]);
        [self assertParkedTheSuccessor:writer[0]];
        if (writer[2] != NSNull.null) {
            XCTAssertEqual(_player.parkedTrack, writer[2], @"%@", writer[0]);
        }
    }
}

#pragma mark - The deferred metadata sweep

- (void)testTheSweepWaitsForSettlementAndStartsOnce {
    [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    XCTAssertEqual(_timers.count, 1u);
    XCTAssertEqualObjects(_cache.calls, @[]);
    [_controller startPendingMetadataLoad];
    XCTAssertEqualObjects(_cache.calls, @[@"load 3"]);
    [_controller startPendingMetadataLoad];
    _timers.lastObject();
    XCTAssertEqualObjects(_cache.calls, @[@"load 3"]);
}

- (void)testTheBoundStartsTheSweepOnceWhenSettlementNeverComes {
    [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    _timers.lastObject();
    XCTAssertEqualObjects(_cache.calls, @[@"load 3"]);
    [_controller startPendingMetadataLoad];
    _timers.lastObject();
    XCTAssertEqualObjects(_cache.calls, @[@"load 3"]);
}

- (void)testAReplacementOpenCancelsThePreviousDeferral {
    [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    dispatch_block_t first = _timers.lastObject;
    [_controller loadTracks:TracksNamed(@"x y") selectingIndex:0 startPaused:NO];
    XCTAssertEqualObjects(_cache.calls, @[@"cancel"], @"the old scan dies before the new submission");
    first();
    XCTAssertEqualObjects(_cache.calls, @[@"cancel"]);
    _timers.lastObject();
    NSArray *expected = @[@"cancel", @"load 2"];
    XCTAssertEqualObjects(_cache.calls, expected);
}

- (void)testAnAppendMidOpenCoalescesIntoOneSweep {
    [self load:@"a b" row:0 state:VibeShellTestPlayerStatePlaying];
    dispatch_block_t first = _timers.lastObject;
    [_controller addTracks:TracksNamed(@"c")];
    first();
    XCTAssertEqualObjects(_cache.calls, @[]);
    [_controller startPendingMetadataLoad];
    XCTAssertEqualObjects(_cache.calls, @[@"load 3"]);
}

- (void)testCloseCancelsTheDeferral {
    [self load:@"a b" row:0 state:VibeShellTestPlayerStatePlaying];
    [_controller closeFile:nil];
    _timers.lastObject();
    [_controller startPendingMetadataLoad];
    XCTAssertEqualObjects(_cache.calls, @[@"cancel"]);
}

#pragma mark - The reorder follow-up

- (void)testAMoveKeepsTheCurrentObjectReparksAndRegistersItsInverse {
    NSArray<AudioTrack *> *tracks = [self load:@"a b c d e" row:1 state:VibeShellTestPlayerStatePaused];
    [self gesture:^{
        [self.playlist moveTracksAtIndexes:RowSet(4) toIndexes:RowSet(2)];
    }];
    XCTAssertEqualObjects(NamesOf(self.playlist.playlist), @"a b e c d");
    XCTAssertEqual(self.playlist.currentTrack, tracks[1]);
    XCTAssertEqualObjects(_player.calls, @[@"prefetch e"], @"no play funnel: a paused row stays paused");
    XCTAssertEqualObjects(_cache.neighborhood, self.playlist.neighborhoodTracks);
    XCTAssertEqualObjects(_undo.undoActionName, STR_MENU_EDIT_REORDER);

    [_undo undo];
    XCTAssertEqualObjects(self.playlist.playlist, tracks);
    XCTAssertEqual(self.playlist.currentTrack, tracks[1]);
    [self assertParkedTheSuccessor:@"after undo"];

    [_undo redo];
    XCTAssertEqualObjects(NamesOf(self.playlist.playlist), @"a b e c d");
    XCTAssertTrue(_undo.canUndo, @"the redo's move registers the undo again");
}

- (void)testAMovesUndoAfterAReplacementMovesNothing {
    [self load:@"a b c" row:0 state:VibeShellTestPlayerStatePlaying];
    [self gesture:^{
        [self.playlist moveTracksAtIndexes:RowSet(0) toIndexes:RowSet(2)];
    }];
    NSArray<AudioTrack *> *replacement = [self load:@"x y z" row:0 state:VibeShellTestPlayerStatePlaying];
    [_undo undo];
    XCTAssertEqualObjects(self.playlist.playlist, replacement);
    XCTAssertEqualObjects(_player.calls, @[]);
    XCTAssertFalse(_undo.canRedo, @"a refused restore registers nothing");
}

#pragma mark - Equalizer demand

- (void)testTheMeterFollowsCountedDemand {
    _player.outputAudioActive = YES;
    [_controller equalizerLevelsWanted:YES];
    XCTAssertTrue(_player.levelsEnabled);
    // A reused row view takes the source before the old one lets go.
    [_controller equalizerLevelsWanted:YES];
    [_controller equalizerLevelsWanted:NO];
    XCTAssertTrue(_player.levelsEnabled);
    [_controller equalizerLevelsWanted:NO];
    XCTAssertFalse(_player.levelsEnabled, @"zero consumers remove the meter");
}

- (void)testTheMeterNeedsOutputAudioAndAVisibleWindow {
    [_controller equalizerLevelsWanted:YES];
    XCTAssertFalse(_player.levelsEnabled, @"no output audio");
    XCTAssertFalse(self.playlist.equalizerAudioOutputActive);

    _player.outputAudioActive = YES;
    [_controller syncEqualizerActivity];
    XCTAssertTrue(_player.levelsEnabled);
    XCTAssertTrue(self.playlist.equalizerAudioOutputActive);
    XCTAssertTrue(self.playlist.equalizerSurfaceVisible);

    MainPlayerController.testWindowVisible = NO;
    [_controller syncEqualizerActivity];
    XCTAssertFalse(_player.levelsEnabled, @"occluded");
    XCTAssertFalse(self.playlist.equalizerSurfaceVisible);
}

- (void)testAnUnbalancedReleaseIsCaughtAndCountsNothing {
    _player.outputAudioActive = YES;
    XCTAssertThrows([_controller equalizerLevelsWanted:NO]);
    [_controller equalizerLevelsWanted:YES];
    XCTAssertTrue(_player.levelsEnabled, @"the refused release did not go negative");
}

// The device runs every integer file at its widest depth. The Active caption
// names the file's depth instead. That depth reaches the device unchanged.
- (void)testTheActiveCaptionShowsTheFilesDepthNotTheDevices {
    _player.bitPerfectReport = (VibeBitPerfectReport){.status = VibeBitPerfectStatusActive, .sampleRate = 96000,
                                                      .bitsPerChannel = 32, .sourceBits = 16};
    NSString *caption = [_controller bitPerfectStatusText];
    XCTAssertTrue([caption containsString:@"16-bit"], @"%@", caption);
    XCTAssertFalse([caption containsString:@"32"], @"%@", caption);
}

@end
