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
    if ([tableColumn.identifier isEqualToString:@"artColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackArt" owner:self];
        NSView *gradientView = [view viewWithIdentifier:@"gradient_overlay"];
        if (!gradientView.layer) {
            gradientView.wantsLayer = YES;
            CAGradientLayer *g = [[CAGradientLayer alloc] init];
            g.colors = @[
                    (id) [NSColor colorWithRed:0 green:0 blue:0 alpha:0.85].CGColor,
                    (id) [NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
            ];
            gradientView.layer = g;
        }
        NSImage *image = track.albumArt;
        if (!image) {
            image = [NSImage imageNamed:@"record-black-1024"];
        }
        view.imageView.image = image;
    }
    else if ([tableColumn.identifier isEqualToString:@"titleColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackName" owner:self];
        if (track.hasArtistAndTitle) {
            NSMutableAttributedString *artist = [[NSMutableAttributedString alloc] initWithColor:NSColor.secondaryLabelColor];
            [artist appendString:track.artist];
            NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithColor:NSColor.labelColor];
            [title appendString:track.title];
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
            [s appendAttributedString:title];
            [s appendString:@" "];
            [s appendAttributedString:artist];
            view.textField.attributedStringValue = s;
        }
        else {
            view.textField.stringValue = track.singleLineTitle;
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"lengthColumn"]) {
        view = [tableView makeViewWithIdentifier:@"trackLength" owner:self];
        view.textField.stringValue = track.lengthString;
        view.textField.font = [Fonts fontForNumbers:view.textField.font.pointSize];
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

- (BOOL)next {
    if (self.currentIndex < _playlist.count - 1) {
        self.currentIndex += 1;
        [self play];
        return YES;
    }
    return NO;
}

- (void)doubleClick:(id)doubleClick {
    self.currentIndex = (NSUInteger) [_tableView clickedRow];
    [self play];
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

@end
