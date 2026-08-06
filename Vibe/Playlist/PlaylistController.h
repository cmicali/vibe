//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "AudioPlayer.h"

@class PlaylistTableView;

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property NSUInteger currentIndex;

@property (weak) AudioPlayer *audioPlayer;
// Attaching the table also wires the double-click action and installs the row
// context menu. The table's construction itself lives in PlaylistTableView.
@property (weak) PlaylistTableView *tableView;

// Fires after a double-click has started a new track. The player's own events
// arrive only once its async open makes progress, since didBeginLoading is
// gated on the 0.5-second slow-open threshold. Without this the owner's header
// would keep describing the previous track after the row indicator had already
// moved.
@property (nonatomic, copy, nullable) void (^userDidChangeTrackHandler)(void);

// The artwork-derived accent for the playing row's equalizer bars. The owner
// sets it from the current track's dominant art color, and nil falls back to
// the appearance default. It is deliberately the only accented element in the
// row: the title text keeps its normal label color and the row background
// stays neutral; see PlaylistRowView.
@property (nonatomic, strong, nullable) NSColor *accentColor;

- (NSArray<AudioTrack *> *)playlist;

// Single-element access. Unlike the playlist getter it makes no defensive
// copy, so use it for one-off indexed reads on the main thread, and use
// playlist only when holding the whole list across async work. It returns nil
// when out of range.
- (AudioTrack * _Nullable)trackAtIndex:(NSUInteger)index;

- (instancetype)initWithAudioPlayer:(AudioPlayer *)player;

- (void)play;
- (void)play:(NSArray<NSURL *> *)urls;

// Adds tracks to the end without touching playback or currentIndex, whereas
// play: replaces and restarts. AppDelegate's open burst uses it.
- (void)append:(NSArray<NSURL *> *)urls;

// Empties the playlist and resets currentIndex. It does not touch the audio
// player: the caller stops playback itself.
- (void)clear;

- (BOOL)next;

- (BOOL)previous;

// The playlist-boundary predicates: the single source of truth for whether
// there is a track after or before the current one. They are shared by next
// and previous themselves, the transport buttons, menu validation, the Now
// Playing command gating in Control Center, and the end-of-playlist stop.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

- (AudioTrack * _Nullable)currentTrack;
- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;

- (BOOL)isCurrentTrack:(AudioTrack *)track;
- (AudioTrack * _Nullable)trackForURL:(NSURL *)url;

- (void)reloadCurrentTrack;
- (void)reloadCurrentTrackPlayState;
- (void)reloadTrackAtIndex:(NSUInteger)index;
- (void)reloadTrack:(AudioTrack *)track;

// Scrolls the playing row into view. It is a no-op while the row is already
// visible.
- (void)scrollCurrentTrackToVisible;

@end

NS_ASSUME_NONNULL_END
