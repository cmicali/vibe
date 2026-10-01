//
//  PlaylistController.m
//  Vibe
//

#import "PlaylistController.h"
#import "AudioTrackMetadata.h"
#import "Playlist.h"
#import "PlaylistDragRules.h"
#import "PlaylistTableView.h"
#import "PlaylistRowView.h"
#import "CloudTransferRegistry.h"
#import "EqualizerIndicatorView.h"
#import "LoadingIndicatorView.h"
#import "MainMenuBuilder.h" // vends the row context menu's symbol items
#import "TrackCommands.h"
#import "VibeStrings.h"

static NSString *const kPlaylistRowViewIdentifier = @"playlistRow";

// With the live session's token as payload, the whole proof a drop is this
// table's reorder: an external file drag carries a file URL too.
static NSPasteboardType const kPlaylistReorderPasteboardType =
        @"com.commonwealthrecordings.vibe.playlist-reorder";

@interface PlaylistController () <NSMenuItemValidation, NSMenuDelegate, PlaylistObserver,
        CloudTransferRegistryObserver>
@end

@implementation PlaylistController {
    Playlist *_model;
    __weak PlaylistTableView *_tableView;
    __weak NSClipView *_observedClipView;
    // Remove's targets, captured at menu open as exact objects so a
    // replacement while the menu is up cannot remove strangers. Weak, and
    // deliberately not cleared on close: the action can run after
    // menuDidClose:.
    NSPointerArray *_menuOpenTargetTracks;
    // The live reorder drag: the exact dragged objects (never rows — every
    // validation re-resolves them) and the token proving a pasteboard belongs
    // to THIS session. Cleared at session end.
    NSArray<AudioTrack *> *_dragSessionTracks;
    NSString *_dragSessionToken;
    NSMutableSet<NSURL *> *_dragSessionFileURLs;
    // Only the URLs whose scope start answered YES; see willBeginAtPoint:.
    NSArray<NSURL *> *_dragSessionScopedURLs;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:AudioTrackMetadataThumbnailDidLoadNotification
                                                object:nil];
    if (_observedClipView) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSViewBoundsDidChangeNotification
                                                    object:_observedClipView];
    }
}

- (NSArray<AudioTrack *> *)playlist {
    return [_model tracks];
}

- (AudioTrack *)trackAtIndex:(NSUInteger)index {
    return [_model trackAtIndex:index];
}

- (NSUInteger)currentIndex {
    return _model.currentIndex;
}

- (NSUInteger)structureGeneration {
    return _model.structureGeneration;
}

- (void)setCurrentIndex:(NSUInteger)currentIndex {
    _model.currentIndex = currentIndex;
}

- (PlaylistTableView *)tableView {
    return _tableView;
}

- (void)setTableView:(PlaylistTableView *)tableView {
    if (_observedClipView) {
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:NSViewBoundsDidChangeNotification
                                                    object:_observedClipView];
    }
    _tableView = tableView;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(doubleClick:)];
    // Shadows the window-wide menu: these items act on the CLICKED row, not
    // the current track, so they carry their own selectors and identifiers.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Playlist Menu")];
    [menu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_SHOW_IN_FINDER
                                            symbolName:@"folder"
                                                action:@selector(showClickedTrackInFinder:)
                                                target:self
                                            identifier:@"show_clicked_track_in_finder"]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_EDIT_COPY_NAME
                                            symbolName:@"textformat"
                                                action:@selector(copyClickedTrackName:)
                                                target:self
                                            identifier:@"copy_clicked_track_name"]];
    [menu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_EDIT_COPY_FILE
                                            symbolName:@"doc.on.doc"
                                                action:@selector(copyClickedTrackFile:)
                                                target:self
                                            identifier:@"copy_clicked_track_file"]];
    [menu addItem:[NSMenuItem separatorItem]];
    // minus.circle, not trash: the file stays on disk.
    [menu addItem:[MainMenuBuilder symbolItemWithTitle:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST
                                            symbolName:@"minus.circle"
                                                action:@selector(removeClickedTrackFromPlaylist:)
                                                target:self
                                            identifier:@"remove_clicked_track_from_playlist"]];
    menu.delegate = self;
    _tableView.menu = menu;

    // Only the private type: an external file drag must fall through to the
    // window's Add/Replace wells.
    [_tableView registerForDraggedTypes:@[kPlaylistReorderPasteboardType]];
    [_tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

    NSClipView *clipView = tableView.enclosingScrollView.contentView;
    if (!clipView) {
        return;
    }
    clipView.postsBoundsChangedNotifications = YES;
    _observedClipView = clipView;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(playlistClipBoundsDidChange:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:clipView];
    CloudTransferRegistry.sharedRegistry.observer = self;
}

- (instancetype)initWithAudioPlayer:(AudioPlayer *)audioPlayer {
    self = [super init];
    if (self) {
        _model = [Playlist new];
        _model.observer = self;
        self.audioPlayer = audioPlayer;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(thumbnailDidLoad:)
                                                   name:AudioTrackMetadataThumbnailDidLoadNotification
                                                 object:nil];
    }
    return self;
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    PlaylistTableView *tableView = self.tableView;
    NSInteger artColumn = [tableView columnWithIdentifier:kPlaylistColumnArt];
    if (!tableView || artColumn < 0) {
        return;
    }
    NSRange visibleRows = [tableView rowsInRect:tableView.visibleRect];
    if (visibleRows.location == NSNotFound || visibleRows.length == 0) {
        return;
    }
    NSMutableIndexSet *matchingRows = [NSMutableIndexSet indexSet];
    for (NSUInteger row = visibleRows.location;
         row < NSMaxRange(visibleRows) && row < _model.count; row++) {
        if ([_model trackAtIndex:row].metadata == notification.object) {
            [matchingRows addIndex:row];
        }
    }
    if (matchingRows.count > 0) {
        [tableView reloadDataForRowIndexes:matchingRows
                             columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)artColumn]];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_model.count;
}

#pragma mark - Row dragging (reorder inside, files outside)

// The token qualifies a reorder drop; the file URL is what a drop outside the
// app copies, once per file however many of its cue rows are dragged. AppKit
// asks once per dragged row before the session begins, so the first ask mints
// the token and the rest of the selection shares it.
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView
              pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_model.count) {
        return nil;
    }
    if (!_dragSessionToken) {
        _dragSessionToken = NSUUID.UUID.UUIDString;
        _dragSessionFileURLs = [NSMutableSet set];
    }
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:_dragSessionToken forType:kPlaylistReorderPasteboardType];
    NSURL *url = [_model trackAtIndex:(NSUInteger)row].url;
    if (url.isFileURL && ![_dragSessionFileURLs containsObject:url]) {
        [_dragSessionFileURLs addObject:url];
        [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    }
    return item;
}

- (void)tableView:(NSTableView *)tableView
  draggingSession:(NSDraggingSession *)session
 willBeginAtPoint:(NSPoint)screenPoint
    forRowIndexes:(NSIndexSet *)rowIndexes {
    _dragSessionTracks = [_model tracksAtIndexes:rowIndexes];
    // An outside receiver reads the files after the drag, so the scope
    // outlives it; endedAtPoint: balances it. Only a start that answered YES
    // is recorded: an unbalanced stop over-releases the sandbox extension (a
    // folder-granted URL answers NO and drags fine).
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    for (AudioTrack *track in _dragSessionTracks) {
        NSURL *url = track.url;
        if ([url startAccessingSecurityScopedResource]) {
            [scoped addObject:url];
        }
    }
    _dragSessionScopedURLs = scoped;
}

// The one qualification for both the insertion line and the drop, so the line
// never promises a move the accept refuses. nil for no move; otherwise
// outSourceRows (optional) carries the surviving dragged rows.
- (NSIndexSet *)reorderDestinationForInfo:(id<NSDraggingInfo>)info
                              proposedRow:(NSInteger)row
                               sourceRows:(NSIndexSet **)outSourceRows {
    if (![self draggingInfoIsLiveReorderSession:info]) {
        return nil;
    }
    NSIndexSet *sourceRows = [self rowsForTracks:_dragSessionTracks];
    NSIndexSet *destination = VibePlaylistDropDestinationForSlot(sourceRows, row, _model.count);
    if (destination && outSourceRows) {
        *outSourceRows = sourceRows;
    }
    return destination;
}

- (BOOL)draggingInfoIsLiveReorderSession:(id<NSDraggingInfo>)info {
    if (info.draggingSource != _tableView || !_dragSessionToken) {
        return NO;
    }
    NSString *token = [info.draggingPasteboard stringForType:kPlaylistReorderPasteboardType];
    return [token isEqualToString:_dragSessionToken];
}

// O(1) in playlist size per hover: never an index rebuild or a reload.
- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    if (![self reorderDestinationForInfo:info proposedRow:row sourceRows:NULL]) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {
    // Requalified: the playlist may have changed since the last validation.
    NSIndexSet *sourceRows;
    NSIndexSet *destination = [self reorderDestinationForInfo:info
                                                  proposedRow:row
                                                   sourceRows:&sourceRows];
    return destination && [_model moveTracksAtIndexes:sourceRows toIndexes:destination];
}

// Always called, drop or cancel.
- (void)tableView:(NSTableView *)tableView
  draggingSession:(NSDraggingSession *)session
     endedAtPoint:(NSPoint)screenPoint
        operation:(NSDragOperation)operation {
    for (NSURL *url in _dragSessionScopedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
    _dragSessionScopedURLs = nil;
    _dragSessionTracks = nil;
    _dragSessionToken = nil;
    _dragSessionFileURLs = nil;
}

#pragma mark - Playlist observer

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // The cursor is reset without its setter, so nothing else announces it.
    [self notifyCurrentIndexDidChange];
    // reloadData keeps selection by row index, which would land on an
    // unrelated row of the new playlist.
    [self.tableView deselectAll:nil];
    [self.tableView reloadData];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    // Not reloadData: existing row views, and so the playing marking, survive.
    [self.tableView insertRowsAtIndexes:indexes withAnimation:NSTableViewAnimationEffectNone];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    [self reloadTrackAtIndex:index];
}

- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes {
    PlaylistTableView *tableView = self.tableView;
    [tableView removeRowsAtIndexes:indexes withAnimation:NSTableViewAnimationEffectNone];
    // Presentation only; never starts a play.
    NSUInteger count = _model.count;
    if (count > 0) {
        [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(indexes.firstIndex, count - 1)]
               byExtendingSelection:NO];
    }
    [self refreshRowViewPlayingStates];
    [self reconfigureVisibleNumberCells];
    // No currentIndexDidChangeHandler: the shell's removal funnel follows up
    // once from the final state; a second edge would reconcile one edit twice.
}

- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes {
    PlaylistTableView *tableView = self.tableView;
    [tableView insertRowsAtIndexes:indexes withAnimation:NSTableViewAnimationEffectNone];
    [self selectRevealAndRestampRows:indexes];
}

// Presentation only, never a play: revealed because an undo whose rows are
// off screen reads as a no-op. The re-stamp runs before the run loop returns,
// so no frame shows two playing rows.
- (void)selectRevealAndRestampRows:(NSIndexSet *)rows {
    PlaylistTableView *tableView = self.tableView;
    [tableView selectRowIndexes:rows byExtendingSelection:NO];
    [tableView scrollRowToVisible:(NSInteger)rows.firstIndex];
    [self refreshRowViewPlayingStates];
    [self reconfigureVisibleNumberCells];
}

- (void)playlist:(Playlist *)playlist
        didMoveTracksFromIndexes:(NSIndexSet *)sourceIndexes
                       toIndexes:(NSIndexSet *)destinationIndexes {
    PlaylistTableView *tableView = self.tableView;
    // TRAP: moveRowAtIndex: has no animation argument and slides by default.
    // A sliding row from off screen lands as a blank slot, and one still
    // sliding when endUpdates' cleanup runs is retained by the table for good.
    // The zero-duration group closes the slot and most of the retention;
    // rapid back-to-back reorders or undos can still strand a few row views,
    // an AppKit bug with no public-API cure.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0;
        [tableView beginUpdates];
        VibePlaylistMoveSequenceEnumerate(sourceIndexes, destinationIndexes,
                                          ^(NSUInteger from, NSUInteger to) {
            [tableView moveRowAtIndex:(NSInteger)from toIndex:(NSInteger)to];
        });
        [tableView endUpdates];
    }];
    // Selected explicitly: a drag begun outside the selection would leave it.
    [self selectRevealAndRestampRows:destinationIndexes];
    // Here, not at the drop site, so every initiator — undo included — gets it.
    if (self.playlistOrderDidChangeHandler) {
        self.playlistOrderDidChangeHandler(sourceIndexes, destinationIndexes);
    }
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [self notifyCurrentIndexDidChange];
    [self refreshRowViewPlayingStates];
    // Now, not after the async didStartPlaying round-trip.
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    if (previousIndex < _model.count) {
        [rows addIndex:previousIndex];
    }
    if (_model.currentIndex < _model.count) {
        [rows addIndex:_model.currentIndex];
    }
    if (rows.count == 0) {
        return;
    }
    [self.tableView reloadDataForRowIndexes:rows
                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (void)notifyCurrentIndexDidChange {
    if (self.currentIndexDidChangeHandler) {
        self.currentIndexDidChangeHandler();
    }
}

#pragma mark - Row views

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    PlaylistRowView *rowView = [tableView makeViewWithIdentifier:kPlaylistRowViewIdentifier owner:self];
    if (!rowView) {
        rowView = [[PlaylistRowView alloc] initWithFrame:NSZeroRect];
        rowView.identifier = kPlaylistRowViewIdentifier;
    }
    rowView.playingRow = (row == (NSInteger)self.currentIndex);
    return rowView;
}

// Cell reloads and structural edits keep row views, so the flag is re-stamped
// here; rows scrolled in later get theirs from rowViewForRow:.
- (void)refreshRowViewPlayingStates {
    NSInteger current = (NSInteger)self.currentIndex;
    [self.tableView enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rowView, NSInteger row) {
        if ([rowView isKindOfClass:[PlaylistRowView class]]) {
            ((PlaylistRowView *)rowView).playingRow = (row == current);
        }
    }];
}

#pragma mark - Cell population

- (BOOL)isCurrentEqualizerRowVisible {
    PlaylistTableView *tableView = self.tableView;
    if (!tableView.window || self.currentIndex >= _model.count) {
        return NO;
    }
    NSClipView *clipView = tableView.enclosingScrollView.contentView;
    NSView *windowContent = tableView.window.contentView;
    if (!clipView || !windowContent) {
        return NO;
    }

    NSRect rowInClip = [tableView convertRect:[tableView rectOfRow:(NSInteger)self.currentIndex]
                                      toView:clipView];
    NSRect visibleInClip = NSIntersectionRect(rowInClip, clipView.bounds);
    if (NSIsEmptyRect(visibleInClip)) {
        return NO;
    }

    NSRect visibleInWindow = [clipView convertRect:visibleInClip toView:windowContent];
    return !NSIsEmptyRect(NSIntersectionRect(visibleInWindow, windowContent.bounds));
}

- (void)updateCurrentEqualizerActivity {
    PlaylistTableView *tableView = self.tableView;
    NSInteger column = [tableView columnWithIdentifier:kPlaylistColumnNumber];
    if (column < 0 || self.currentIndex >= _model.count) {
        return;
    }
    NSTableCellView *cell = [tableView viewAtColumn:column
                                                row:(NSInteger)self.currentIndex
                                    makeIfNecessary:NO];
    EqualizerIndicatorView *indicator = cell
            ? [PlaylistTableView equalizerViewInCell:cell] : nil;
    if (!indicator) {
        return;
    }
    indicator.audioOutputActive = self.equalizerAudioOutputActive;
    indicator.presentationVisible = self.equalizerSurfaceVisible
            && [self isCurrentEqualizerRowVisible];
}

- (void)playlistClipBoundsDidChange:(NSNotification *)notification {
    [self updateCurrentEqualizerActivity];
}

- (void)setEqualizerAudioOutputActive:(BOOL)equalizerAudioOutputActive {
    if (_equalizerAudioOutputActive == equalizerAudioOutputActive) {
        return;
    }
    _equalizerAudioOutputActive = equalizerAudioOutputActive;
    [self updateCurrentEqualizerActivity];
}

- (void)setEqualizerSurfaceVisible:(BOOL)equalizerSurfaceVisible {
    _equalizerSurfaceVisible = equalizerSurfaceVisible;
    // Not deduplicated: the flag can stay YES while a resize clips the row.
    [self updateCurrentEqualizerActivity];
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    AudioTrack *track = [_model trackAtIndex:(NSUInteger)row];
    BOOL isCurrentRow = (row == (NSInteger)self.currentIndex);
    NSTableCellView *view = [_tableView cellViewForColumn:tableColumn];
    if ([tableColumn.identifier isEqualToString:kPlaylistColumnNumber]) {
        [self configureNumberCell:view row:row track:track isCurrentRow:isCurrentRow];
    }
    else if ([tableColumn.identifier isEqualToString:kPlaylistColumnArt]) {
        view.imageView.image = [PlaylistTableView artworkCellImage:track.cachedThumbnail];
    }
    else if ([tableColumn.identifier isEqualToString:kPlaylistColumnTitle]) {
        view.textField.attributedStringValue = [PlaylistTableView titleCellStringForTrack:track];
    }
    else if ([tableColumn.identifier isEqualToString:kPlaylistColumnLength]) {
        view.textField.attributedStringValue = [PlaylistTableView durationCellString:track.durationString];
    }

    return view;
}

// Precedence loading, playing, number: during the open there is no output, so
// the equalizer would be dots. Every state is set unconditionally, so a reused
// cell cannot carry a previous row's.
- (void)configureNumberCell:(NSTableCellView *)view
                        row:(NSInteger)row
                      track:(AudioTrack *)track
               isCurrentRow:(BOOL)isCurrentRow {
    EqualizerIndicatorView *eqView = [PlaylistTableView equalizerViewInCell:view];
    LoadingIndicatorView *loadingView = [PlaylistTableView loadingViewInCell:view];
    // Unconditional: a reused view releases its old source before declaring
    // demand against the new row's state.
    eqView.levelSource = self.levelSource;
    CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
    BOOL loading = track.url != nil && [registry isTransferringURL:track.url];
    loadingView.active = loading;
    loadingView.progress = loading ? [registry progressForURL:track.url] : -1;
    if (loading) {
        view.textField.hidden = YES;
        eqView.hidden = YES;
        eqView.audioOutputActive = NO;
        eqView.presentationVisible = NO;
    }
    else if (isCurrentRow) {
        view.textField.hidden = YES;
        eqView.hidden = NO;
        eqView.audioOutputActive = self.equalizerAudioOutputActive;
        eqView.presentationVisible = self.equalizerSurfaceVisible
                && [self isCurrentEqualizerRowVisible];
    }
    else {
        view.textField.hidden = NO;
        eqView.hidden = YES;
        eqView.audioOutputActive = NO;
        eqView.presentationVisible = NO;
        view.textField.attributedStringValue = [PlaylistTableView numberCellString:(NSUInteger)row + 1];
    }
}

- (void)cloudTransferRegistryDidChange:(CloudTransferRegistry *)registry {
    [self reconfigureVisibleNumberCells];
}

// In place: a reload would rebuild the playing row's indicator out from under
// its demand balancing.
- (void)reconfigureVisibleNumberCells {
    PlaylistTableView *tableView = self.tableView;
    NSInteger column = [tableView columnWithIdentifier:kPlaylistColumnNumber];
    if (column < 0) {
        return;
    }
    NSRange rows = [tableView rowsInRect:tableView.visibleRect];
    for (NSUInteger row = rows.location;
            row < NSMaxRange(rows) && row < _model.count; row++) {
        NSTableCellView *cell = [tableView viewAtColumn:column
                                                    row:(NSInteger)row
                                        makeIfNecessary:NO];
        if (!cell) {
            continue;
        }
        [self configureNumberCell:cell
                              row:(NSInteger)row
                            track:[_model trackAtIndex:row]
                     isCurrentRow:row == self.currentIndex];
    }
}

#pragma mark - Public API

- (AudioTrack *)currentTrack {
    return [_model currentTrack];
}

- (void)loadTracks:(NSArray<AudioTrack *> *)tracks selectingIndex:(NSUInteger)index {
    [_model replaceAllWithTracks:tracks startingAtIndex:index];
    // The observer's reloadData keeps the scroll offset, but a new playlist
    // starts at its cursor.
    [self scrollCurrentTrackToVisible];
}

- (void)append:(NSArray<AudioTrack *> *)tracks {
    [_model appendTracks:tracks];
}

- (void)play {
    [self playStartPaused:NO];
}

- (void)playStartPaused:(BOOL)startPaused {
    AudioTrack *track = self.currentTrack;
    if (!track) {
        return;
    }
#if VIBE_VERBOSE_LOGGING
    // Input-to-play latency, which exposes a lagging main thread. Only input
    // that can start a play counts: a track end or scripted play runs under
    // whatever stale event AppKit last saw.
    NSEvent *event = NSApp.currentEvent;
    NSTimeInterval sinceInput = NSProcessInfo.processInfo.systemUptime - event.timestamp;
    NSString *kind = event.type == NSEventTypeKeyDown ? @"key"
            : event.type == NSEventTypeSystemDefined ? @"media key"
            : event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp ? @"click"
            : nil;
    if (kind && !startPaused && sinceInput < 5) {
        LogInfo(@"Timeline: play of %@ requested %.0f ms after its input event (%@)",
                track.url.lastPathComponent, sinceInput * 1000, kind);
    }
#endif
    if (startPaused) {
        // The only entry point that can park; it declicks rather than
        // crossfades, since nothing of a parked start is heard.
        [self.audioPlayer play:track atPosition:0 startPaused:YES];
    }
    else {
        [self.audioPlayer play:track];   // the configured track-change crossfade
    }
    // AFTER submission, so the owner's refresh describes the new track.
    if (self.playWillStartHandler) {
        self.playWillStartHandler();
    }
}

- (void)clear {
    [_model clear];
}

- (void)reloadTrackAtIndex:(NSUInteger)index {
    // reloadCurrentTrack reaches here with index 0 on an empty playlist.
    if (index >= _model.count) {
        return;
    }
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (BOOL)hasNextTrack {
    return _model.hasNextTrack;
}

- (BOOL)hasPreviousTrack {
    return _model.hasPreviousTrack;
}

- (BOOL)next {
    if ([_model next]) {
        [self scrollCurrentTrackToVisible];
        [self play];
        return YES;
    }
    return NO;
}

- (BOOL)previous {
    if ([_model previous]) {
        [self scrollCurrentTrackToVisible];
        [self play];
        return YES;
    }
    return NO;
}

- (void)setRepeatMode:(VibeRepeatMode)repeatMode shuffleEnabled:(BOOL)shuffleEnabled {
    _model.repeatMode = repeatMode;
    _model.shuffleEnabled = shuffleEnabled;
}

- (AudioTrack *)trackEndSuccessor {
    return _model.trackEndSuccessor;
}

- (NSArray<AudioTrack *> *)neighborhoodTracks {
    return _model.neighborhoodTracks;
}

- (BOOL)advanceAtTrackEnd {
    if ([_model advanceAtTrackEnd]) {
        [self scrollCurrentTrackToVisible];
        [self play];
        return YES;
    }
    return NO;
}

- (BOOL)advanceFromTrack:(AudioTrack *)finishedTrack toTrack:(AudioTrack *)startedTrack {
    if ([_model advanceFromTrack:finishedTrack toTrack:startedTrack]) {
        [self scrollCurrentTrackToVisible];
        return YES;
    }
    return NO;
}

// scrollRowToVisible: no-ops for an on-screen row, so a user who scrolled away
// keeps their position until the next track change. Under shuffle the row
// centers instead, as far as the list's ends allow: the next row is usually
// far off, and an edge-hugging minimal scroll hides where the play order went.
- (void)scrollCurrentTrackToVisible {
    if (self.currentIndex >= _model.count) {
        return;
    }
    NSInteger row = (NSInteger)self.currentIndex;
    if (!_model.shuffleEnabled) {
        [self.tableView scrollRowToVisible:row];
        return;
    }
    NSClipView *clip = self.tableView.enclosingScrollView.contentView;
    NSRect bounds = clip.bounds;
    bounds.origin.y = NSMidY([self.tableView rectOfRow:row]) - NSHeight(bounds) / 2;
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [self.tableView.enclosingScrollView reflectScrolledClipView:clip];
}

- (void)doubleClick:(id)sender {
    if ([_tableView clickedRow] < 0) {
        return;
    }
    self.currentIndex = (NSUInteger) [_tableView clickedRow];
    [self play];
}

- (NSIndexSet *)selectedRows {
    // A playlist replacement can outrun the table's selection for a turn.
    NSIndexSet *rows = _tableView.selectedRowIndexes;
    NSUInteger count = _model.count;
    if (rows.lastIndex == NSNotFound || rows.lastIndex < count) {
        return rows;
    }
    NSMutableIndexSet *valid = [rows mutableCopy];
    [valid removeIndexesInRange:NSMakeRange(count, rows.lastIndex - count + 1)];
    return valid;
}

- (NSInteger)selectedRow {
    // Not NSTableView.selectedRow, which is the most recently CLICKED row of a
    // multi-row selection.
    NSUInteger row = [self selectedRows].firstIndex;
    return row != NSNotFound ? (NSInteger)row : -1;
}

- (NSArray<AudioTrack *> *)selectedTracks {
    return [_model tracksAtIndexes:[self selectedRows]];
}

- (NSIndexSet *)rowsForTracks:(NSArray<AudioTrack *> *)tracks {
    return [_model indexesOfTracks:tracks];
}

- (AudioTrack *)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes {
    return [_model forwardTrackAfterRemovingTracksAtIndexes:indexes];
}

- (void)playSelectedTrack {
    NSInteger row = [self selectedRow];
    if (row < 0) {
        return;
    }
    // doubleClick:'s two steps.
    self.currentIndex = (NSUInteger)row;
    [self play];
}

- (IBAction)showClickedTrackInFinder:(id)sender {
    [TrackCommands revealInFinder:[self clickedTargetTracks]];
}

- (IBAction)copyClickedTrackFile:(id)sender {
    [TrackCommands copyFiles:[self clickedTargetTracks]];
}

- (IBAction)copyClickedTrackName:(id)sender {
    [TrackCommands copyNames:[self clickedTargetTracks]];
}

// Asks the shell rather than mutating the model: only the shell can decide what
// the player does when the current row goes.
- (IBAction)removeClickedTrackFromPlaylist:(id)sender {
    NSArray<AudioTrack *> *tracks = [self menuOpenSurvivingTracks];
    if (tracks.count == 0 || !self.removeTracksRequestHandler) {
        return;
    }
    self.removeTracksRequestHandler(tracks);
}

// Here, not menuWillOpen:, because AppKit validates the items in between.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    NSPointerArray *captured = [NSPointerArray weakObjectsPointerArray];
    for (AudioTrack *track in [self clickedTargetTracks]) {
        [captured addPointer:(__bridge void *)track];
    }
    _menuOpenTargetTracks = captured;
}

- (NSArray<AudioTrack *> *)menuOpenSurvivingTracks {
    return [_model tracksAtIndexes:[self rowsForTracks:_menuOpenTargetTracks.allObjects]];
}

// The whole selection for a click inside it, else the clicked row alone. The
// content commands read it at action time: the playlist can be replaced while
// the menu is up.
- (NSArray<AudioTrack *> *)clickedTargetTracks {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_model.count) {
        return @[];
    }
    if ([_tableView.selectedRowIndexes containsIndex:(NSUInteger)row]) {
        return [self selectedTracks];
    }
    return @[[_model trackAtIndex:(NSUInteger)row]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"show_clicked_track_in_finder"] ||
        [menuItem.identifier isEqualToString:@"copy_clicked_track_file"] ||
        [menuItem.identifier isEqualToString:@"copy_clicked_track_name"]) {
        // A right-click on empty table area opens the menu with clickedRow -1.
        NSInteger row = _tableView.clickedRow;
        return row >= 0 && row < (NSInteger)_model.count;
    }
    if ([menuItem.identifier isEqualToString:@"remove_clicked_track_from_playlist"]) {
        // By identity, not row number: something at those rows is not proof.
        return [self menuOpenSurvivingTracks].count > 0;
    }
    return YES;
}

- (NSUInteger)count {
    return _model.count;
}

- (NSInteger)getIndexForTrack:(AudioTrack *)track {
    return [_model getIndexForTrack:track];
}

- (NSIndexSet *)indexesOfTracksWithURL:(NSURL *)url {
    return [_model indexesOfTracksWithURL:url];
}

- (BOOL)stampTracksSounding:(AudioTrack *)track usingBlock:(void (NS_NOESCAPE ^)(AudioTrack *track))stamp {
    return [_model stampTracksSounding:track usingBlock:stamp];
}

- (NSIndexSet *)replaceTracksMatchingTrack:(AudioTrack *)track withURL:(NSURL *)url {
    return [_model replaceTracksMatchingTrack:track withURL:url];
}

- (NSArray<AudioTrack *> *)removeTracksAtIndexes:(NSIndexSet *)indexes {
    return [_model removeTracksAtIndexes:indexes];
}

- (void)insertTracks:(NSArray<AudioTrack *> *)tracks atIndexes:(NSIndexSet *)indexes {
    [_model insertTracks:tracks atIndexes:indexes];
}

- (BOOL)moveTracksAtIndexes:(NSIndexSet *)sourceIndexes toIndexes:(NSIndexSet *)destinationIndexes {
    return [_model moveTracksAtIndexes:sourceIndexes toIndexes:destinationIndexes];
}

- (BOOL)isCurrentTrack:(AudioTrack *)track {
    return [_model isCurrentTrack:track];
}

- (AudioTrack *)trackForURL:(NSURL *)url {
    return [_model trackForURL:url];
}

- (void)reloadCurrentTrack {
    [self reloadTrackAtIndex:self.currentIndex];
}

- (void)reloadTrack:(AudioTrack *)track {
    NSInteger idx = [self getIndexForTrack:track];
    if (idx >= 0) {
        [self reloadTrackAtIndex:(NSUInteger)idx];
    }
}

- (void)reloadAllTracks {
    [self.tableView reloadData];
}

- (void)reloadVisibleTracks {
    NSTableView *tableView = self.tableView;
    NSRange rows = [tableView rowsInRect:tableView.visibleRect];
    NSInteger columns = tableView.numberOfColumns;
    if (rows.length == 0 || columns <= 0) {
        return;
    }
    [tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:rows]
                         columnIndexes:[NSIndexSet indexSetWithIndexesInRange:
                                 NSMakeRange(0, (NSUInteger)columns)]];
}

@end
