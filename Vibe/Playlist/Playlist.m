//
// Playlist.m
// Vibe
//

#import "Playlist.h"

@implementation Playlist {
    NSMutableArray<AudioTrack *> *_tracks;
    // A track-to-row map for getIndexForTrack:. The metadata sweep resolves a
    // row once per track on the main thread, and a linear scan would make the
    // sweep O(n²) in playlist size. replaceAllWithURLs: rebuilds the map and
    // appendURLs: extends it. removeTrackAtIndex: is the one mutation that
    // MOVES rows, and rebuilds both indexes rather than patching them; every
    // other path leaves the recorded positions valid.
    NSMapTable<AudioTrack *, NSNumber *> *_trackIndexes;
    // The same thing keyed by URL, for indexesOfTracksWithURL: and
    // trackForURL:. A file can occupy several rows, so the value is a row set
    // rather than one index. It exists for the same reason as the map above:
    // every analyzed BPM and key delivery asks, once per track start, and the
    // scan it replaced was a full-playlist NSURL isEqual: walk. Equality stays
    // NSURL's own, so a URL that did not match before does not match now.
    // Maintained by exactly the mutators that touch _trackIndexes.
    NSMutableDictionary<NSURL *, NSMutableIndexSet *> *_indexesByURL;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetStorage];
        _currentIndex = 0;
    }
    return self;
}

// The empty state of all three collections, so a replacement and a clear
// cannot rebuild one and forget another.
- (void)resetStorage {
    _tracks = [NSMutableArray new];
    [self resetIndexes];
}

// The empty state of the two indexes alone, for a rebuild that keeps _tracks.
- (void)resetIndexes {
    _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
    _indexesByURL = [NSMutableDictionary dictionary];
}

- (void)setCurrentIndex:(NSUInteger)currentIndex {
    NSUInteger previousIndex = _currentIndex;
    _currentIndex = currentIndex;
    [self.observer playlist:self currentIndexDidChangeFromIndex:previousIndex];
}

- (NSArray<AudioTrack *> *)tracks {
    return [_tracks copy];
}

- (AudioTrack *)trackAtIndex:(NSUInteger)index {
    return index < _tracks.count ? _tracks[index] : nil;
}

- (AudioTrack *)currentTrack {
    if (_currentIndex < _tracks.count) {
        return _tracks[_currentIndex];
    }
    return nil;
}

- (NSUInteger)count {
    return _tracks.count;
}

- (void)replaceAllWithURLs:(NSArray<NSURL *> *)urls {
    [self resetStorage];
    [self addTracksForURLs:urls];
    _currentIndex = 0;
    [self.observer playlistDidReplaceAllTracks:self];
}

- (void)appendURLs:(NSArray<NSURL *> *)urls {
    if (!urls.count) {
        return;
    }
    NSUInteger firstIndex = _tracks.count;
    [self addTracksForURLs:urls];
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(firstIndex, urls.count)];
    [self.observer playlist:self didAppendTracksAtIndexes:indexes];
}

- (void)addTracksForURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        AudioTrack *track = [AudioTrack withURL:url];
        [self indexTrack:track atIndex:_tracks.count];
        [_tracks addObject:track];
    }
}

// Both indexes for one row, so no mutator can record a track's row without
// recording its URL's.
- (void)indexTrack:(AudioTrack *)track atIndex:(NSUInteger)index {
    [_trackIndexes setObject:@(index) forKey:track];
    [self indexURL:track.url atIndex:index];
}

// The two halves of the URL index, so no mutator can do one without the other.
- (void)indexURL:(NSURL *)url atIndex:(NSUInteger)index {
    if (!url) {
        return;
    }
    NSMutableIndexSet *rows = _indexesByURL[url];
    if (!rows) {
        rows = [NSMutableIndexSet indexSet];
        _indexesByURL[url] = rows;
    }
    [rows addIndex:index];
}

// Both indexes rebuilt from _tracks in one pass. Row removal is the one
// mutation that MOVES rows, so the incremental bookkeeping every other mutator
// does cannot repair the shifted entries. O(n) is what NSMutableArray's own
// removal already costs, and the hot async-delivery lookups stay O(1).
- (void)rebuildIndexes {
    [self resetIndexes];
    NSUInteger index = 0;
    for (AudioTrack *track in _tracks) {
        [self indexTrack:track atIndex:index];
        index++;
    }
}

- (void)unindexURL:(NSURL *)url atIndex:(NSUInteger)index {
    if (!url) {
        return;
    }
    NSMutableIndexSet *rows = _indexesByURL[url];
    [rows removeIndex:index];
    if (rows.count == 0) {
        // Dropped rather than left empty: a playlist that converts every row
        // away would otherwise keep a bucket per departed file for its life.
        [_indexesByURL removeObjectForKey:url];
    }
}

- (void)clear {
    [self resetStorage];
    _currentIndex = 0;
    [self.observer playlistDidReplaceAllTracks:self];
}

- (BOOL)hasNextTrack {
    return _currentIndex + 1 < _tracks.count;
}

- (BOOL)hasPreviousTrack {
    return _tracks.count > 0 && _currentIndex > 0;
}

- (BOOL)next {
    if (self.hasNextTrack) {
        self.currentIndex = _currentIndex + 1;
        return YES;
    }
    return NO;
}

- (BOOL)previous {
    if (self.hasPreviousTrack) {
        self.currentIndex = _currentIndex - 1;
        return YES;
    }
    return NO;
}

- (NSInteger)getIndexForTrack:(AudioTrack *)track {
    // AudioTrack uses NSObject's identity hash and isEqual, so this is an
    // identity lookup.
    NSNumber *index = track ? [_trackIndexes objectForKey:track] : nil;
    return index != nil ? index.integerValue : -1;
}

- (NSIndexSet *)indexesOfTracksWithURL:(NSURL *)url {
    if (!url) {
        return [NSIndexSet indexSet];
    }
    // A copy, not the live set: callers enumerate the result while replacing
    // the very rows it names (the convert swap does exactly that).
    return [_indexesByURL[url] copy] ?: [NSIndexSet indexSet];
}

- (AudioTrack *)trackForURL:(NSURL *)url {
    if (!url) {
        return nil;
    }
    // The nil check is load-bearing: firstIndex on a nil set answers 0, not
    // NSNotFound, so an unknown URL would resolve to row 0.
    NSMutableIndexSet *rows = _indexesByURL[url];
    return rows ? [self trackAtIndex:rows.firstIndex] : nil;
}

- (BOOL)isCurrentTrack:(AudioTrack *)track {
    return self.currentTrack == track;
}

- (AudioTrack *)replaceTrackAtIndex:(NSUInteger)index withURL:(NSURL *)url {
    if (index >= _tracks.count || !url) {
        return nil;
    }
    AudioTrack *outgoing = _tracks[index];
    AudioTrack *incoming = [AudioTrack withURL:url];
    incoming.duration = outgoing.duration;
    incoming.detectedBPM = outgoing.detectedBPM;
    incoming.detectedKey = outgoing.detectedKey;
    // Remove the outgoing key: entries are never otherwise removed, and a
    // departed track still resolving to this row would let its late metadata
    // delivery redraw a row it no longer occupies. The URL index moves the
    // same way — the row leaves the source's bucket and joins the output's,
    // which is what stops a post-swap delivery for the old file from stamping
    // a row that no longer holds it.
    [_trackIndexes removeObjectForKey:outgoing];
    [self unindexURL:outgoing.url atIndex:index];
    [self indexTrack:incoming atIndex:index];
    _tracks[index] = incoming;
    // currentIndex, being positional, needs no adjustment.
    [self.observer playlist:self didReplaceTrackAtIndex:index];
    return incoming;
}

- (AudioTrack *)removeTrackAtIndex:(NSUInteger)index {
    if (index >= _tracks.count) {
        return nil;
    }
    AudioTrack *removed = _tracks[index];
    [_tracks removeObjectAtIndex:index];
    // Every row below the removed one has moved, so the indexes are rebuilt
    // rather than patched; the incremental unindex the convert swap uses would
    // leave every later entry naming the row above its own.
    [self rebuildIndexes];
    // The cursor is positional, so it follows the rows rather than the object:
    // a row removed above it moves it up one, which is what keeps it naming the
    // same AudioTrack, and one removed below leaves it alone. Removing the
    // current row itself keeps the cursor on the successor that slid into that
    // row, or moves it to the new last row when the removed one was last.
    // Written straight to the ivar: one structural edit sends ONE event, and
    // the property's setter would fire currentIndexDidChangeFromIndex: as a
    // second edge for the same action.
    if (index < _currentIndex) {
        _currentIndex -= 1;
    }
    // Unconditional, not chained to the shift above: every removal must leave
    // the cursor in range (or 0 in an emptied list), whatever state it arrived
    // in — a chained else-if would carry a corrupt cursor straight through.
    if (_currentIndex >= _tracks.count) {
        _currentIndex = _tracks.count == 0 ? 0 : _tracks.count - 1;
    }
    [self.observer playlist:self didRemoveTrackAtIndex:index];
    return removed;
}

- (void)insertTrack:(AudioTrack *)track atIndex:(NSUInteger)index {
    if (!track) {
        return;
    }
    // Clamped, not refused: the undo of a removal can land after later edits
    // have moved the end of the list, and a past-the-end restore should come
    // back as the last row rather than not at all.
    NSUInteger insertIndex = MIN(index, _tracks.count);
    BOOL wasEmpty = _tracks.count == 0;
    [_tracks insertObject:track atIndex:insertIndex];
    // The mirror of removal's rebuild: every row at or below the insert moved.
    [self rebuildIndexes];
    // The cursor is positional and follows the rows, exactly as removal's
    // does: an insert at or before it moves it down one, which keeps it naming
    // the same AudioTrack. Into an empty list it stays 0, naming the new row,
    // as a replacement would leave it. Written straight to the ivar for
    // removal's reason: one structural edit, one event.
    if (!wasEmpty && insertIndex <= _currentIndex) {
        _currentIndex += 1;
    }
    [self.observer playlist:self didInsertTrackAtIndex:insertIndex];
}

@end
