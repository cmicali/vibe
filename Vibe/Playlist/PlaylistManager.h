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

// Fired after a double-click starts a new track. The player's own events
// arrive only once its async open makes progress (didBeginLoading is gated on
// the 0.5 s slow-open threshold), so without this the owner's header keeps
// describing the previous track after the row indicator has already moved.
@property (nonatomic, copy, nullable) void (^userDidChangeTrackHandler)(void);

- (NSArray<AudioTrack *> *)playlist;

// Single-element access. Unlike the playlist getter, no defensive copy — use
// this for one-off indexed reads on the main thread; use playlist only when
// holding the whole list across async work. Returns nil out of range.
- (AudioTrack * _Nullable)trackAtIndex:(NSUInteger)index;

- (instancetype)initWithAudioPlayer:(AudioPlayer *)player;

- (void)play;
- (void)play:(NSArray<NSURL *> *)urls;

// Adds tracks to the end without touching playback or currentIndex (play:
// replaces and restarts). Used by AppDelegate's open burst.
- (void)append:(NSArray<NSURL *> *)urls;

// Empties the playlist and resets currentIndex. Does not touch the audio
// player — the caller stops playback itself.
- (void)clear;

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

// Scrolls the playing row into view; no-op while it is already visible.
- (void)scrollCurrentTrackToVisible;

@end

NS_ASSUME_NONNULL_END
