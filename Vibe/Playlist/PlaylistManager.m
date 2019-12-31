//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import "PlaylistManager.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "PlaylistTextCell.h"
#import "NSMutableAttributedString+Util.h"
#import "NSView+Util.h"
#import "Fonts.h"

@implementation PlaylistManager {
    NSMutableArray<AudioTrack *> *_playlist;
    __weak NSTableView *_tableView;
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
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _playlist.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(nullable NSTableColumn *)tableColumn row:(NSInteger)row {
    AudioTrack *track = _playlist[row];
    NSTableCellView *view;
    if ([tableColumn.identifier isEqualToString:@"numColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackNum" owner:self];
        if (row == self.currentIndex) {
            view.textField.hidden = YES;
            view.imageView.hidden = NO;
            view.imageView.animates = self.audioPlayer.isPlaying;
        }
        else {
            view.textField.hidden = NO;
            view.imageView.hidden = YES;
            view.textField.attributedStringValue = [Fonts stringForNumbers:[NSString stringWithFormat:@"%ld", (long)row+1]
                                                                     color:NSColor.secondaryLabelColor
                                                                      size:12
                                                                 alignment:NSTextAlignmentCenter
                                                                   kerning:-1.5];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"artColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackArt" owner:self];
        NSImage *image = track.albumArt;
        if (!image) {
            image = [NSImage imageNamed:@"record-black-1024"];
        }
        view.imageView.image = image;
    }
    else if ([tableColumn.identifier isEqualToString:@"titleColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackName" owner:self];
        if (track.hasArtistAndTitle) {
            NSMutableAttributedString *artist = [Fonts string:track.artist
                                                        color:NSColor.secondaryLabelColor
                                                         size:14];
            NSMutableAttributedString *title = [Fonts string:track.title
                                                       color:NSColor.labelColor
                                                        size:14];
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
            [s appendAttributedString:title];
            [s appendString:@" "];
            [s appendAttributedString:artist];
            view.textField.attributedStringValue = s;
        }
        else {
            view.textField.attributedStringValue = [Fonts string:track.singleLineTitle
                                                           color:NSColor.secondaryLabelColor
                                                            size:14];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"lengthColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackLength" owner:self];
        view.textField.attributedStringValue = [Fonts stringForNumbers:track.durationString
                                                                 color:NSColor.secondaryLabelColor
                                                                  size:12
                                                             alignment:NSTextAlignmentRight
                                                               kerning:-1.0
        ];
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
    _currentIndex = 0;
    self.currentIndex = 0;
    [self.tableView reloadData];
    [self play];
    [self.audioPlayer loadMetadata:_playlist];
}

- (void)play {
    if (self.currentIndex < _playlist.count) {
        [self.audioPlayer play:_playlist[self.currentIndex]];
        [self reloadTrackAtIndex:self.currentIndex];
    }
}

- (void)reloadTrackAtIndex:(NSUInteger)index {
    [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tableView.numberOfColumns)]];
}

- (BOOL)next {
    if (self.currentIndex < _playlist.count - 1) {
        self.currentIndex += 1;
        [self reloadTrackAtIndex:self.currentIndex - 1];
        [self play];
        return YES;
    }
    return NO;
}

- (void)doubleClick:(id)doubleClick {
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

- (void)reloadTrack:(AudioTrack *)track {
    NSInteger idx = [self getIndexForTrack:track];
    if (idx >= 0) {
        [self reloadTrackAtIndex:(NSUInteger)idx];
    }
}

@end
