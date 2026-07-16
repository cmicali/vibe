//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistManager : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property NSUInteger currentIndex;

@property (weak) AudioPlayer *audioPlayer;
@property (weak) NSTableView *tableView;

- (NSArray<AudioTrack *> *)playlist;

- (id)initWithAudioPlayer:(AudioPlayer *)player;

- (void)play;
- (void)play:(NSArray<NSURL *> *)urls;
- (BOOL)next;

- (BOOL)previous;

// Playlist-boundary predicates — the single source of truth for "is there a
// track after/before the current one", shared by next/previous themselves,
// the transport buttons, menu validation, Now Playing (Control Center)
// command gating, and the end-of-playlist stop.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

- (AudioTrack * _Nullable)currentTrack;
- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;

- (void)reloadCurrentTrack;
- (void)reloadCurrentTrackPlayState;
- (void)reloadTrackAtIndex:(NSUInteger)index;
- (void)reloadTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
