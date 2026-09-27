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

NS_ASSUME_NONNULL_BEGIN

@class Playlist;

// Change notifications, fired synchronously by the mutation that caused them,
// carrying the affected rows so a table owner can reload precisely.
@protocol PlaylistObserver <NSObject>

// A replacement or a clear: the whole row set changed and currentIndex is 0.
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
@property (nonatomic) NSUInteger currentIndex;

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

// The first forward survivor of a current-row removal. nil for a noncurrent
// edit, an invalid set, or when the landing is backward/empty. The shell uses
// this to decide whether the ordered playing intent may continue.
- (nullable AudioTrack *)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes;

// Replaces the whole list and resets currentIndex to 0.
- (void)replaceAllWithURLs:(NSArray<NSURL *> *)urls;

// Appends without touching currentIndex; an empty urls is a no-op.
- (void)appendURLs:(NSArray<NSURL *> *)urls;

- (void)clear;

// Advance or retreat currentIndex, returning NO at the playlist boundary.
- (BOOL)next;
- (BOOL)previous;

// Adopt a gapless boundary only while BOTH exact rows still describe it.
// Refusal changes nothing; success performs the ordinary cursor notification.
- (BOOL)advanceFromTrack:(AudioTrack *)finishedTrack toTrack:(AudioTrack *)startedTrack;

// The single source of truth for the playlist boundary.
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

// Points a row at a different file, returning the fresh AudioTrack now in it,
// or nil when index is out of range. Mints rather than reassigning url:
// AudioTrack memoizes its cache key, so a reused track would file the new
// file's waveform and metadata under the old entries. Duration, detected BPM
// and detected key carry across — same audio.
- (nullable AudioTrack *)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url;

// Replaces every row still holding this file, even if the captured row left
// during conversion. Returns the affected rows; transport is the shell's.
- (NSIndexSet *)replaceTracksMatchingTrack:(AudioTrack *)track withURL:(NSURL *)url;

// Removes every row in indexes, returning the exact removed objects in
// ascending row order, or nil — changing nothing, sending no event — when
// indexes is empty or any member is out of range.
//
// The cursor stays on the current track; a removed current row leaves it on
// the survivor that slid into its row, else the new last row; emptying the
// list resets it to 0.
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
