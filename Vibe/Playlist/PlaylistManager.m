//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "PlaylistManager.h"
#import "NSMutableAttributedString+Util.h"
#import "Fonts.h"
#import "NSView+DarkMode.h"

@implementation PlaylistManager {
    NSMutableArray<AudioTrack *> *_playlist;
    __weak NSTableView *_tableView;
    NSImage *_imageEqWhite;
    NSImage *_imageEqBlack;
}

- (NSArray<AudioTrack *> *)playlist {
    return _playlist;
}

- (NSTableView *)tableView {
    return _tableView;
}

- (void)setTableView:(NSTableView *)tableView {
    _tableView = tableView;
    [_tableView setTarget:self];
    [_tableView setDoubleAction:@selector(doubleClick:)];
}

- (id)initWithAudioPlayer:(AudioPlayer *)audioPlayer {
    self = [super init];
    if (self) {
        _playlist = [NSMutableArray new];
        self.currentIndex = 0;
        self.audioPlayer = audioPlayer;
        _imageEqBlack = [NSImage imageNamed:@"equi-black.gif"];
        _imageEqWhite = [NSImage imageNamed:@"equi-white.gif"];
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _playlist.count;
}

static NSDictionary *numColumnAttributes;
static NSDictionary *lengthColumnAttributes;
static NSDictionary *titleAttributes;
static NSDictionary *artistAttributes;

static void ensureCellAttributes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableParagraphStyle *center = [[NSParagraphStyle new] mutableCopy];
        center.alignment = NSTextAlignmentCenter;
        NSMutableParagraphStyle *left = [[NSParagraphStyle new] mutableCopy];
        left.alignment = NSTextAlignmentLeft;
        NSMutableParagraphStyle *right = [[NSParagraphStyle new] mutableCopy];
        right.alignment = NSTextAlignmentRight;
        numColumnAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-1.5),
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        lengthColumnAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-1.0),
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        titleAttributes = @{
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts font:14],
        };
        artistAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts font:14],
        };
    });
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    ensureCellAttributes();
    AudioTrack *track = _playlist[row];
    NSTableCellView *view;
    if ([tableColumn.identifier isEqualToString:@"numColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackNum" owner:self];
        if (row == self.currentIndex) {
            view.textField.hidden = YES;
            view.imageView.hidden = NO;
            view.imageView.animates = self.audioPlayer.isPlaying;
            view.imageView.image = view.isDark ? _imageEqWhite : _imageEqBlack;
        }
        else {
            view.textField.hidden = NO;
            view.imageView.hidden = YES;
            view.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld", (long)row+1]
                                                                                   attributes:numColumnAttributes];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"artColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackArt" owner:self];
        NSImage *image = track.thumbnailAlbumArt;
        if (!image) {
            image = [NSImage imageNamed:@"record-bg"];
        }
        view.imageView.image = image;
    }
    else if ([tableColumn.identifier isEqualToString:@"titleColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackName" owner:self];
        if (track.hasArtistAndTitle) {
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[track.title stringByAppendingString:@" "]
                                                                                  attributes:titleAttributes];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:track.artist
                                                                      attributes:artistAttributes]];
            view.textField.attributedStringValue = s;
        }
        else {
            view.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:track.singleLineTitle
                                                                                    attributes:artistAttributes];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"lengthColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackLength" owner:self];
        view.textField.attributedStringValue = [[NSAttributedString alloc] initWithString:track.durationString
                                                                                attributes:lengthColumnAttributes];
    }

    return view;
}

- (AudioTrack *)currentTrack {
    if (self.currentIndex < _playlist.count) {
        return _playlist[self.currentIndex];
    }
    return nil;
}

- (void)play:(NSArray<NSURL *> *)urls {
    _playlist = [NSMutableArray new];
    for (NSURL *url in urls) {
        [_playlist addObject:[AudioTrack withURL:url]];
    }
    self.currentIndex = 0;
    [self.tableView reloadData];
    [self play];
}

- (void)play {
    AudioTrack *track = self.currentTrack;
    if (track) {
        [self.audioPlayer play:track];
    }
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
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:range] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (BOOL)next {
    if (_playlist.count > 0 && self.currentIndex < _playlist.count - 1) {
        self.currentIndex += 1;
        [self reloadTrackInRange:NSMakeRange(self.currentIndex - 1, 2)];
        [self play];
        return YES;
    }
    return NO;
}

- (BOOL)previous {
    if (self.currentIndex > 0) {
        self.currentIndex -= 1;        
        [self reloadTrackInRange:NSMakeRange(self.currentIndex, 2)];
        [self play];
        return YES;
    }
    return NO;
}

- (void)doubleClick:(id)doubleClick {
    if ([_tableView clickedRow] < 0) {
        return;
    }
    NSUInteger previousIndex = self.currentIndex;
    self.currentIndex = (NSUInteger) [_tableView clickedRow];
    [self play];
    [self reloadTrackAtIndex:previousIndex];
}

- (NSUInteger)count {
    return _playlist.count;
}

- (NSInteger)getIndexForTrack:(AudioTrack *)track {
    for(NSUInteger i = 0; i < _playlist.count; i++) {
        if (_playlist[i] == track) {
            return i;
        }
    }
    return -1;
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
