//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "PlaylistController.h"
#import "Playlist.h"
#import "PlaylistTableView.h"
#import "PlaylistRowView.h"
#import "EqualizerIndicatorView.h"
#import "MainMenuBuilder.h" // vends the row context menu's symbol items
#import "TrackCommands.h"
#import "VibeStrings.h"

// The reuse identifier for the custom row view. Cell views reuse their column
// identifiers, so the row view needs one of its own.
static NSString *const kPlaylistRowViewIdentifier = @"playlistRow";

// Validation for the row context menu installed in setTableView:.
@interface PlaylistController () <NSMenuItemValidation, PlaylistObserver>
@end

@implementation PlaylistController {
    // The ordered-list model, view-free; this controller is its observer and
    // maps its change notifications onto table reloads.
    Playlist *_model;
    __weak PlaylistTableView *_tableView;
    __weak NSClipView *_observedClipView;
}

- (void)dealloc {
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
    // The table gets its own menu, shadowing the window-wide one, whose "Show
    // in Finder" reveals the current track, so that a right-click on a row
    // reveals that row's track instead.
    // Menu title never drawn — a context menu shows only its items.
    // The items share their titles and SF Symbols with the main menu's, vended
    // so the symbol wiring lives in MainMenuBuilder — but they act on the
    // CLICKED row, not the current track, so they carry this controller's own
    // selectors and identifiers rather than reusing the vended copy pair.
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
    _tableView.menu = menu;

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
}

- (instancetype)initWithAudioPlayer:(AudioPlayer *)audioPlayer {
    self = [super init];
    if (self) {
        _model = [Playlist new];
        _model.observer = self;
        self.audioPlayer = audioPlayer;
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_model.count;
}

#pragma mark - Playlist observer

- (void)playlistDidReplaceAllTracks:(Playlist *)playlist {
    // A replacement resets the index to 0 without moving it, so the hook below
    // never fires for the first track of a new folder.
    [self notifyCurrentIndexDidChange];
    // reloadData keeps selection by row index, which would land a stale
    // selection wash on an unrelated row of the new playlist. The append path
    // needs no clearing: its indexes stay valid.
    [self.tableView deselectAll:nil];
    [self.tableView reloadData];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    // Insert, not reloadData: the existing rows keep their row VIEWS, so the
    // playing row keeps its marking and the selection keeps its rows rather
    // than its indexes. The model has already grown, so numberOfRows agrees.
    // No animation — an append is usually an open of hundreds of files, and
    // sliding them all in is motion nobody asked for.
    [self.tableView insertRowsAtIndexes:indexes withAnimation:NSTableViewAnimationEffectNone];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    // Row views are untouched by a cell reload, so the playing row's marking
    // survives.
    [self reloadTrackAtIndex:index];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
    [self notifyCurrentIndexDidChange];
    [self refreshRowViewPlayingStates];
    // Reload both rows: the departed row must drop its playing state and the
    // new one must show its own now, rather than after the async
    // didStartPlaying round-trip.
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

// A custom row view, which gives selection and the playing row a neutral wash
// in place of the system's accent-blue selectedContentBackgroundColor fill.
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    PlaylistRowView *rowView = [tableView makeViewWithIdentifier:kPlaylistRowViewIdentifier owner:self];
    if (!rowView) {
        rowView = [[PlaylistRowView alloc] initWithFrame:NSZeroRect];
        rowView.identifier = kPlaylistRowViewIdentifier;
    }
    rowView.playingRow = (row == (NSInteger)self.currentIndex);
    return rowView;
}

// reloadDataForRowIndexes: rebuilds cell views but keeps the row views, so
// every currentIndex change re-stamps the visible rows' playing flag here.
// Rows scrolled in later get theirs from rowViewForRow:.
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
    // The boolean can stay true while a resize clips the row away, so every
    // reconciliation also refreshes the material row intersection.
    [self updateCurrentEqualizerActivity];
}

// Structure and styling — cell construction, fonts and the column set — live
// in PlaylistTableView. This method decides content alone.
- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    AudioTrack *track = [_model trackAtIndex:(NSUInteger)row];
    BOOL isCurrentRow = (row == (NSInteger)self.currentIndex);
    NSTableCellView *view = [_tableView cellViewForColumn:tableColumn];
    if ([tableColumn.identifier isEqualToString:kPlaylistColumnNumber]) {
        EqualizerIndicatorView *eqView = [PlaylistTableView equalizerViewInCell:view];
        // Unconditional, as the iOS list does it: a reused view releases the
        // old source before it can declare demand against the new row's state.
        eqView.levelSource = self.levelSource;
        if (isCurrentRow) {
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

#pragma mark - Public API

- (AudioTrack *)currentTrack {
    return [_model currentTrack];
}

- (void)play:(NSArray<NSURL *> *)urls {
    [_model replaceAllWithURLs:urls];
    // The observer's reloadData keeps the scroll offset, but a new playlist
    // starts at the top.
    [self scrollCurrentTrackToVisible];
    [self play];
}

- (void)append:(NSArray<NSURL *> *)urls {
    // Playback and currentIndex are deliberately untouched.
    [_model appendURLs:urls];
}

- (void)play {
    AudioTrack *track = self.currentTrack;
    if (!track) {
        return;
    }
    [self.audioPlayer play:track];
    // AFTER the play is submitted, so the owner's refresh describes the track
    // that is now current; see playWillStartHandler for why every start needs
    // it and not just the double-click.
    if (self.playWillStartHandler) {
        self.playWillStartHandler();
    }
}

- (void)clear {
    [_model clear];
}

- (void)reloadTrackAtIndex:(NSUInteger)index {
    // Guard against an out-of-range index, matching
    // reloadCurrentTrackPlayState. reloadCurrentTrack fires with currentIndex
    // 0 on an empty playlist, as updateUI does at launch.
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

- (BOOL)advanceToNextTrackWithoutPlaying {
    if ([_model next]) {
        [self scrollCurrentTrackToVisible];
        return YES;
    }
    return NO;
}

// Called only on a track change, and scrollRowToVisible: no-ops while the row
// is on screen, so a user who has scrolled away keeps their position until
// then.
- (void)scrollCurrentTrackToVisible {
    if (self.currentIndex >= _model.count) {
        return;
    }
    [self.tableView scrollRowToVisible:(NSInteger)self.currentIndex];
}

- (void)doubleClick:(id)sender {
    if ([_tableView clickedRow] < 0) {
        return;
    }
    // The model's index-change notification reloads the departed and clicked
    // rows immediately, rather than after the async didStartPlaying
    // round-trip.
    self.currentIndex = (NSUInteger) [_tableView clickedRow];
    [self play];
}

// Return's counterpart of the double-click, from the Playback menu's Play
// Selected Track and TransportKeyMonitor. Both read the selection at action
// time, like the context menu's clicked row, because the playlist can be
// replaced between the press and here.

- (BOOL)hasSelectedTrack {
    NSInteger row = _tableView.selectedRow;
    return row >= 0 && row < (NSInteger)_model.count;
}

- (void)playSelectedTrack {
    if (![self hasSelectedTrack]) {
        return;
    }
    // Same two steps as doubleClick:, and for the same reason — the model's
    // index-change notification repaints the departed and chosen rows now,
    // rather than after the async didStartPlaying round-trip.
    self.currentIndex = (NSUInteger)_tableView.selectedRow;
    [self play];
}

// The clicked row's counterparts of the Edit menu's Show in Finder, Copy File
// and Copy Name, which act on the current track (MainPlayerController). Same
// three commands, different track.

- (IBAction)showClickedTrackInFinder:(id)sender {
    [TrackCommands revealInFinder:[self clickedTrack]];
}

- (IBAction)copyClickedTrackFile:(id)sender {
    [TrackCommands copyFile:[self clickedTrack]];
}

- (IBAction)copyClickedTrackName:(id)sender {
    [TrackCommands copyName:[self clickedTrack]];
}

// The row under the right-click, or nil for a click on the table's empty area
// or a row a playlist replacement has invalidated. Read at action time, not
// menu-open, because the playlist can be replaced while the menu is up.
- (AudioTrack *)clickedTrack {
    NSInteger row = _tableView.clickedRow;
    if (row < 0) {
        return nil;
    }
    return [_model trackAtIndex:(NSUInteger)row];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"show_clicked_track_in_finder"] ||
        [menuItem.identifier isEqualToString:@"copy_clicked_track_file"] ||
        [menuItem.identifier isEqualToString:@"copy_clicked_track_name"]) {
        // A right-click on the table's empty area still opens the menu, with a
        // clickedRow of -1.
        NSInteger row = _tableView.clickedRow;
        return row >= 0 && row < (NSInteger)_model.count;
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

- (AudioTrack *)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url {
    return [_model replaceTrackAtIndex:index withURL:url];
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

- (void)reloadCurrentTrackPlayState {
    NSInteger column = [self.tableView columnWithIdentifier:kPlaylistColumnNumber];
    if (column < 0 || self.currentIndex >= _model.count) {
        return;
    }
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:self.currentIndex]
                              columnIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)column]];
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
