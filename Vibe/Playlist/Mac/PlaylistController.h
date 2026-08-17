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

// Fires as a play is STARTED, before the player has opened anything. The
// player's own events arrive only once its async open makes progress, since
// didBeginLoading is gated on the 0.5-second slow-open threshold, so without
// this the owner's header keeps describing the previous track after the row
// indicator has already moved.
//
// It hangs off `play` — the one funnel every start goes through — rather than
// off any single entry point, and that is the whole of the fix: it used to
// fire from the double-click alone, so a play begun any OTHER way (an open, a
// drop, Open Recent) kept the stale header for the full half second. On local
// files that window is invisible, which is why it survived; against a file
// provider it is half a second of the wrong title on every track you pick, and
// the cloud stress profile fails a consistency check on it every time.
@property (nonatomic, copy, nullable) void (^playWillStartHandler)(void);

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

// The gapless auto-advance's bookkeeping half: the player has already spliced
// into the next track, so advance the index and scroll without starting a
// play. Row repaint rides the currentIndexDidChange observer, as with next.
- (BOOL)advanceToNextTrackWithoutPlaying;

// The playlist-boundary predicates: the single source of truth for whether
// there is a track after or before the current one. They are shared by next
// and previous themselves, the transport buttons, menu validation, the Now
// Playing command gating in Control Center, and the end-of-playlist stop.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

- (AudioTrack * _Nullable)currentTrack;
- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;

// Points a row at a different file, returning the fresh AudioTrack now in it,
// or nil when index is out of range. Mints a new track rather than
// reassigning the old one's url: AudioTrack memoizes its cache key, and a
// track carrying the old key would file the new file's waveform and metadata
// under the old entries. Duration and detected BPM carry across — same audio.
// Playback is untouched; a caller replacing the playing row restarts it.
- (AudioTrack * _Nullable)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url;

- (BOOL)isCurrentTrack:(AudioTrack *)track;
- (AudioTrack * _Nullable)trackForURL:(NSURL *)url;

// Every row holding url — the same file can sit in the playlist more than
// once, and a caller acting on a file has to reach all of them.
- (NSIndexSet *)indexesOfTracksWithURL:(NSURL *)url;

- (void)reloadCurrentTrack;
- (void)reloadCurrentTrackPlayState;
- (void)reloadTrackAtIndex:(NSUInteger)index;
- (void)reloadTrack:(AudioTrack *)track;

// Every row, for a change that affects the whole list at once rather than one
// track's own data — the folder-artwork setting. Selection and scroll survive.
- (void)reloadAllTracks;

// The same, for the rows on screen alone. Only they have a cell view to rebuild
// — an off-screen row builds one afresh when it scrolls back in — so this is
// what a *repeated* whole-list change should use: a bulk open spanning hundreds
// of folders would otherwise pay a full reloadData per cover that lands.
- (void)reloadVisibleTracks;

// Scrolls the playing row into view. It is a no-op while the row is already
// visible.
- (void)scrollCurrentTrackToVisible;

@end

NS_ASSUME_NONNULL_END
