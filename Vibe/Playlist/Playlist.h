//
// Playlist.h
// Vibe
//
// The ordered track list and its current-index cursor, free of any view
// dependency. THERE IS EXACTLY ONE OBSERVER SLOT, deliberately: a second
// consumer gets whatever the first fans out to (PlaylistController on macOS,
// PlaybackController on iOS).
//

#import <Foundation/Foundation.h>
#import "AudioTrack.h"
#import "RepeatMode.h"

NS_ASSUME_NONNULL_BEGIN

@class Playlist;

// Change notifications, fired synchronously by the mutation that caused them,
// carrying the affected rows so a table owner can reload precisely.
@protocol PlaylistObserver <NSObject>

// A replacement or a clear: the whole row set changed and currentIndex is
// final — 0 for a clear, the replacement's start row otherwise.
- (void)playlistDidReplaceAllTracks:(Playlist *)playlist;

// Rows were appended at indexes; existing rows and currentIndex are untouched.
- (void)playlist:(Playlist *)playlist didAppendTracksAtIndexes:(NSIndexSet *)indexes;

// The track at index was replaced by a fresh AudioTrack.
- (void)playlist:(Playlist *)playlist didReplaceTrackAtIndex:(NSUInteger)index;

// The rows at indexes left the list and currentIndex is final. The ONE event a
// removal sends — currentIndexDidChangeFromIndex: does not also fire, so a
// table reconciles one edit once.
- (void)playlist:(Playlist *)playlist didRemoveTracksAtIndexes:(NSIndexSet *)indexes;

// The rows at indexes — their landed positions — joined the list and
// currentIndex is final. The ONE event an insert sends.
- (void)playlist:(Playlist *)playlist didInsertTracksAtIndexes:(NSIndexSet *)indexes;

// The rows at sourceIndexes (pre-move positions) now occupy
// destinationIndexes, ascending to ascending, and currentIndex is final. The
// ONE event a move sends.
- (void)playlist:(Playlist *)playlist
        didMoveTracksFromIndexes:(NSIndexSet *)sourceIndexes
                       toIndexes:(NSIndexSet *)destinationIndexes;

// currentIndex moved; the rows at previousIndex and currentIndex both render
// playing state and are stale.
- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex;

@end

@interface Playlist : NSObject <AudioTrackIndexedSource>

@property (nonatomic, weak, nullable) id<PlaylistObserver> observer;

// Setting it fires currentIndexDidChangeFromIndex: even when the index is
// unchanged, so a double-click on the already-playing row still re-renders it.
// Under shuffle it is a manual pick: the row is spliced in as the next entry
// of the play order, so nothing else repeats.
@property (nonatomic) NSUInteger currentIndex;

// The transport modes. Each shell pushes its setting in; the model reads no
// setting. Neither sends an event: they change what next and the track end
// mean, never the rows or the current one.
@property (nonatomic) VibeRepeatMode repeatMode;

// On: next walks a shuffled play order of every row, the current one first,
// and previous walks back through what it played; the rows never reorder.
// Setting the value it already has keeps the order.
@property (nonatomic) BOOL shuffleEnabled;

// arc4random_uniform unless a test injects its own. Answers [0, upperBound).
@property (nonatomic, copy, null_resettable) uint32_t (^randomBelow)(uint32_t upperBound);

// Bumped by a replacement or clear, which retires undo registrations for the
// old rows; in-place edits leave it so their undo can restore coordinates.
@property (nonatomic, readonly) NSUInteger structureGeneration;

// A shallow copy, safe to iterate across async work while appends continue.
- (NSArray<AudioTrack *> *)tracks;

// nil when out of range. No defensive copy: for one-off indexed reads on the
// main thread; hold tracks when iterating across async work.
- (nullable AudioTrack *)trackAtIndex:(NSUInteger)index;

- (nullable AudioTrack *)currentTrack;
- (NSUInteger)count;

// The rows at indexes, in row order; out-of-range members are skipped, so a
// selection that outran the model resolves to what is really there.
- (NSArray<AudioTrack *> *)tracksAtIndexes:(NSIndexSet *)indexes;

// Live rows of the exact captured objects, in row order, deduplicated. A
// departed object is ignored even if a new row now has its URL or old index.
- (NSIndexSet *)indexesOfTracks:(NSArray<AudioTrack *> *)tracks;

// The first forward survivor of a current-row removal — the next row, or
// under shuffle the next unplayed entry — which is where the removal lands.
// nil for a noncurrent edit, an invalid set, or when the landing is
// backward/empty; it never wraps. The shell uses this to decide whether the
// ordered playing intent may continue.
- (nullable AudioTrack *)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes;

// Replaces the whole list, landing on index: NSNotFound is the model's
// choice, row 0 or under shuffle the new order's random first. Each row must
// be a fresh object, not one already in the list: a row's identity is the
// object. TRAP: pass the row here rather than setting currentIndex after the
// replace — under shuffle that set is a manual pick, which marks the order's
// first entry played without it ever sounding.
- (void)replaceAllWithTracks:(NSArray<AudioTrack *> *)tracks startingAtIndex:(NSUInteger)index;

// Appends without touching currentIndex; an empty tracks is a no-op. Under
// shuffle each row joins the unplayed part of the order at random.
- (void)appendTracks:(NSArray<AudioTrack *> *)tracks;


- (void)clear;

// Advance or retreat currentIndex, returning NO at the boundary. Next lands
// on nextTrack; previous never wraps, and under shuffle retraces the order.
- (BOOL)next;
- (BOOL)previous;

// Where next lands, or nil at the boundary: the next row, or the next entry of
// the play order, wrapping to a fresh start under Repeat All. A shuffled wrap
// makes the next order on first ask and keeps it, so the track a gapless
// splice armed is the one next lands on.
- (nullable AudioTrack *)nextTrack;

// What follows a track that plays out, or nil to park: the current track
// itself under Repeat One, otherwise nextTrack. Every successor prefetch and
// both track-end reads ask this, never a row neighbor.
- (nullable AudioTrack *)trackEndSuccessor;

// Moves to trackEndSuccessor, returning NO when it is nil. Under Repeat One
// it re-sets the same index, which still notifies.
- (BOOL)advanceAtTrackEnd;

// Adopt a gapless boundary only while BOTH exact objects still describe it:
// the finished track is current and the started one is trackEndSuccessor.
// Refusal changes nothing; success performs the ordinary cursor notification.
- (BOOL)advanceFromTrack:(AudioTrack *)finishedTrack toTrack:(AudioTrack *)startedTrack;

// The single source of truth for the boundary: nextTrack exists, and previous
// has somewhere to go.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

// -1 when the track is nil or absent. An O(1) identity lookup.
- (NSInteger)getIndexForTrack:(nullable AudioTrack *)track;

// Every row holding url — the same file can sit in the playlist more than
// once, and a caller acting on a file has to reach all of them. Empty for nil.
// O(1), by NSURL equality.
- (NSIndexSet *)indexesOfTracksWithURL:(nullable NSURL *)url;

// The first row holding url, off the same index.
- (nullable AudioTrack *)trackForURL:(nullable NSURL *)url;
- (BOOL)isCurrentTrack:(AudioTrack *)track;

// Runs `stamp` on every row sounding what `track` sounds — its sourceKey, the
// file and the window — which is what an analyzed BPM or key delivery is valid
// for: the first match alone would strand a duplicate row that happens to be
// the one playing, and every row of the file would stamp one cue row's tempo
// on the rest. Answers whether the current track was among them, which is
// when a shell redraws or refeeds.
- (BOOL)stampTracksSounding:(nullable AudioTrack *)track usingBlock:(void (NS_NOESCAPE ^)(AudioTrack *track))stamp;

// Points a row at a different file, returning the fresh AudioTrack now in it
// (AudioTrack replacementAtURL:, which says what carries across), or nil when
// index is out of range.
- (nullable AudioTrack *)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url;

// Replaces every row still holding this file, even if the captured row left
// during conversion. Returns the affected rows; transport is the shell's.
- (NSIndexSet *)replaceTracksMatchingTrack:(AudioTrack *)track withURL:(NSURL *)url;

// Removes every row in indexes, returning the exact removed objects in
// ascending row order, or nil — changing nothing, sending no event — when
// indexes is empty or any member is out of range.
//
// The cursor stays on the current track; a removed current row leaves it on
// forwardTrackAfterRemovingTracksAtIndexes:'s answer, else the new last row
// (under shuffle, the last entry played); emptying the list resets it to 0.
//
// The CALLING SHELL owns the audio transition: this stops, starts and parks
// nothing, so removing the current row through it alone leaves the player
// sounding a track the playlist no longer contains (MainPlayerController's
// removal funnel is the coordinated version).
- (nullable NSArray<AudioTrack *> *)removeTracksAtIndexes:(NSIndexSet *)indexes;

// The removal's inverse, for the shell's undo: puts the exact objects back at
// indexes, each clamped to the end so a restore after later edits still
// lands. Refused, changing nothing, when tracks is empty or its count differs
// from the index set's.
//
// The cursor follows the current track; into an empty list it stays 0. Like
// removal it touches no audio and sends ONE event with the cursor final —
// restoring a removed current row does not replay it.
- (void)insertTracks:(NSArray<AudioTrack *> *)tracks atIndexes:(NSIndexSet *)indexes;

// Moves the rows at sourceIndexes so they occupy destinationIndexes —
// ascending to ascending, insertObjects:atIndexes: semantics, so both sets are
// FINAL row positions, never AppKit insertion slots (PlaylistDragRules.h
// converts those). Sets on both sides make it its own inverse: the undo hands
// them back swapped. The cursor follows the current track.
//
// Returns NO, changing nothing and sending no event, for empty or
// unequal-count sets, an out-of-range member, or identical sets.
//
// Touches no audio: a moved current row keeps sounding.
- (BOOL)moveTracksAtIndexes:(NSIndexSet *)sourceIndexes
                  toIndexes:(NSIndexSet *)destinationIndexes;

@end

NS_ASSUME_NONNULL_END
