//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "PlaylistController.h"
#import "Playlist.h"
#import "PlaylistTableView.h"
#import "PlaylistRowView.h"
#import "EqualizerIndicatorView.h"
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
    _tableView = tableView;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(doubleClick:)];
    // The table gets its own menu, shadowing the window-wide one, whose "Show
    // in Finder" reveals the current track, so that a right-click on a row
    // reveals that row's track instead.
    // Menu title never drawn — a context menu shows only its items.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:VibeNotLocalized(@"Playlist Menu")];
    NSMenuItem *showRowInFinder = [[NSMenuItem alloc] initWithTitle:STR_MENU_SHOW_IN_FINDER
                                                             action:@selector(showClickedTrackInFinder:)
                                                      keyEquivalent:@""];
    showRowInFinder.identifier = @"show_clicked_track_in_finder";
    showRowInFinder.target = self;
    showRowInFinder.image = [NSImage imageWithSystemSymbolName:@"folder"
                                      accessibilityDescription:showRowInFinder.title];
    [menu addItem:showRowInFinder];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *copyRowName = [[NSMenuItem alloc] initWithTitle:STR_MENU_EDIT_COPY_NAME
                                                         action:@selector(copyClickedTrackName:)
                                                  keyEquivalent:@""];
    copyRowName.identifier = @"copy_clicked_track_name";
    copyRowName.target = self;
    copyRowName.image = [NSImage imageWithSystemSymbolName:@"textformat"
                                  accessibilityDescription:copyRowName.title];
    [menu addItem:copyRowName];
    NSMenuItem *copyRowFile = [[NSMenuItem alloc] initWithTitle:STR_MENU_EDIT_COPY_FILE
                                                         action:@selector(copyClickedTrackFile:)
                                                  keyEquivalent:@""];
    copyRowFile.identifier = @"copy_clicked_track_file";
    copyRowFile.target = self;
    copyRowFile.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                  accessibilityDescription:copyRowFile.title];
    [menu addItem:copyRowFile];
    _tableView.menu = menu;
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
    [self.tableView reloadData];
}

- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes {
    // A whole-table reload, since only the visible rows render either way.
    [self.tableView reloadData];
}

- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index {
    // Row views are untouched by a cell reload, so the playing row's marking
    // survives.
    [self reloadTrackAtIndex:index];
}

- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex {
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

// Structure and styling — cell construction, fonts and the column set — live
// in PlaylistTableView. This method decides content alone.
- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    AudioTrack *track = [_model trackAtIndex:(NSUInteger)row];
    BOOL isCurrentRow = (row == (NSInteger)self.currentIndex);
    NSTableCellView *view = [_tableView cellViewForColumn:tableColumn];
    if ([tableColumn.identifier isEqualToString:@"numColumn"]) {
        EqualizerIndicatorView *eqView = [PlaylistTableView equalizerViewInCell:view];
        // Reset on every population, because cells are reused across rows.
        eqView.barColor = isCurrentRow ? self.accentColor : nil;
        if (isCurrentRow) {
            view.textField.hidden = YES;
            eqView.hidden = NO;
            eqView.animating = self.audioPlayer.isPlaying;
        }
        else {
            view.textField.hidden = NO;
            eqView.hidden = YES;
            eqView.animating = NO;
            view.textField.attributedStringValue = [PlaylistTableView numberCellString:(NSUInteger)row + 1];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"artColumn"]) {
        NSImage *image = track.thumbnailAlbumArt;
        if (!image) {
            image = [NSImage imageNamed:@"record-bg"];
        }
        view.imageView.image = image;
    }
    else if ([tableColumn.identifier isEqualToString:@"titleColumn"]) {
        view.textField.attributedStringValue = [PlaylistTableView titleCellStringForTrack:track];
    }
    else if ([tableColumn.identifier isEqualToString:@"lengthColumn"]) {
        view.textField.attributedStringValue = [PlaylistTableView durationCellString:track.durationString];
    }

    return view;
}

#pragma mark - Public API

- (void)setAccentColor:(NSColor *)accentColor {
    if (_accentColor == accentColor || [_accentColor isEqual:accentColor]) {
        return;
    }
    _accentColor = accentColor;
    // Only the playing row renders the accent, and only on its equalizer bars:
    // the title text deliberately keeps the normal label color.
    [self reloadCurrentTrack];
}

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
    if (track) {
        [self.audioPlayer play:track];
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
    if (self.userDidChangeTrackHandler) {
        self.userDidChangeTrackHandler();
    }
}

- (IBAction)showClickedTrackInFinder:(id)sender {
    NSURL *url = [self clickedTrack].url;
    if (url) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

// The clicked row's counterparts of the Edit menu's Copy File / Copy Name,
// which act on the current track (MainPlayerController).
- (IBAction)copyClickedTrackFile:(id)sender {
    NSURL *url = [self clickedTrack].url;
    if (url) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard writeObjects:@[url]];
    }
}

- (IBAction)copyClickedTrackName:(id)sender {
    NSString *name = [self clickedTrack].singleLineTitle;
    if (name.length) {
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        [pasteboard writeObjects:@[name]];
    }
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
    NSInteger column = [self.tableView columnWithIdentifier:@"numColumn"];
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

@end
