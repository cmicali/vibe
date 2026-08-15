//
//  PageWaveformPipeline.m
//  Vibe (iOS)
//

#import "PageWaveformPipeline.h"
#import "AudioTrack.h"
#import "AudioWaveformCache.h"

@interface PageWaveformPipeline () <AudioWaveformCacheDelegate>
@end

@implementation PageWaveformPipeline {
    AudioWaveformCache *_cache;
    __weak id<PageWaveformPipelineDelegate> _delegate;
    NSMutableDictionary<NSNumber *, CodableAudioWaveform *> *_snapshots;
    NSMutableIndexSet *_completePages;
    // The file the targeted page holds. Deliveries carry the URL they were
    // loaded for, so a decode that outlives its retarget is dropped on the
    // value rather than on the cancel having been observed in time.
    NSURL *_targetURL;
}

- (instancetype)initWithCache:(AudioWaveformCache *)cache
                     delegate:(id<PageWaveformPipelineDelegate>)delegate {
    self = [super init];
    if (self) {
        _cache = cache;
        _cache.delegate = self;
        _delegate = delegate;
        _targetIndex = NSNotFound;
        _snapshots = [NSMutableDictionary dictionary];
        _completePages = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (void)requestIndex:(NSUInteger)index track:(AudioTrack *)track {
    if (!track || _targetIndex == index) {
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
    [_delegate pageWaveformPipeline:self didUpdateWaveform:waveform forIndex:_targetIndex];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    [_delegate pageWaveformPipeline:self didDetectBPM:bpm forURL:url];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url {
    [_delegate pageWaveformPipeline:self didDetectKey:key forURL:url];
}

@end
