//
//  PageWaveformCoordinator.m
//  Vibe (iOS)
//

#import "PageWaveformCoordinator.h"
#import "AudioTrack.h"
#import "AudioWaveformCache.h"

@interface PageWaveformCoordinator () <AudioWaveformCacheDelegate>
@end

@implementation PageWaveformCoordinator {
    AudioWaveformCache *_cache;
    __weak id<PageWaveformCoordinatorDelegate> _delegate;
    NSMutableDictionary<NSNumber *, CodableAudioWaveform *> *_snapshots;
    NSMutableIndexSet *_completePages;
    // Deliveries are matched on this, not on the cancel being observed.
    NSURL *_targetURL;
    // Owed a forward after the hold; only the latest snapshot per page counts.
    NSMutableIndexSet *_heldUpdates;
    // Owed after the hold; the target clears at once so the settle can retry.
    NSMutableIndexSet *_heldFailures;
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
        _completePages = [NSMutableIndexSet indexSet];
        _heldUpdates = [NSMutableIndexSet indexSet];
        _heldFailures = [NSMutableIndexSet indexSet];
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
    // The URL too: the same page can come to hold a DIFFERENT file.
    if (!track || (_targetIndex == index && [_targetURL isEqual:track.url])) {
        return;
    }
    _targetIndex = index;
    _targetURL = track.url;
    [_cache cancelLoad];
    if ([_completePages containsIndex:index] && _snapshots[@(index)]) {
        return;
    }
    [_completePages removeIndex:index];
    [_cache loadWaveformForTrack:track];
}

- (void)pruneAroundIndex:(NSUInteger)index {
    static const NSUInteger kKeepRadius = 2;
    for (NSNumber *key in _snapshots.allKeys) {
        NSUInteger page = key.unsignedIntegerValue;
        if (page != _targetIndex
                && (page > index + kKeepRadius || index > page + kKeepRadius)) {
            [_snapshots removeObjectForKey:key];
            [_completePages removeIndex:page];
        }
    }
}

- (void)reset {
    _targetIndex = NSNotFound;
    _targetURL = nil;
    [_snapshots removeAllObjects];
    [_completePages removeAllIndexes];
    [_heldUpdates removeAllIndexes];
    [_heldFailures removeAllIndexes];
}

- (CodableAudioWaveform *)snapshotAtIndex:(NSUInteger)index {
    return _snapshots[@(index)];
}

- (BOOL)isCompleteAtIndex:(NSUInteger)index {
    return [_completePages containsIndex:index];
}

#pragma mark - AudioWaveformCacheDelegate

- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
               forURL:(NSURL *)url {
    if (_targetIndex == NSNotFound || ![url isEqual:_targetURL]) {
        return;
    }
    _snapshots[@(_targetIndex)] = waveform;
    if (percentLoaded >= 1.0f) {
        [_completePages addIndex:_targetIndex];
    }
    if (_held) {
        [_heldUpdates addIndex:_targetIndex];
        return;
    }
    [_delegate pageWaveformCoordinator:self didUpdateWaveform:waveform forIndex:_targetIndex];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didFailToLoadForURL:(NSURL *)url {
    if (_targetIndex == NSNotFound || ![url isEqual:_targetURL]) {
        return;
    }
    NSUInteger failedIndex = _targetIndex;
    _targetIndex = NSNotFound;
    _targetURL = nil;
    [_completePages removeIndex:failedIndex];
    if (_held) {
        [_heldFailures addIndex:failedIndex];
        return;
    }
    [_delegate pageWaveformCoordinator:self didFailWaveformForIndex:failedIndex];
}

@end
