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
    // The file the targeted page holds. Deliveries carry the URL they were
    // loaded for, so a decode that outlives its retarget is dropped on the
    // value rather than on the cancel having been observed in time.
    NSURL *_targetURL;
    // Pages whose snapshot moved while the scroll hold was on, owed a forward
    // when it comes off. An index set, not a queue: only the latest snapshot
    // per page is worth painting.
    NSMutableIndexSet *_heldUpdates;
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
    // Paint what arrived during the hold. The dropped requests are deliberately
    // NOT replayed: they were for pages the drag passed over, and the settle
    // that releases the hold asks for the page it actually landed on.
    NSMutableIndexSet *owed = _heldUpdates;
    _heldUpdates = [NSMutableIndexSet indexSet];
    [owed enumerateIndexesUsingBlock:^(NSUInteger page, BOOL *stop) {
        CodableAudioWaveform *waveform = self->_snapshots[@(page)];
        if (waveform) {
            [self->_delegate pageWaveformCoordinator:self didUpdateWaveform:waveform forIndex:page];
        }
    }];
}

- (void)requestIndex:(NSUInteger)index track:(AudioTrack *)track {
    if (_held) {
        return;
    }
    // The URL is part of the identity, not just the index: a page already
    // targeted can come to hold a DIFFERENT file, and matching on the index
    // alone would leave that load pointed at the old one. It was safe only
    // because every playlist replacement happens to call reset first — a
    // guarantee held by a caller in another file and written down in neither.
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
    // A load started before the drag keeps delivering through it. Record it —
    // a page coming into view still hydrates from the newest snapshot — but do
    // not repaint until the scroll settles.
    if (_held) {
        [_heldUpdates addIndex:_targetIndex];
        return;
    }
    [_delegate pageWaveformCoordinator:self didUpdateWaveform:waveform forIndex:_targetIndex];
}

// audioWaveformCache:didDetectBPM:forURL: and its key twin are optional and
// deliberately unimplemented: analysis is macOS-only, so the cache never fires
// them here. See the delegate protocol.

@end
