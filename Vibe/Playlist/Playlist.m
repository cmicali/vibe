//
// Playlist.m
// Vibe
//

#import "Playlist.h"

@implementation Playlist {
    NSURL * _Nullable (^_urlKey)(id entry);
    NSString * _Nullable (^_sourceKey)(id entry);
    NSMutableArray *_tracks;
    // Keeps getIndexForTrack: O(1): the metadata sweep resolves a row per
    // track, and a scan would make the sweep O(n²). Every mutator patches
    // both indexes over the rows whose positions change. Keyed by pointer,
    // never the entry's own isEqual:, so two entries for one file stay two.
    NSMapTable<id, NSNumber *> *_trackIndexes;
    // The same, keyed by URL, for the BPM and key deliveries on every track
    // start. A file can occupy several rows, so the value is a row set.
    NSMutableDictionary<NSURL *, NSMutableIndexSet *> *_indexesByURL;
    // Under shuffle, every row object exactly once, in play order: entries
    // before the cursor are played, the cursor entry is the current row, and
    // entries after it are unplayed. nil while shuffle is off. Objects rather
    // than row numbers, so a move needs nothing and a remove or insert only
    // drops or adds its own entries; a replacement, which puts a fresh
    // object in place, swaps the entry with it.
    NSMutableArray *_playOrder;
    NSUInteger _playOrderCursor;
    // Repeat All's next cycle, made on the first ask at the order's end and
    // kept so that nextTrack is where next lands. Any edit to the order drops
    // it, but a replacement swaps its entry as in _playOrder. nil whenever
    // _playOrder is.
    NSMutableArray *_nextPlayOrder;
}

@synthesize randomBelow = _randomBelow;

- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetStorage];
        _currentIndex = 0;
        // Never nil, so the per-row reads need no branch.
        _urlKey = ^NSURL *(id entry) { return nil; };
        _sourceKey = ^NSString *(id entry) { return nil; };
    }
    return self;
}

- (instancetype)initWithURLKey:(NSURL * _Nullable (^)(id))urlKey
                     sourceKey:(NSString * _Nullable (^)(id))sourceKey {
    self = [self init];
    if (self) {
        _urlKey = [urlKey copy];
        _sourceKey = [sourceKey copy];
    }
    return self;
}

// The empty state of all three collections, so a replacement and a clear
// cannot rebuild one and forget another.
- (void)resetStorage {
    _structureGeneration++;
    _tracks = [NSMutableArray new];
    _trackIndexes = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                                            | NSPointerFunctionsObjectPointerPersonality
                                              valueOptions:NSPointerFunctionsStrongMemory
                                                  capacity:0];
    _indexesByURL = [NSMutableDictionary dictionary];
}

- (void)setCurrentIndex:(NSUInteger)currentIndex {
    if (_playOrder && currentIndex < _tracks.count) {
        [self splicePickIntoPlayOrder:_tracks[currentIndex]];
    }
    [self moveCurrentIndexTo:currentIndex];
}

// The cursor write next, previous and the track end share: no splice, the
// same event a pick sends, so observers cannot tell which moved it.
- (void)moveCurrentIndexTo:(NSUInteger)currentIndex {
    NSUInteger previousIndex = _currentIndex;
    _currentIndex = currentIndex;
    [self.observer playlist:self currentIndexDidChangeFromIndex:previousIndex];
}

#pragma mark - Transport modes

- (BOOL)shuffleEnabled {
    return _playOrder != nil;
}

- (void)setShuffleEnabled:(BOOL)shuffleEnabled {
    if (shuffleEnabled == self.shuffleEnabled) {
        return;
    }
    if (shuffleEnabled) {
        [self resetPlayOrderStartingWith:self.currentTrack];
    }
    else {
        _playOrder = nil;
        _nextPlayOrder = nil;
    }
}

// What next and previous walk: the play order under shuffle, else the rows.
- (NSArray *)activeOrder {
    return _playOrder ?: _tracks;
}

- (NSUInteger)activeCursor {
    return _playOrder ? _playOrderCursor : _currentIndex;
}

- (uint32_t (^)(uint32_t))randomBelow {
    return _randomBelow ?: ^uint32_t(uint32_t upperBound) {
        return arc4random_uniform(upperBound);
    };
}

// Fisher-Yates: every order equally likely.
- (NSMutableArray *)shuffledTracks:(NSArray *)tracks {
    NSMutableArray *order = [tracks mutableCopy];
    uint32_t (^randomBelow)(uint32_t) = self.randomBelow;
    for (NSUInteger i = order.count; i > 1; i--) {
        [order exchangeObjectAtIndex:i - 1 withObjectAtIndex:randomBelow((uint32_t)i)];
    }
    return order;
}

// A fresh order over every row with first, when it is a row, at the cursor.
- (void)resetPlayOrderStartingWith:(nullable id)first {
    _playOrder = [self shuffledTracks:_tracks];
    _nextPlayOrder = nil;
    _playOrderCursor = 0;
    NSUInteger position = first ? [_playOrder indexOfObjectIdenticalTo:first] : NSNotFound;
    if (position != NSNotFound) {
        [_playOrder exchangeObjectAtIndex:position withObjectAtIndex:0];
    }
}

// An unplayed pick swaps into the next slot. A played pick moves from the
// history to the current slot. Every other unplayed entry stays unplayed.
- (void)splicePickIntoPlayOrder:(id)picked {
    NSUInteger position = [_playOrder indexOfObjectIdenticalTo:picked];
    if (position == NSNotFound || position == _playOrderCursor) {
        return;
    }
    _nextPlayOrder = nil;
    if (position > _playOrderCursor) {
        [_playOrder exchangeObjectAtIndex:position withObjectAtIndex:_playOrderCursor + 1];
        _playOrderCursor += 1;
        return;
    }
    [_playOrder removeObjectAtIndex:position];
    [_playOrder insertObject:picked atIndex:_playOrderCursor];
}

// Each track at a uniformly random place in the unplayed part, (cursor, end],
// in one pass rather than an insert apiece, which would be O(n·m) on a large
// Add: the new tracks shuffled, then randomly interleaved with the waiting
// ones, whose order is kept.
- (void)addUnplayedTracksToPlayOrder:(NSArray *)tracks {
    _nextPlayOrder = nil;
    uint32_t (^randomBelow)(uint32_t) = self.randomBelow;
    NSArray *added = [self shuffledTracks:tracks];
    NSRange unplayed = NSMakeRange(_playOrderCursor + 1, _playOrder.count - _playOrderCursor - 1);
    NSArray *waiting = [_playOrder subarrayWithRange:unplayed];
    NSMutableArray *merged = [NSMutableArray arrayWithCapacity:waiting.count + added.count];
    NSUInteger nextWaiting = 0;
    NSUInteger nextAdded = 0;
    while (merged.count < waiting.count + added.count) {
        NSUInteger addedLeft = added.count - nextAdded;
        NSUInteger left = addedLeft + waiting.count - nextWaiting;
        BOOL takeAdded = randomBelow((uint32_t)left) < addedLeft;
        [merged addObject:takeAdded ? added[nextAdded++] : waiting[nextWaiting++]];
    }
    [_playOrder replaceObjectsInRange:unplayed withObjectsFromArray:merged];
}

// With more than one row, keep the previous cycle's last track from opening
// the new cycle. An independent shuffle would repeat it one time in n.
- (NSArray *)nextPlayOrder {
    if (!_nextPlayOrder) {
        NSMutableArray *order = [self shuffledTracks:_tracks];
        if (order.count > 1 && order.firstObject == _playOrder.lastObject) {
            NSUInteger swap = 1 + self.randomBelow((uint32_t)order.count - 1);
            [order exchangeObjectAtIndex:0 withObjectAtIndex:swap];
        }
        _nextPlayOrder = order;
    }
    return _nextPlayOrder;
}

- (NSArray *)tracks {
    return [_tracks copy];
}

- (NSArray *)tracksAtIndexes:(NSIndexSet *)indexes {
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

- (id)trackAtIndex:(NSUInteger)index {
    return index < _tracks.count ? _tracks[index] : nil;
}

- (NSIndexSet *)indexesOfTracks:(NSArray *)tracks {
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (id track in tracks) {
        NSInteger row = [self getIndexForTrack:track];
        if (row >= 0) {
            [rows addIndex:(NSUInteger)row];
        }
    }
    return rows;
}

- (id)forwardTrackAfterRemovingTracksAtIndexes:(NSIndexSet *)indexes {
    if (indexes.count == 0 || indexes.lastIndex >= _tracks.count
            || ![indexes containsIndex:_currentIndex]) {
        return nil;
    }
    NSArray *order = self.activeOrder;
    for (NSUInteger position = self.activeCursor + 1; position < order.count; position++) {
        id track = order[position];
        if (![indexes containsIndex:(NSUInteger)[self getIndexForTrack:track]]) {
            return track;
        }
    }
    return nil;
}

- (BOOL)advanceFromTrack:(id)finishedTrack toTrack:(id)startedTrack {
    if (finishedTrack != self.currentTrack || !startedTrack
            || startedTrack != self.trackEndSuccessor) {
        return NO;
    }
    return [self advanceAtTrackEnd];
}

- (id)currentTrack {
    if (_currentIndex < _tracks.count) {
        return _tracks[_currentIndex];
    }
    return nil;
}

- (NSUInteger)count {
    return _tracks.count;
}

- (void)replaceAllWithTracks:(NSArray *)tracks startingAtIndex:(NSUInteger)index {
    [self resetStorage];
    [self addTracks:tracks];
    id start = [self trackAtIndex:index];
    if (_playOrder) {
        [self resetPlayOrderStartingWith:start];
        start = _playOrder.firstObject;
    }
    _currentIndex = start ? (NSUInteger)[self getIndexForTrack:start] : 0;
    [self.observer playlistDidReplaceAllTracks:self];
}

- (void)appendTracks:(NSArray *)tracks {
    if (!tracks.count) {
        return;
    }
    NSUInteger firstIndex = _tracks.count;
    [self addTracks:tracks];
    [self playOrderDidGainTracks:tracks];
    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(firstIndex, tracks.count)];
    [self.observer playlist:self didAppendTracksAtIndexes:indexes];
}

- (void)addTracks:(NSArray *)tracks {
    for (id track in tracks) {
        [self indexTrack:track atIndex:_tracks.count];
        [_tracks addObject:track];
    }
}

// Both indexes for one row, so no mutator can record a track's row without
// recording its URL's.
- (void)indexTrack:(id)track atIndex:(NSUInteger)index {
    [_trackIndexes setObject:@(index) forKey:track];
    [self indexURL:_urlKey(track) atIndex:index];
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

// Remove and insert shift the tail. A move only renumbers the span between
// its source and destination. Entries outside that span stay valid.
- (void)unindexRowsFrom:(NSUInteger)first to:(NSUInteger)end {
    for (NSUInteger row = first; row < end; row++) {
        NSURL *url = _urlKey(_tracks[row]);
        if (url) {
            [_indexesByURL[url] removeIndex:row];
        }
    }
}

- (void)indexRowsFrom:(NSUInteger)first to:(NSUInteger)end {
    for (NSUInteger row = first; row < end; row++) {
        [self indexTrack:_tracks[row] atIndex:row];
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
    if (_playOrder) {
        [self resetPlayOrderStartingWith:nil];
    }
    [self.observer playlistDidReplaceAllTracks:self];
}

// Rows that just joined the list. Into an empty order the current row, the
// first new one, goes first, so the order still names it at the cursor.
- (void)playOrderDidGainTracks:(NSArray *)tracks {
    if (!_playOrder) {
        return;
    }
    if (_playOrder.count == 0) {
        [self resetPlayOrderStartingWith:self.currentTrack];
        return;
    }
    [self addUnplayedTracksToPlayOrder:tracks];
}

- (id)nextTrack {
    if (_tracks.count == 0) {
        return nil;
    }
    NSArray *order = self.activeOrder;
    NSUInteger cursor = self.activeCursor;
    if (cursor + 1 < order.count) {
        return order[cursor + 1];
    }
    if (_repeatMode != VibeRepeatModeAll) {
        return nil;
    }
    return _playOrder ? self.nextPlayOrder.firstObject : _tracks.firstObject;
}

- (NSArray *)neighborhoodTracks {
    NSMutableArray *neighborhood = [NSMutableArray array];
    NSArray *order = self.activeOrder;
    NSUInteger cursor = self.activeCursor;
    id next = self.nextTrack;
    if (next) {
        [neighborhood addObject:next];
    }
    if (cursor + 2 < order.count) {
        [neighborhood addObject:order[cursor + 2]];
    }
    if (cursor > 0 && cursor - 1 < order.count) {
        [neighborhood addObject:order[cursor - 1]];
    }
    return neighborhood;
}

- (id)trackEndSuccessor {
    if (_pauseAtTrackEnd) {
        return nil;
    }
    return _repeatMode == VibeRepeatModeOne ? self.currentTrack : self.nextTrack;
}

- (BOOL)hasNextTrack {
    return self.nextTrack != nil;
}

- (BOOL)hasPreviousTrack {
    return _tracks.count > 0 && self.activeCursor > 0;
}

- (BOOL)next {
    id next = self.nextTrack;
    if (!next) {
        return NO;
    }
    if (_playOrder) {
        if (_playOrderCursor + 1 < _playOrder.count) {
            _playOrderCursor += 1;
        }
        else {
            _playOrder = _nextPlayOrder;
            _nextPlayOrder = nil;
            _playOrderCursor = 0;
        }
    }
    [self moveCurrentIndexTo:(NSUInteger)[self getIndexForTrack:next]];
    return YES;
}

- (BOOL)previous {
    if (!self.hasPreviousTrack) {
        return NO;
    }
    if (_playOrder) {
        _playOrderCursor -= 1;
        [self moveCurrentIndexTo:(NSUInteger)[self getIndexForTrack:_playOrder[_playOrderCursor]]];
        return YES;
    }
    [self moveCurrentIndexTo:_currentIndex - 1];
    return YES;
}

- (BOOL)advanceAtTrackEnd {
    if (!self.trackEndSuccessor) {
        return NO;
    }
    if (_repeatMode != VibeRepeatModeOne) {
        return [self next];
    }
    [self moveCurrentIndexTo:_currentIndex];
    return YES;
}

- (NSInteger)getIndexForTrack:(id)track {
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

- (BOOL)stampTracksSounding:(id)track usingBlock:(void (NS_NOESCAPE ^)(id track))stamp {
    if (!track) {
        return NO;
    }
    NSString *sourceKey = _sourceKey(track);
    __block BOOL current = NO;
    [[self indexesOfTracksWithURL:_urlKey(track)] enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        id row = [self trackAtIndex:index];
        if (![self->_sourceKey(row) isEqualToString:sourceKey]) {
            return;
        }
        stamp(row);
        current |= [self isCurrentTrack:row];
    }];
    return current;
}

- (id)trackForURL:(NSURL *)url {
    if (!url) {
        return nil;
    }
    // The nil check is load-bearing: firstIndex on a nil set answers 0, not
    // NSNotFound, so an unknown URL would resolve to row 0.
    NSMutableIndexSet *rows = _indexesByURL[url];
    return rows ? [self trackAtIndex:rows.firstIndex] : nil;
}

- (BOOL)isCurrentTrack:(id)track {
    return self.currentTrack == track;
}

- (NSIndexSet *)replaceTracksMatchingTrack:(id)track
                                usingBlock:(id (NS_NOESCAPE ^)(id outgoing))replacement {
    NSMutableIndexSet *replaced = [NSMutableIndexSet indexSet];
    [[self indexesOfTracksWithURL:_urlKey(track)] enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if ([self replaceTrackAtIndex:row withTrack:replacement(self->_tracks[row])]) {
            [replaced addIndex:row];
        }
    }];
    return replaced;
}

- (BOOL)replaceTrackAtIndex:(NSUInteger)index withTrack:(id)incoming {
    // A replacement already in the list would hold two rows, and the
    // track-to-row map can name only one of them.
    if (index >= _tracks.count || !incoming || [_trackIndexes objectForKey:incoming]) {
        return NO;
    }
    id outgoing = _tracks[index];
    // Unindex the outgoing track and URL, or a late delivery for the departed
    // track or file would stamp a row it no longer occupies.
    [_trackIndexes removeObjectForKey:outgoing];
    [self unindexURL:_urlKey(outgoing) atIndex:index];
    [self indexTrack:incoming atIndex:index];
    _tracks[index] = incoming;
    // No row moves, so the row keeps its place in both orders, and the next
    // cycle a gapless splice may be armed on survives.
    [self replaceOrderEntry:outgoing with:incoming in:_playOrder];
    [self replaceOrderEntry:outgoing with:incoming in:_nextPlayOrder];
    [self.observer playlist:self didReplaceTrackAtIndex:index];
    return YES;
}

// The nil check is load-bearing: a message to a nil order answers 0, not
// NSNotFound.
- (void)replaceOrderEntry:(id)outgoing with:(id)incoming
                       in:(NSMutableArray *)order {
    NSUInteger position = order ? [order indexOfObjectIdenticalTo:outgoing] : NSNotFound;
    if (position != NSNotFound) {
        order[position] = incoming;
    }
}

- (NSArray *)removeTracksAtIndexes:(NSIndexSet *)indexes {
    if (indexes.count == 0 || indexes.lastIndex >= _tracks.count) {
        return nil;
    }
    NSArray *removed = [_tracks objectsAtIndexes:indexes];
    [self unindexRowsFrom:indexes.firstIndex to:_tracks.count];
    [_tracks removeObjectsAtIndexes:indexes];
    for (id track in removed) {
        [_trackIndexes removeObjectForKey:track];
    }
    [self indexRowsFrom:indexes.firstIndex to:_tracks.count];
    // Dropped as unindexURL:atIndex: drops them.
    for (id track in removed) {
        NSURL *url = _urlKey(track);
        if (url && _indexesByURL[url].count == 0) {
            [_indexesByURL removeObjectForKey:url];
        }
    }
    if (_playOrder) {
        [self dropDepartedRowsFromPlayOrder];
    }
    else {
        // Dropping by the removed rows above keeps the cursor on its object,
        // or, for a removed current row, on the survivor that slid in. Written
        // to the ivar: the setter would send a second event for one edit.
        _currentIndex -= [indexes countOfIndexesInRange:NSMakeRange(0, _currentIndex)];
        // Unconditional, not chained to the shift: a cursor that arrived
        // corrupt must still leave in range.
        if (_currentIndex >= _tracks.count) {
            _currentIndex = _tracks.count == 0 ? 0 : _tracks.count - 1;
        }
    }
    [self.observer playlist:self didRemoveTracksAtIndexes:indexes];
    return removed;
}

- (void)insertTracks:(NSArray *)tracks atIndexes:(NSIndexSet *)indexes {
    if (tracks.count == 0 || tracks.count != indexes.count) {
        return;
    }
    id current = self.currentTrack;
    // Past-the-end indexes clamp rather than refuse: a removal's undo can land
    // after later edits shortened the list. Only the clamped case pays the
    // ascending per-row loop, and the event carries the landed set.
    NSUInteger first = MIN(indexes.firstIndex, _tracks.count);
    NSIndexSet *landed = indexes;
    [self unindexRowsFrom:first to:_tracks.count];
    if (indexes.lastIndex < _tracks.count + tracks.count) {
        [_tracks insertObjects:tracks atIndexes:indexes];
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
    [self indexRowsFrom:first to:_tracks.count];
    [self playOrderDidGainTracks:tracks];
    // The cursor follows its object; into an empty list it stays 0. Ivar, not
    // setter: one edit, one event.
    NSInteger resolvedCurrent = [self getIndexForTrack:current];
    if (resolvedCurrent >= 0) {
        _currentIndex = (NSUInteger)resolvedCurrent;
    }
    [self.observer playlist:self didInsertTracksAtIndexes:landed];
}

// After a removal has unindexed its rows. The cursor keeps its object; a
// removed current entry hands the cursor to the next unplayed survivor —
// forwardTrackAfterRemovingTracksAtIndexes:'s answer — else to the last one
// played. Ivar, not setter: one edit, one event.
- (void)dropDepartedRowsFromPlayOrder {
    NSIndexSet *departed = [_playOrder indexesOfObjectsPassingTest:^BOOL(id track, NSUInteger position, BOOL *stop) {
        return [self getIndexForTrack:track] < 0;
    }];
    _playOrderCursor -= [departed countOfIndexesInRange:NSMakeRange(0, _playOrderCursor)];
    [_playOrder removeObjectsAtIndexes:departed];
    _nextPlayOrder = nil;
    if (_playOrder.count == 0) {
        _currentIndex = 0;
        return;
    }
    _playOrderCursor = MIN(_playOrderCursor, _playOrder.count - 1);
    _currentIndex = (NSUInteger)[self getIndexForTrack:_playOrder[_playOrderCursor]];
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
    id current = self.currentTrack;
    NSArray *moved = [_tracks objectsAtIndexes:sourceIndexes];
    NSUInteger first = MIN(sourceIndexes.firstIndex, destinationIndexes.firstIndex);
    NSUInteger end = MAX(sourceIndexes.lastIndex, destinationIndexes.lastIndex) + 1;
    [self unindexRowsFrom:first to:end];
    [_tracks removeObjectsAtIndexes:sourceIndexes];
    [_tracks insertObjects:moved atIndexes:destinationIndexes];
    [self indexRowsFrom:first to:end];
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
