//
//  PageWaveformCoordinator.m
//  Vibe (iOS)
//

#import "PageWaveformCoordinator.h"
#import "AudioTrack.h"
#import "AudioWaveformCache.h"
#import "AudioWorkScheduler.h"

@interface PageWaveformCoordinator () <AudioWaveformCacheDelegate>
@end

@implementation PageWaveformCoordinator {
    AudioWaveformCache *_cache;
    __weak id<PageWaveformCoordinatorDelegate> _delegate;
    NSMutableDictionary<NSNumber *, CodableAudioWaveform *> *_snapshots;
    // Each snapshot's delivered fraction, kept and dropped with it, but
    // dropped alone by a failure.
    NSMutableDictionary<NSNumber *, NSNumber *> *_percentLoaded;
    // Deliveries are matched on this, not on the cancel being observed: the
    // target's sourceKey, since cue rows of one file each have a waveform.
    NSString *_targetKey;
    // Owed a forward after the hold; only the latest snapshot per page counts.
    NSMutableIndexSet *_heldUpdates;
    // Owed after the hold; the target clears at once so the settle can retry.
    NSMutableIndexSet *_heldFailures;
    NSMutableDictionary<NSNumber *, AudioTrack *> *_prefetchTracks;
    NSMutableDictionary<NSNumber *, AudioWorkToken *> *_prefetchTokens;
    NSUInteger _prefetchCursor;
}

- (instancetype)initWithCache:(AudioWaveformCache *)cache
                     delegate:(id<PageWaveformCoordinatorDelegate>)delegate {
    self = [super init];
    if (self) {
        _cache = cache;
        _cache.delegate = self;
        _delegate = delegate;
        _targetIndex = NSNotFound;
        _snapshots = [NSMutableDictionary dictionary];
        _percentLoaded = [NSMutableDictionary dictionary];
        _heldUpdates = [NSMutableIndexSet indexSet];
        _heldFailures = [NSMutableIndexSet indexSet];
        _prefetchTracks = [NSMutableDictionary dictionary];
        _prefetchTokens = [NSMutableDictionary dictionary];
        _prefetchCursor = NSNotFound;
    }
    return self;
}

- (void)setHeld:(BOOL)held {
    if (_held == held) {
        return;
    }
    _held = held;
    if (held) {
        return;
    }
    // Dropped requests are NOT replayed: the settle asks for its own page.
    NSMutableIndexSet *owed = _heldUpdates;
    _heldUpdates = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *failed = _heldFailures;
    _heldFailures = [NSMutableIndexSet indexSet];
    [owed enumerateIndexesUsingBlock:^(NSUInteger page, BOOL *stop) {
        CodableAudioWaveform *waveform = self->_snapshots[@(page)];
        if (waveform) {
            [self->_delegate pageWaveformCoordinator:self didUpdateWaveform:waveform forIndex:page];
        }
    }];
    [failed enumerateIndexesUsingBlock:^(NSUInteger page, BOOL *stop) {
        [self->_delegate pageWaveformCoordinator:self didFailWaveformForIndex:page];
    }];
}

- (void)requestIndex:(NSUInteger)index track:(AudioTrack *)track {
    if (_held) {
        return;
    }
    // The source too: the same page can come to hold a DIFFERENT track.
    if (!track || (_targetIndex == index && [_targetKey isEqualToString:track.sourceKey])) {
        return;
    }
    _targetIndex = index;
    _targetKey = track.sourceKey;
    [_cache cancelLoad];
    if ([self isCompleteAtIndex:index] && _snapshots[@(index)]) {
        return;
    }
    [_cache loadWaveformForTrack:track];
}

- (void)prefetchIndex:(NSUInteger)index track:(AudioTrack *)track {
    if (_held || [self isCompleteAtIndex:index] || _prefetchTracks[@(index)] == track) {
        return;
    }
    [_prefetchTokens[@(index)] cancelIfPending];
    _prefetchTracks[@(index)] = track;
    __block __weak AudioWorkToken *requestToken;
    __weak PageWaveformCoordinator *weakSelf = self;
    AudioWorkToken *token = [_cache cachedWaveformForTrack:track completion:^(CodableAudioWaveform *waveform) {
        PageWaveformCoordinator *self = weakSelf;
        if (!self || !requestToken || self->_prefetchTokens[@(index)] != requestToken) {
            return;
        }
        [self->_prefetchTokens removeObjectForKey:@(index)];
        if (!waveform || [self isCompleteAtIndex:index]) {
            return;
        }
        [self storeWaveform:waveform fraction:1 atIndex:index];
    }];
    requestToken = token;
    _prefetchTokens[@(index)] = token;
}

- (void)pruneAroundIndex:(NSUInteger)index {
    static const NSUInteger kKeepRadius = 2;
    if (_prefetchCursor != index) {
        _prefetchCursor = index;
        // Retry misses only when the cursor moves, never on repeated refreshes.
        for (NSNumber *key in _prefetchTracks.allKeys) {
            if (!_prefetchTokens[key] && ![self isCompleteAtIndex:key.unsignedIntegerValue]) {
                [_prefetchTracks removeObjectForKey:key];
            }
        }
    }
    NSMutableSet *pages = [NSMutableSet setWithArray:_snapshots.allKeys];
    [pages addObjectsFromArray:_prefetchTracks.allKeys];
    for (NSNumber *key in pages) {
        NSUInteger page = key.unsignedIntegerValue;
        if (page != _targetIndex
                && (page > index + kKeepRadius || index > page + kKeepRadius)) {
            [_prefetchTokens[key] cancelIfPending];
            [_prefetchTokens removeObjectForKey:key];
            [_prefetchTracks removeObjectForKey:key];
            [_heldUpdates removeIndex:page];
            [_heldFailures removeIndex:page];
            [_snapshots removeObjectForKey:key];
            [_percentLoaded removeObjectForKey:key];
        }
    }
}

- (void)reset {
    for (AudioWorkToken *token in _prefetchTokens.allValues) {
        [token cancelIfPending];
    }
    [_prefetchTokens removeAllObjects];
    _prefetchCursor = NSNotFound;
    [_prefetchTracks removeAllObjects];
    _targetIndex = NSNotFound;
    _targetKey = nil;
    [_snapshots removeAllObjects];
    [_percentLoaded removeAllObjects];
    [_heldUpdates removeAllIndexes];
    [_heldFailures removeAllIndexes];
}

- (CodableAudioWaveform *)snapshotAtIndex:(NSUInteger)index {
    return _snapshots[@(index)];
}

- (BOOL)isCompleteAtIndex:(NSUInteger)index {
    return [self percentLoadedAtIndex:index] >= 1.0f;
}

- (float)percentLoadedAtIndex:(NSUInteger)index {
    return _percentLoaded[@(index)].floatValue;
}

#pragma mark - AudioWaveformCacheDelegate

- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
             forTrack:(AudioTrack *)track {
    if (_targetIndex == NSNotFound || ![track.sourceKey isEqualToString:_targetKey]) {
        return;
    }
    [self storeWaveform:waveform fraction:percentLoaded atIndex:_targetIndex];
}

// Recorded before it is forwarded; held, it is owed after the hold.
- (void)storeWaveform:(CodableAudioWaveform *)waveform
             fraction:(float)fraction
              atIndex:(NSUInteger)index {
    _snapshots[@(index)] = waveform;
    _percentLoaded[@(index)] = @(fraction);
    if (_held) {
        [_heldUpdates addIndex:index];
        return;
    }
    [_delegate pageWaveformCoordinator:self didUpdateWaveform:waveform forIndex:index];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForTrack:(AudioTrack *)track {
    if (_targetIndex == NSNotFound || ![track.sourceKey isEqualToString:_targetKey]) {
        return;
    }
    NSUInteger failedIndex = _targetIndex;
    _targetIndex = NSNotFound;
    _targetKey = nil;
    [_percentLoaded removeObjectForKey:@(failedIndex)];
    if (_held) {
        [_heldFailures addIndex:failedIndex];
        return;
    }
    [_delegate pageWaveformCoordinator:self didFailWaveformForIndex:failedIndex];
}

// Straight through: the track is the match, and the hold does not apply. No
// key twin: key detection is macOS-only.
- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forTrack:(AudioTrack *)track {
    [_delegate pageWaveformCoordinator:self didDetectBPM:bpm forTrack:track];
}

@end
