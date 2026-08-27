//
//  PlaylistController.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "AudioTrack.h"
#import "AudioPlayer.h"
#import "EqualizerLevelSource.h"

@class PlaylistTableView;

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistController : NSObject <NSTableViewDataSource, NSTableViewDelegate,
                                          AudioTrackIndexedSource>

@property NSUInteger currentIndex;

@property (weak) AudioPlayer *audioPlayer;

// Handed to every row's EqualizerIndicatorView so the playing row can consume
// the window controller's coherent audio snapshots. The controller owns this
// source because it also reconciles the producer with window occlusion.
@property (weak, nullable) id<EqualizerLevelSource> levelSource;
// The two shell-owned inputs the playing-row indicator cannot derive from the
// audio snapshot itself. `equalizerSurfaceVisible` is the window-level gate;
// the controller combines it with the row's actual intersection with the
// scroll clip before handing it to the view.
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerSurfaceVisible;
// Attaching the table also wires the double-click action and installs the row
// context menu. The table's construction itself lives in PlaylistTableView.
@property (weak) PlaylistTableView *tableView;

// Fires as a play is STARTED, before the player has opened anything. The
// player's own events arrive only once its async open makes progress, since
// didBeginLoading is gated on the 0.5-second slow-open threshold, so without
// this the owner's header keeps describing the previous track after the row
// indicator has already moved.
//
// It hangs off `play`, the one funnel every start goes through, so a play
// begun any other way — an open, a drop, Open Recent — raises it exactly as a
// double-click does.
@property (nonatomic, copy, nullable) void (^playWillStartHandler)(void);

// Fires whenever currentIndex comes to name a different track — every play,
// skip and gapless auto-advance, plus a replacement, which resets the index to
// 0 without moving it and so never trips the index-change path. This is the
// mac's one current-index funnel, and it exists for the work that must follow
// the cursor rather than the playback state: the metadata sweep's cloud-lane
// ranking (AudioTrackMetadataCache.setNeighborhoodAroundIndex:inTracks:). Row
// repainting is NOT its business — that rides the observer directly.
@property (nonatomic, copy, nullable) void (^currentIndexDidChangeHandler)(void);

// Fires once after every completed row move — drag, undo or redo — with the
// model, the table and the cursor already final, carrying the move it
// describes. The shell's one follow-up edge for a reorder: register the
// inverse on the undo stack, re-park the gapless successor, re-rank the
// metadata neighborhood, refresh transport UI. A move never enters a play
// funnel, so this is deliberately not currentIndexDidChangeHandler — one
// structural edit, one edge.
@property (nonatomic, copy, nullable) void (^playlistOrderDidChangeHandler)(NSIndexSet *sourceIndexes, NSIndexSet *destinationIndexes);

// Staleness counter for work stamped against the current row set — the
// shell's removal-undo and reorder-undo registrations. It follows the model's
// own replace-all announcement (playlistDidReplaceAllTracks:, which both
// replaceAllWithURLs: and clear fire), so ANY path that replaces the list
// bumps it — there is no call-site discipline to forget. Appends, swaps,
// removals and inserts leave it alone: they never invalidate a stamped row
// number wholesale, because a stamped registration only runs after every
// undoable edit made since it has itself been unwound (NSUndoManager is
// LIFO), which restores the coordinates it was stamped in.
@property (nonatomic, readonly) NSUInteger structureGeneration;

// A row-menu removal request. The shell resolves the exact objects to their
// live rows and owns the transport consequences; this controller never
// removes them.
@property (nonatomic, copy, nullable) void (^removeTracksRequestHandler)(NSArray<AudioTrack *> *tracks);

- (NSArray<AudioTrack *> *)playlist;

// Single-element access. Unlike the playlist getter it makes no defensive
// copy, so use it for one-off indexed reads on the main thread, and use
// playlist only when holding the whole list across async work. It returns nil
// when out of range.
- (AudioTrack * _Nullable)trackAtIndex:(NSUInteger)index;

- (instancetype)initWithAudioPlayer:(AudioPlayer *)player;

- (void)play;
- (void)play:(NSArray<NSURL *> *)urls;

// The parked twin of play: the current track is submitted at its start with
// nothing rendering until playPause. It shares play's funnel, so
// playWillStartHandler fires after submission exactly as an ordinary start's
// does — that hook is what repaints the header through a slow open, and having
// one funnel is why no caller reaches the player directly.
- (void)playStartPaused:(BOOL)startPaused;

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

// Takes the rows out of the list, returning the exact objects removed in
// ascending row order, or nil when the set is empty or out of range. Survivors
// close the gaps and the cursor follows them; the files are untouched.
//
// It performs the model mutation and nothing else, so call it ONLY from the
// shell's removal funnel, which has already decided what the player must do
// about it. Everything a user gesture reaches goes through
// removeTracksRequestHandler instead.
- (NSArray<AudioTrack *> * _Nullable)removeTracksAtIndexes:(NSIndexSet *)indexes;

// The removal's inverse, same pass-through contract: the model mutation and
// nothing else, so call it ONLY from the shell's undo of a removal, which owns
// what the player and the metadata sweep must do about the restored rows.
- (void)insertTracks:(NSArray<AudioTrack *> *)tracks atIndexes:(NSIndexSet *)indexes;

// A move's own inverse, for the shell's undo of a reorder: the model mutation
// and nothing else — the observer reconciles the table and re-raises
// playlistOrderDidChangeHandler, which is what re-registers the opposite
// direction while the undo manager unwinds. The drag itself never calls this;
// it lands through the table's acceptDrop.
- (BOOL)moveTracksAtIndexes:(NSIndexSet *)sourceIndexes toIndexes:(NSIndexSet *)destinationIndexes;

// The keyboard selection, which is not the playing row: the arrow keys move
// it, and it stays put while playback moves currentIndex. Empty when nothing
// is selected or a playlist replacement has outrun the selection. The
// selection primitive — selectedRow and selectedTracks derive from it.
- (NSIndexSet *)selectedRows;

// The topmost selected row, or -1 with no selection — so >= 0 is also the one
// "is there a selection" predicate.
- (NSInteger)selectedRow;

// Every selected row's track, in row order. Empty when nothing is selected.
- (NSArray<AudioTrack *> *)selectedTracks;

// The live rows the exact objects occupy now, departed ones dropped: the
// identity-resolution rule every group gesture rests on, in its one home. The
// drag session and the shell's removal funnel both resolve through this.
- (NSIndexSet *)rowsForTracks:(NSArray<AudioTrack *> *)tracks;

// Plays the selected row, exactly as a double-click on it does. A no-op with
// no selection.
- (void)playSelectedTrack;

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

// Marks the visible rows for redraw — PlaylistRowView reads its themed fill
// per draw, so a row-fill color change needs only this, not a cell rebuild.
- (void)redrawVisibleRowFills;

@end

NS_ASSUME_NONNULL_END
