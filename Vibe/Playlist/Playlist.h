//
// Playlist.h
// Vibe
//
// The ordered track list, free of any view dependency: the backing store, the
// current-index cursor, and the track-to-row map that keeps row lookups O(1)
// during the metadata sweep. Both app shells observe it through
// PlaylistObserver — PlaylistController owns the mac's NSTableView half, and
// on iOS PlaybackController takes the one slot and re-broadcasts, because
// three screens there describe the same playlist at once — and neither is
// visible from here.
//
// THERE IS EXACTLY ONE OBSERVER SLOT, deliberately. A second consumer does not
// get a second slot; it gets whatever the first one fans out to.
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

// The row at index left the list: every later row has shifted up by one, and
// currentIndex is already at its final value. It is the ONE event a removal
// sends — currentIndexDidChangeFromIndex: deliberately does not also fire, so a
// table reconciles one structural edit once.
- (void)playlist:(Playlist *)playlist didRemoveTrackAtIndex:(NSUInteger)index;

// The removal's inverse: the row at index joined the list, it and every later
// row have shifted down by one, and currentIndex is already at its final
// value. Like the removal it is the ONE event the edit sends.
- (void)playlist:(Playlist *)playlist didInsertTrackAtIndex:(NSUInteger)index;

// currentIndex moved; the rows at previousIndex and currentIndex both render
// playing state and are stale.
- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex;

@end

@interface Playlist : NSObject <AudioTrackIndexedSource>

@property (nonatomic, weak, nullable) id<PlaylistObserver> observer;

// Setting it fires currentIndexDidChangeFromIndex: even when the index is
// unchanged, so a double-click on the already-playing row still re-renders it.
@property (nonatomic) NSUInteger currentIndex;

// A defensive shallow copy. Callers iterate the result across async work
// while appends can extend the live array on the main thread.
- (NSArray<AudioTrack *> *)tracks;

// nil when out of range. No defensive copy: for one-off indexed reads on the
// main thread; hold tracks when iterating across async work.
- (nullable AudioTrack *)trackAtIndex:(NSUInteger)index;

- (nullable AudioTrack *)currentTrack;
- (NSUInteger)count;

// Replaces the whole list and resets currentIndex to 0.
- (void)replaceAllWithURLs:(NSArray<NSURL *> *)urls;

// Appends without touching currentIndex; an empty urls is a no-op.
- (void)appendURLs:(NSArray<NSURL *> *)urls;

- (void)clear;

// Advance or retreat currentIndex, returning NO at the playlist boundary.
- (BOOL)next;
- (BOOL)previous;

// The playlist-boundary predicates: the single source of truth for whether
// there is a track after or before the current one.
- (BOOL)hasNextTrack;
- (BOOL)hasPreviousTrack;

// -1 when the track is nil or not in the playlist. An identity lookup, O(1).
- (NSInteger)getIndexForTrack:(nullable AudioTrack *)track;

// Every row holding url — the same file can sit in the playlist more than
// once, and a caller acting on a file has to reach all of them. Empty for nil.
// Indexed like getIndexForTrack:, so a BPM or key delivery does not scan the
// whole playlist; equality is NSURL's, unchanged.
- (NSIndexSet *)indexesOfTracksWithURL:(nullable NSURL *)url;

// The first row holding url, off the same index.
- (nullable AudioTrack *)trackForURL:(nullable NSURL *)url;
- (BOOL)isCurrentTrack:(AudioTrack *)track;

// Points a row at a different file, returning the fresh AudioTrack now in it,
// or nil when index is out of range. Mints a new track rather than
// reassigning the old one's url: AudioTrack memoizes its cache key, and a
// track carrying the old key would file the new file's waveform and metadata
// under the old entries. Duration, detected BPM, and detected key carry
// across — same audio.
- (nullable AudioTrack *)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url;

// Removes and returns the exact row object, or nil when index is out of range,
// in which case nothing changes and no event is sent. Rows below it shift up
// by one, so this is the one mutation that MOVES rows and therefore rebuilds
// both indexes.
//
// The surviving current track keeps its identity: removing a row before it
// decrements currentIndex so it names the same object, and removing one after
// it leaves the cursor alone. Removing the current row leaves the cursor on the
// successor that slid into the same row, or on the new last row when the
// removed one was last; emptying the list resets it to 0.
//
// The CALLING SHELL owns the corresponding audio-player transition. This
// method does not stop, start or park anything, so removing the current row
// through it alone would leave the player sounding a track the playlist no
// longer contains — see MainPlayerController's removal funnel for the
// coordinated version.
- (nullable AudioTrack *)removeTrackAtIndex:(NSUInteger)index;

// The removal's inverse, for the shell's undo: puts the exact object back at
// index — clamped to the end, so a restore landing after later edits still
// lands — shifting the rows at and below it down by one. The other mutation
// that MOVES rows, so it too rebuilds both indexes. A nil track is refused,
// and nothing changes.
//
// The current track keeps its identity: an insert at or before the cursor
// moves the cursor down one so it names the same object. Inserting into an
// empty list leaves the cursor at 0, naming the new row, exactly as
// replaceAllWithURLs: would.
//
// Like removal, this touches no audio and sends ONE observer event with the
// cursor already final. The shell owns any transport consequence — restoring
// a removed current row does not replay it.
- (void)insertTrack:(AudioTrack *)track atIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
