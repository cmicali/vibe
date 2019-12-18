//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "PlaylistManager.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"


@implementation PlaylistManager {
    NSMutableArray<AudioTrack *> *_playlist;
}

- (id)initWithAudioPlayer:(BASSAudioPlayer *)audioPlayer {
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
    NSTableCellView *view = [tableView makeViewWithIdentifier:@"trackName" owner:self];
    view.textField.stringValue = _playlist[row].title;
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

@end
