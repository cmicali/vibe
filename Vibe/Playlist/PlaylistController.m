//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "EqualizerIndicatorView.h"

// Validation for the row context menu installed in setTableView:.
@interface PlaylistController () <NSMenuItemValidation>
@end

@implementation PlaylistController {
    NSMutableArray<AudioTrack *> *_playlist;
    // Track → row for reloadTrack:. didLoadMetadata fires it once per track
    // during the metadata sweep — a linear scan would make that sweep O(n²)
    // in playlist size on the main thread. Rebuilt whenever the playlist is
    // replaced (play:) and extended by append:; rows never move otherwise,
    // so the recorded indexes stay valid.
    NSMapTable<AudioTrack *, NSNumber *> *_trackIndexes;
    __weak PlaylistTableView *_tableView;
}

- (NSArray<AudioTrack *> *)playlist {
    // Defensive shallow copy: callers iterate the result across async work
    // while append: can extend the live array on the main thread.
    return [_playlist copy];
}

- (AudioTrack *)trackAtIndex:(NSUInteger)index {
    return index < _playlist.count ? _playlist[index] : nil;
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
    // The table gets its own menu (shadowing the window-wide one, whose
    // "Show in Finder" reveals the CURRENT track) so a right-click on a row
    // reveals THAT row's track.
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Playlist Menu"];
    NSMenuItem *showRowInFinder = [[NSMenuItem alloc] initWithTitle:@"Show in Finder"
                                                             action:@selector(showClickedTrackInFinder:)
                                                      keyEquivalent:@""];
    showRowInFinder.identifier = @"show_clicked_track_in_finder";
    showRowInFinder.target = self;
    [menu addItem:showRowInFinder];
    _tableView.menu = menu;
}

- (instancetype)initWithAudioPlayer:(AudioPlayer *)audioPlayer {
    self = [super init];
    if (self) {
        _playlist = [NSMutableArray new];
        _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
        self.currentIndex = 0;
        self.audioPlayer = audioPlayer;
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _playlist.count;
}

#pragma mark - Cell population

// Structure and styling live in PlaylistTableView (cell construction, fonts,
// column set); this method only decides content.
- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    AudioTrack *track = _playlist[row];
    NSTableCellView *view = [_tableView cellViewForColumn:tableColumn];
    if ([tableColumn.identifier isEqualToString:@"numColumn"]) {
        EqualizerIndicatorView *eqView = [PlaylistTableView equalizerViewInCell:view];
        if (row == self.currentIndex) {
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

- (AudioTrack *)currentTrack {
    if (self.currentIndex < _playlist.count) {
        return _playlist[self.currentIndex];
    }
    return nil;
}

- (void)play:(NSArray<NSURL *> *)urls {
    _playlist = [NSMutableArray new];
    _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
    [self addTracksForURLs:urls];
    self.currentIndex = 0;
    [self.tableView reloadData];
    // reloadData keeps the scroll offset; a new playlist starts at the top.
    [self scrollCurrentTrackToVisible];
    [self play];
}

- (void)append:(NSArray<NSURL *> *)urls {
    if (!urls.count) {
        return;
    }
    [self addTracksForURLs:urls];
    // Whole-table reload like play: — only visible rows render either way.
    // Playback and currentIndex are deliberately untouched.
    [self.tableView reloadData];
}

// Appends tracks for urls to _playlist, recording each one's row.
- (void)addTracksForURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        AudioTrack *track = [AudioTrack withURL:url];
        [_trackIndexes setObject:@(_playlist.count) forKey:track];
        [_playlist addObject:track];
    }
}

- (void)play {
    AudioTrack *track = self.currentTrack;
    if (track) {
        [self.audioPlayer play:track];
    }
}

- (void)clear {
    _playlist = [NSMutableArray new];
    _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
    self.currentIndex = 0;
    [self.tableView reloadData];
}

- (void)reloadTrackAtIndex:(NSUInteger)index {
    // Guard out-of-range (matches reloadCurrentTrackPlayState): reloadCurrentTrack
    // fires with currentIndex 0 on an empty playlist (e.g. updateUI at launch),
    // and doubleClick passes a previous index that a playlist replacement may
    // have invalidated.
    if (index >= _playlist.count) {
        return;
    }
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (void)reloadTrackInRange:(NSRange)range {
    // Clamp against the table like reloadTrackAtIndex: guards its index —
    // next/previous reload a two-row window that can extend past the end.
    range = NSIntersectionRange(range, NSMakeRange(0, (NSUInteger)self.tableView.numberOfRows));
    if (range.length == 0) {
        return;
    }
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:range] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (BOOL)hasNextTrack {
    return self.currentIndex + 1 < _playlist.count;
}

- (BOOL)hasPreviousTrack {
    return _playlist.count > 0 && self.currentIndex > 0;
}

- (BOOL)next {
    if (self.hasNextTrack) {
        self.currentIndex += 1;
        [self reloadTrackInRange:NSMakeRange(self.currentIndex - 1, 2)];
        [self scrollCurrentTrackToVisible];
        [self play];
        return YES;
    }
    return NO;
}

- (BOOL)previous {
    if (self.hasPreviousTrack) {
        self.currentIndex -= 1;
        [self reloadTrackInRange:NSMakeRange(self.currentIndex, 2)];
        [self scrollCurrentTrackToVisible];
        [self play];
        return YES;
    }
    return NO;
}

// Called only on track changes, and scrollRowToVisible: no-ops while the row
// is on screen — a user who scrolled away keeps their position until then.
- (void)scrollCurrentTrackToVisible {
    if (self.currentIndex >= _playlist.count) {
        return;
    }
    [self.tableView scrollRowToVisible:(NSInteger)self.currentIndex];
}

- (void)doubleClick:(id)sender {
    if ([_tableView clickedRow] < 0) {
        return;
    }
    NSUInteger previousIndex = self.currentIndex;
    self.currentIndex = (NSUInteger) [_tableView clickedRow];
    [self play];
    // Reload both rows: the clicked row must show its playing state now, not
    // after the async didStartPlaying round-trip.
    [self reloadTrackAtIndex:previousIndex];
    [self reloadTrackAtIndex:self.currentIndex];
    if (self.userDidChangeTrackHandler) {
        self.userDidChangeTrackHandler();
    }
}

// The row context menu's action. clickedRow is read at action time, not
// captured at menu-open — the playlist can be replaced while the menu is up,
// so the row is re-bounds-checked here (validation already disabled the item
// for a click outside the rows).
- (IBAction)showClickedTrackInFinder:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_playlist.count) {
        return;
    }
    NSURL *url = _playlist[(NSUInteger)row].url;
    if (url) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem.identifier isEqualToString:@"show_clicked_track_in_finder"]) {
        // Right-click on the table's empty area still opens the menu, with
        // clickedRow -1.
        NSInteger row = _tableView.clickedRow;
        return row >= 0 && row < (NSInteger)_playlist.count;
    }
    return YES;
}

- (NSUInteger)count {
    return _playlist.count;
}

- (NSInteger)getIndexForTrack:(AudioTrack *)track {
    // AudioTrack uses NSObject's identity hash/isEqual, so this is an
    // identity lookup.
    NSNumber *index = track ? [_trackIndexes objectForKey:track] : nil;
    return index ? index.integerValue : -1;
}

- (BOOL)isCurrentTrack:(AudioTrack *)track {
    return self.currentTrack == track;
}

- (AudioTrack *)trackForURL:(NSURL *)url {
    if (!url) {
        return nil;
    }
    for (AudioTrack *track in _playlist) {
        if ([track.url isEqual:url]) {
            return track;
        }
    }
    return nil;
}

- (void)reloadCurrentTrack {
    [self reloadTrackAtIndex:self.currentIndex];
}

- (void)reloadCurrentTrackPlayState {
    NSInteger column = [self.tableView columnWithIdentifier:@"numColumn"];
    if (column < 0 || self.currentIndex >= _playlist.count) {
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
