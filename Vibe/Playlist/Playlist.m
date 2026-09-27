//
// Playlist.m
// Vibe
//

#import "Playlist.h"

@implementation Playlist {
    NSMutableArray<AudioTrack *> *_tracks;
    // Keeps getIndexForTrack: O(1): the metadata sweep resolves a row per
    // track, and a scan would make the sweep O(n²). Mutators that move rows
    // rebuild both indexes; the rest patch them.
    NSMapTable<AudioTrack *, NSNumber *> *_trackIndexes;
    // The same, keyed by URL, for the BPM and key deliveries on every track
    // start. A file can occupy several rows, so the value is a row set.
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
    _structureGeneration++;
    _tracks = [NSMutableArray new];
    [self resetIndexes];
}

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

- (NSArray<AudioTrack *> *)tracksAtIndexes:(NSIndexSet *)indexes {
    if (indexes.count == 0) {
        return @[];
    }
    if (indexes.lastIndex < _tracks.count) {
        return [_tracks objectsAtIndexes:indexes];
    }
    NSMutableIndexSet *valid = [indexes mutableCopy];
    [valid removeIndexesInRange:NSMakeRange(_tracks.count,
                                            indexes.lastIndex - _tracks.count + 1)];
    return [_tracks objectsAtIndexes:valid];
}

- (AudioTrack *)trackAtIndex:(NSUInteger)index {
    return index < _tracks.count ? _tracks[index] : nil;
}

- (NSIndexSet *)indexesOfTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (AudioTrack *track in tracks) {
        NSInteger row = [self getIndexForTrack:track];
        if (row >= 0) {
            [rows addIndex:(NSUInteger)row];
        }
    }
    return rows;
}

- (AudioTrack *)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes {
    if (indexes.count == 0 || indexes.lastIndex >= _tracks.count
            || ![indexes containsIndex:_currentIndex]) {
        return nil;
    }
    NSUInteger successor = _currentIndex + 1;
    while ([indexes containsIndex:successor]) {
        successor++;
    }
    return [self trackAtIndex:successor];
}

- (BOOL)advanceFromTrack:(AudioTrack *)finishedTrack toTrack:(AudioTrack *)startedTrack {
    if (finishedTrack != self.currentTrack || !self.hasNextTrack
            || startedTrack != [self trackAtIndex:_currentIndex + 1]) {
        return NO;
    }
    return [self next];
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

// For remove, insert and move, which shift rows past what incremental
// bookkeeping can repair. O(n), as NSMutableArray's own edit already is.
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
    // An identity lookup: AudioTrack keeps NSObject's hash and isEqual.
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

- (BOOL)stampTracksWithURL:(NSURL *)url usingBlock:(void (NS_NOESCAPE ^)(AudioTrack *track))stamp {
    __block BOOL current = NO;
    [[self indexesOfTracksWithURL:url] enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        AudioTrack *track = [self trackAtIndex:index];
        stamp(track);
        current |= [self isCurrentTrack:track];
    }];
    return current;
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

- (NSIndexSet *)replaceTracksMatchingTrack:(AudioTrack *)track withURL:(NSURL *)url {
    NSIndexSet *rows = [self indexesOfTracksWithURL:track.url];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [self replaceTrackAtIndex:row withURL:url];
    }];
    return rows;
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
    // Unindex the outgoing track and URL, or a late delivery for the departed
    // track or file would stamp a row it no longer occupies.
    [_trackIndexes removeObjectForKey:outgoing];
    [self unindexURL:outgoing.url atIndex:index];
    [self indexTrack:incoming atIndex:index];
    _tracks[index] = incoming;
    [self.observer playlist:self didReplaceTrackAtIndex:index];
    return incoming;
}

- (NSArray<AudioTrack *> *)removeTracksAtIndexes:(NSIndexSet *)indexes {
    if (indexes.count == 0 || indexes.lastIndex >= _tracks.count) {
        return nil;
    }
    NSArray<AudioTrack *> *removed = [_tracks objectsAtIndexes:indexes];
    [_tracks removeObjectsAtIndexes:indexes];
    [self rebuildIndexes];
    // Dropping by the removed rows above keeps the cursor on its object, or,
    // for a removed current row, on the survivor that slid in. Written to the
    // ivar: the setter would send a second event for one edit.
    _currentIndex -= [indexes countOfIndexesInRange:NSMakeRange(0, _currentIndex)];
    // Unconditional, not chained to the shift: a cursor that arrived corrupt
    // must still leave in range.
    if (_currentIndex >= _tracks.count) {
        _currentIndex = _tracks.count == 0 ? 0 : _tracks.count - 1;
    }
    [self.observer playlist:self didRemoveTracksAtIndexes:indexes];
    return removed;
}

- (void)insertTracks:(NSArray<AudioTrack *> *)tracks atIndexes:(NSIndexSet *)indexes {
    if (tracks.count == 0 || tracks.count != indexes.count) {
        return;
    }
    AudioTrack *current = self.currentTrack;
    // Past-the-end indexes clamp rather than refuse: a removal's undo can land
    // after later edits shortened the list. Only the clamped case pays the
    // ascending per-row loop, and the event carries the landed set.
    NSIndexSet *landed;
    if (indexes.lastIndex < _tracks.count + tracks.count) {
        [_tracks insertObjects:tracks atIndexes:indexes];
        landed = indexes;
    } else {
        NSMutableIndexSet *clamped = [NSMutableIndexSet indexSet];
        __block NSUInteger trackPosition = 0;
        [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
            NSUInteger insertIndex = MIN(index, self->_tracks.count);
            [self->_tracks insertObject:tracks[trackPosition] atIndex:insertIndex];
            [clamped addIndex:insertIndex];
            trackPosition += 1;
        }];
        landed = clamped;
    }
    [self rebuildIndexes];
    // The cursor follows its object; into an empty list it stays 0. Ivar, not
    // setter: one edit, one event.
    NSInteger resolvedCurrent = [self getIndexForTrack:current];
    if (resolvedCurrent >= 0) {
        _currentIndex = (NSUInteger)resolvedCurrent;
    }
    [self.observer playlist:self didInsertTracksAtIndexes:landed];
}

- (BOOL)moveTracksAtIndexes:(NSIndexSet *)sourceIndexes
                  toIndexes:(NSIndexSet *)destinationIndexes {
    NSUInteger moving = sourceIndexes.count;
    if (moving == 0 || destinationIndexes.count != moving
            || sourceIndexes.lastIndex >= _tracks.count
            || destinationIndexes.lastIndex >= _tracks.count) {
        return NO;
    }
    if ([sourceIndexes isEqualToIndexSet:destinationIndexes]) {
        return NO;
    }
    AudioTrack *current = self.currentTrack;
    NSArray<AudioTrack *> *moved = [_tracks objectsAtIndexes:sourceIndexes];
    [_tracks removeObjectsAtIndexes:sourceIndexes];
    [_tracks insertObjects:moved atIndexes:destinationIndexes];
    [self rebuildIndexes];
    // The cursor follows its object. Ivar, not setter: one edit, one event.
    NSInteger resolvedCurrent = [self getIndexForTrack:current];
    if (resolvedCurrent >= 0) {
        _currentIndex = (NSUInteger)resolvedCurrent;
    }
    [self.observer playlist:self didMoveTracksFromIndexes:sourceIndexes
                  toIndexes:destinationIndexes];
    return YES;
}

@end
