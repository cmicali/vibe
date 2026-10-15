//
//  PlaylistControllerTests.m
//
//  The reorder drag's proof and its identity resolution, through the real
//  controller over a real, windowless PlaylistTableView. AppKit's dragging
//  session is the boundary: the tests make the data source calls AppKit makes,
//  with a dragging info that carries a source and a pasteboard's strings.
//

#import <XCTest/XCTest.h>

#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PlaylistTestSupport.h"
#import "ShellTestFakes.h"

@interface VibeTestDraggingInfo : NSObject
@property (nonatomic, weak) id draggingSource;
@property (nonatomic, copy) NSDictionary<NSPasteboardType, NSString *> *strings;
@end

@implementation VibeTestDraggingInfo
// Stands in for the pasteboard too: the controller reads it by type.
- (NSPasteboard *)draggingPasteboard {
    return (NSPasteboard *)self;
}

- (NSString *)stringForType:(NSPasteboardType)type {
    return self.strings[type];
}
@end

@interface PlaylistControllerTests : XCTestCase
@end

@implementation PlaylistControllerTests {
    VibeShellTestPlayer *_player;
    PlaylistController *_controller;
    NSScrollView *_scrollView;
    PlaylistTableView *_table;
    NSArray<AudioTrack *> *_tracks;
    NSMutableArray<NSString *> *_moves;
    NSPasteboardType _reorderType;
}

static NSArray<AudioTrack *> *TracksNamed(NSString *names) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSString *name in [names componentsSeparatedByString:@" "]) {
        [urls addObject:URLNamed([name stringByAppendingString:@".mp3"])];
    }
    return Rows(urls);
}

static NSString *NamesOf(NSArray<AudioTrack *> *tracks) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (AudioTrack *track in tracks) {
        [names addObject:track.url.lastPathComponent.stringByDeletingPathExtension];
    }
    return [names componentsJoinedByString:@" "];
}

- (void)setUp {
    [super setUp];
    _player = [VibeShellTestPlayer new];
    _controller = [[PlaylistController alloc] initWithAudioPlayer:(AudioPlayer *)_player];
    _scrollView = [PlaylistTableView scrollViewWithFrame:NSMakeRect(0, 0, 300, 400)];
    _table = _scrollView.documentView;
    _controller.tableView = _table;
    _tracks = TracksNamed(@"a b c d e");
    [_controller loadTracks:_tracks selectingIndex:0];
    _moves = [NSMutableArray array];
    NSMutableArray<NSString *> *moves = _moves;
    _controller.playlistOrderDidChangeHandler = ^(NSIndexSet *source, NSIndexSet *destination) {
        [moves addObject:[NSString stringWithFormat:@"%@>%@", RowsString(source), RowsString(destination)]];
    };
}

#pragma mark - Helpers

// AppKit's two calls before a drag: a writer per row, then the session start.
// Answers the items, so a test can read what each carried.
- (NSArray<NSPasteboardItem *> *)beginDragOfRows:(NSIndexSet *)rows {
    NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [items addObject:(NSPasteboardItem *)[self->_controller tableView:self->_table
                                                     pasteboardWriterForRow:(NSInteger)row]];
    }];
    NSDraggingSession *session = nil;
    [_controller tableView:_table draggingSession:session willBeginAtPoint:NSZeroPoint forRowIndexes:rows];
    for (NSPasteboardType type in items.firstObject.types) {
        if (![type isEqualToString:NSPasteboardTypeFileURL]) {
            _reorderType = type;
        }
    }
    return items;
}

- (void)endDrag {
    NSDraggingSession *session = nil;
    [_controller tableView:_table draggingSession:session endedAtPoint:NSZeroPoint operation:NSDragOperationNone];
}

- (VibeTestDraggingInfo *)infoFromSource:(id)source carrying:(NSArray<NSPasteboardItem *> *)items {
    VibeTestDraggingInfo *info = [VibeTestDraggingInfo new];
    info.draggingSource = source;
    NSMutableDictionary<NSPasteboardType, NSString *> *strings = [NSMutableDictionary dictionary];
    for (NSPasteboardType type in items.firstObject.types) {
        strings[type] = [items.firstObject stringForType:type];
    }
    info.strings = strings;
    return info;
}

- (NSDragOperation)validate:(VibeTestDraggingInfo *)info slot:(NSInteger)slot {
    return [_controller tableView:_table validateDrop:(id<NSDraggingInfo>)info
                      proposedRow:slot proposedDropOperation:NSTableViewDropAbove];
}

- (BOOL)accept:(VibeTestDraggingInfo *)info slot:(NSInteger)slot {
    return [_controller tableView:_table acceptDrop:(id<NSDraggingInfo>)info
                              row:slot dropOperation:NSTableViewDropAbove];
}

#pragma mark - The proof

- (void)testALiveSessionReordersAndRaisesTheFollowUpOnce {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSet(0)]];
    XCTAssertEqual([self validate:info slot:3], NSDragOperationMove);
    XCTAssertTrue([self accept:info slot:3]);
    XCTAssertEqualObjects(NamesOf(_controller.playlist), @"b c a d e");
    XCTAssertEqualObjects(_moves, @[@"0>2"]);
    XCTAssertEqual(_controller.currentTrack, _tracks[0], @"the current object moves with its row");
    XCTAssertEqualObjects(_player.calls, @[], @"a move is no play");
}

- (void)testEveryRowOfOneDragCarriesOneToken {
    NSArray<NSPasteboardItem *> *items = [self beginDragOfRows:RowRange(1, 3)];
    XCTAssertNotNil(_reorderType);
    NSString *token = [items[0] stringForType:_reorderType];
    XCTAssertNotNil(token);
    for (NSPasteboardItem *item in items) {
        XCTAssertEqualObjects([item stringForType:_reorderType], token);
    }
}

- (void)testATokenFromAnEndedSessionIsRefused {
    VibeTestDraggingInfo *stale = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSet(0)]];
    [self endDrag];
    XCTAssertEqual([self validate:stale slot:3], NSDragOperationNone, @"no session is live");
    [self beginDragOfRows:RowSet(0)];
    XCTAssertEqual([self validate:stale slot:3], NSDragOperationNone, @"a newer session has its own token");
    XCTAssertFalse([self accept:stale slot:3]);
    XCTAssertEqualObjects(_controller.playlist, _tracks);
    XCTAssertEqualObjects(_moves, @[]);
}

- (void)testAnotherSourceIsRefused {
    NSArray<NSPasteboardItem *> *items = [self beginDragOfRows:RowSet(0)];
    NSTableView *other = [[NSTableView alloc] initWithFrame:NSZeroRect];
    XCTAssertEqual([self validate:[self infoFromSource:other carrying:items] slot:3], NSDragOperationNone);
    XCTAssertEqual([self validate:[self infoFromSource:nil carrying:items] slot:3], NSDragOperationNone);
}

// An external drag carries a file URL too, so the URL alone proves nothing.
- (void)testAFileURLWithoutTheTokenIsRefused {
    [self beginDragOfRows:RowSet(0)];
    VibeTestDraggingInfo *info = [VibeTestDraggingInfo new];
    info.draggingSource = _table;
    info.strings = @{NSPasteboardTypeFileURL: _tracks[0].url.absoluteString};
    XCTAssertEqual([self validate:info slot:3], NSDragOperationNone);
}

- (void)testAHeldPlaylistRefusesTheDrop {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSet(0)]];
    _controller.structureEditsHeld = YES;
    XCTAssertEqual([self validate:info slot:3], NSDragOperationNone);
    XCTAssertFalse([self accept:info slot:3]);
    XCTAssertEqualObjects(_controller.playlist, _tracks);
}

- (void)testANoOpSlotDrawsNoLine {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSet(1)]];
    XCTAssertEqual([self validate:info slot:1], NSDragOperationNone);
    XCTAssertEqual([self validate:info slot:2], NSDragOperationNone);
    XCTAssertEqual([self validate:info slot:0], NSDragOperationMove);
}

#pragma mark - Identity, not row numbers

- (void)testDraggedRowsAreFollowedAfterTheyShift {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSetOf(@[@1, @3])]];
    [_controller removeTracksAtIndexes:RowSet(0)];   // b and d shift up a row
    XCTAssertTrue([self accept:info slot:4]);
    XCTAssertEqualObjects(NamesOf(_controller.playlist), @"c e b d");
}

- (void)testADraggedRowRemovedMidDragDropsOutAlone {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSetOf(@[@1, @3])]];
    [_controller removeTracksAtIndexes:RowSet(3)];   // d leaves
    XCTAssertTrue([self accept:info slot:4]);
    XCTAssertEqualObjects(NamesOf(_controller.playlist), @"a c e b");
    XCTAssertEqualObjects(_moves, @[@"1>3"]);
}

- (void)testAReplacedPlaylistRejectsTheDrag {
    VibeTestDraggingInfo *info = [self infoFromSource:_table carrying:[self beginDragOfRows:RowSet(0)]];
    NSArray<AudioTrack *> *replacement = TracksNamed(@"a b c d e");
    [_controller loadTracks:replacement selectingIndex:0];
    XCTAssertEqual([self validate:info slot:3], NSDragOperationNone, @"same names, new objects");
    XCTAssertFalse([self accept:info slot:3]);
    XCTAssertEqualObjects(_controller.playlist, replacement);
}

#pragma mark - What goes out

// One file URL per file, so a drop outside copies a cue image once.
- (void)testOnlyTheFirstRowOfAFileCarriesItsURL {
    NSArray<AudioTrack *> *rows = @[CueRowOf(@"album.flac", 0, 100), CueRowOf(@"album.flac", 100, 200),
                                    CueRowOf(@"other.flac", 0, 0)];
    [_controller loadTracks:rows selectingIndex:0];
    NSArray<NSPasteboardItem *> *items = [self beginDragOfRows:RowRange(0, 3)];
    XCTAssertNotNil([items[0] stringForType:NSPasteboardTypeFileURL]);
    XCTAssertNil([items[1] stringForType:NSPasteboardTypeFileURL]);
    XCTAssertNotNil([items[2] stringForType:NSPasteboardTypeFileURL]);
    XCTAssertNotNil([items[1] stringForType:_reorderType], @"the row still reorders");
}

@end
