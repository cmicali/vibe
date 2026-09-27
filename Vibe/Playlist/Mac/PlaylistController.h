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

// Handed to every row's EqualizerIndicatorView.
@property (weak, nullable) id<EqualizerLevelSource> levelSource;
// Shell-owned inputs. equalizerSurfaceVisible is the window-level gate; the
// controller ANDs it with the row's real intersection with the scroll clip.
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerSurfaceVisible;
// Attaching also wires double-click, the drag masks and the row menu.
@property (weak) PlaylistTableView *tableView;

// Fires as a play is submitted, before the player has opened anything: its
// didBeginLoading waits out a 0.5 s slow-open grace, and until then the
// header would describe the previous track. Every start, parked or not,
// raises it.
@property (nonatomic, copy, nullable) void (^playWillStartHandler)(void);

// The mac's one current-index funnel: every play, skip, gapless advance and
// replacement, never a structural edit. For work that follows the cursor —
// the metadata sweep's cloud-lane ranking — not row repainting.
@property (nonatomic, copy, nullable) void (^currentIndexDidChangeHandler)(void);

// Fires once per completed move — drag, undo or redo — with model, table and
// cursor final: the shell's one reorder follow-up (undo registration,
// successor re-park, neighborhood, transport UI).
@property (nonatomic, copy, nullable) void (^playlistOrderDidChangeHandler)(NSIndexSet *sourceIndexes, NSIndexSet *destinationIndexes);

// Stamps the shell's removal- and reorder-undo registrations. Bumped by any
// replacement or clear, with no call-site discipline. In-place edits leave
// it: NSUndoManager is LIFO, so a stamped registration runs only after every
// later edit is unwound, restoring its coordinates.
@property (nonatomic, readonly) NSUInteger structureGeneration;

// A row-menu removal of exact objects; the shell removes them and owns the
// transport consequences.
@property (nonatomic, copy, nullable) void (^removeTracksRequestHandler)(NSArray<AudioTrack *> *tracks);

- (NSArray<AudioTrack *> *)playlist;

// nil when out of range. No copy: for one-off main-thread reads; hold
// playlist across async work.
- (AudioTrack * _Nullable)trackAtIndex:(NSUInteger)index;

- (instancetype)initWithAudioPlayer:(AudioPlayer *)player;

- (void)play;

// Replaces the list and lands the cursor on index (out of range: row 0), then
// scrolls it into view. Opens nothing: the shell follows with play or
// playStartPaused:.
- (void)loadURLs:(NSArray<NSURL *> *)urls selectingIndex:(NSUInteger)index;

// The parked twin of play: nothing renders until playPause. The one start
// funnel; no caller reaches the player directly.
- (void)playStartPaused:(BOOL)startPaused;

// Adds tracks to the end without touching playback or currentIndex.
- (void)append:(NSArray<NSURL *> *)urls;

// Does not touch the player: the caller stops playback.
- (void)clear;

- (BOOL)next;

- (BOOL)previous;

// The gapless advance's bookkeeping: the player has already spliced into the
// next track. Success scrolls without starting a play; a stale boundary
// changes nothing.
- (BOOL)advanceFromTrack:(AudioTrack *)finishedTrack toTrack:(AudioTrack *)startedTrack;

- (nullable AudioTrack *)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes;

// The single source of truth for the playlist boundary.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

- (AudioTrack * _Nullable)currentTrack;
- (NSUInteger)count;

- (NSInteger)getIndexForTrack:(AudioTrack *)track;

// The convert swap: every row still holding this file gets a fresh
// AudioTrack. Playback is untouched; the shell restarts a replaced playing row.
- (NSIndexSet *)replaceTracksMatchingTrack:(AudioTrack *)track withURL:(NSURL *)url;

// The model mutation alone (Playlist.h): call it ONLY from the shell's removal
// funnel. A user gesture goes through removeTracksRequestHandler.
- (NSArray<AudioTrack *> * _Nullable)removeTracksAtIndexes:(NSIndexSet *)indexes;

// The model mutation alone: call it ONLY from the shell's removal undo.
- (void)insertTracks:(NSArray<AudioTrack *> *)tracks atIndexes:(NSIndexSet *)indexes;

// For the shell's reorder undo alone; the drag lands through acceptDrop. The
// observer re-raises playlistOrderDidChangeHandler, which re-registers the
// opposite direction.
- (BOOL)moveTracksAtIndexes:(NSIndexSet *)sourceIndexes toIndexes:(NSIndexSet *)destinationIndexes;

// The selection, not the playing row, filtered to the model's range.
- (NSIndexSet *)selectedRows;

// The topmost selected row, or -1.
- (NSInteger)selectedRow;

// In row order.
- (NSArray<AudioTrack *> *)selectedTracks;

// The live rows the exact objects occupy now, departed ones dropped: the one
// identity-resolution rule every group gesture rests on.
- (NSIndexSet *)rowsForTracks:(NSArray<AudioTrack *> *)tracks;

// Plays the topmost selected row, as a double-click does.
- (void)playSelectedTrack;

- (BOOL)isCurrentTrack:(AudioTrack *)track;
- (AudioTrack * _Nullable)trackForURL:(NSURL *)url;

- (NSIndexSet *)indexesOfTracksWithURL:(NSURL *)url;

- (void)reloadCurrentTrack;
- (void)reloadTrackAtIndex:(NSUInteger)index;
- (void)reloadTrack:(AudioTrack *)track;

// For a whole-list change (the folder-artwork setting). Selection and scroll
// survive.
- (void)reloadAllTracks;

// On-screen rows only, for a *repeated* whole-list change: a bulk open would
// otherwise pay a full reloadData per cover that lands.
- (void)reloadVisibleTracks;

// A no-op while the row is visible.
- (void)scrollCurrentTrackToVisible;

@end

NS_ASSUME_NONNULL_END
