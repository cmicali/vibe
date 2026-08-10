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
    // appendURLs: extends it; rows never move otherwise, so the recorded
    // indexes stay valid.
    NSMapTable<AudioTrack *, NSNumber *> *_trackIndexes;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tracks = [NSMutableArray new];
        _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
        _currentIndex = 0;
    }
    return self;
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
    _tracks = [NSMutableArray new];
    _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
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

// Appends tracks for urls to _tracks, recording each one's row.
- (void)addTracksForURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        AudioTrack *track = [AudioTrack withURL:url];
        [_trackIndexes setObject:@(_tracks.count) forKey:track];
        [_tracks addObject:track];
    }
}

- (void)clear {
    _tracks = [NSMutableArray new];
    _trackIndexes = [NSMapTable strongToStrongObjectsMapTable];
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
    return index ? index.integerValue : -1;
}

- (NSIndexSet *)indexesOfTracksWithURL:(NSURL *)url {
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    if (!url) {
        return indexes;
    }
    [_tracks enumerateObjectsUsingBlock:^(AudioTrack *track, NSUInteger index, BOOL *stop) {
        if ([track.url isEqual:url]) {
            [indexes addIndex:index];
        }
    }];
    return indexes;
}

- (AudioTrack *)trackForURL:(NSURL *)url {
    if (!url) {
        return nil;
    }
    for (AudioTrack *track in _tracks) {
        if ([track.url isEqual:url]) {
            return track;
        }
    }
    return nil;
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
    // Remove the outgoing key: entries are never otherwise removed, and a
    // departed track still resolving to this row would let its late metadata
    // delivery redraw a row it no longer occupies.
    [_trackIndexes removeObjectForKey:outgoing];
    [_trackIndexes setObject:@(index) forKey:incoming];
    _tracks[index] = incoming;
    // currentIndex, being positional, needs no adjustment.
    [self.observer playlist:self didReplaceTrackAtIndex:index];
    return incoming;
}

@end
