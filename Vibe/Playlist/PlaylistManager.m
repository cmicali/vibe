//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import "PlaylistManager.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "PlaylistTextCell.h"

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
    NSString *key = @"trackArt";
    if ([tableColumn.identifier isEqualToString:@"artColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackArt" owner:self];
        NSImage *image = track.albumArt;
        if (!image) {
            image = [NSImage imageNamed:@"record-black-1024"];
        }
        view.imageView.image = image;
    }
    else if ([tableColumn.identifier isEqualToString:@"titleColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackName" owner:self];
        view.textField.stringValue = track.singleLineTitle;

//        view.textField.wantsLayer = YES;
//        view.textField.layer.opacity = 0.6;
//        view.textField.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
    else if ([tableColumn.identifier isEqualToString:@"lengthColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackLength" owner:self];
        view.textField.stringValue = @"";
    }

    return view;
}

- (AudioTrack *)currentTrack {
    if (self.currentIndex < _playlist.count) {
        return _playlist[self.currentIndex];
    }
    else {
        return [AudioTrack empty];
    }
}

- (void)reset:(NSArray<NSURL *> *)urls {
    _playlist = [NSMutableArray new];
    for (NSURL *url in urls) {
        [_playlist addObject:[AudioTrack withURL:url]];
    }
    self.currentIndex = 0;
    [self play];
    [self.audioPlayer loadMetadata:_playlist];
}

- (void)play {
    if (self.currentIndex < _playlist.count) {
        [self.audioPlayer play:_playlist[self.currentIndex]];
    }
}

- (void)next {
    if (self.currentIndex < _playlist.count - 1) {
        self.currentIndex += 1;
        [self play];
    }
}

- (void)doubleClick:(id)doubleClick {
    self.currentIndex =  [_tableView clickedRow];
    [self play];
}

- (NSUInteger)count {
    return _playlist.count;
}
@end
