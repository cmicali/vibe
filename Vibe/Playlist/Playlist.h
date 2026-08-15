//
// Playlist.h
// Vibe
//
// The ordered track list, free of any view dependency: the backing store, the
// current-index cursor, and the track-to-row map that keeps row lookups O(1)
// during the metadata sweep. PlaylistController owns the NSTableView half and
// reacts to changes through PlaylistObserver.
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

// currentIndex moved; the rows at previousIndex and currentIndex both render
// playing state and are stale.
- (void)playlist:(Playlist *)playlist currentIndexDidChangeFromIndex:(NSUInteger)previousIndex;

@end

@interface Playlist : NSObject

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

@end

NS_ASSUME_NONNULL_END
