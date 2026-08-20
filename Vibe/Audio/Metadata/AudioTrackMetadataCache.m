//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <stdatomic.h>

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioLoadingConfiguration.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MetadataParseCoordinator.h"
#if DEBUG
#import "AudioTrackMetadataCache+Debug.h"
#endif

@interface AudioTrackMetadataCache ()
@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;
- (instancetype)initWithLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;
+ (NSString *)cacheName;
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
@end

#if DEBUG
@interface AudioTrackMetadataLoader (CacheDebug)
- (NSUInteger)debugPendingBackgroundMaterializationCount;
- (NSDictionary *)debugPriorityLaneState;
@end
#endif

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
    // Exists only to construct the cache off the main thread at utility QoS;
    // see init.
    dispatch_queue_t            _cacheQueue;
    // Bumped by invalidateWithCompletion:; see the class-extension comment.
    atomic_uint_fast64_t        _cacheGeneration;
    // The foreground-download hold, scan ranking, and current-track priority,
    // kept here rather than only on the loader because loadMetadata: mints a
    // new one: neither a hold set during an open, nor the neighborhood the
    // screen last named, nor the priority of the track the user is waiting on
    // may be lost by the sweep that open is racing.
    BOOL                        _backgroundMaterializationHeld;
    AudioFileMaterializationHoldToken *_materializationHoldToken;
    NSArray<NSURL *>            *_neighborhood;
    // Weak on purpose: re-prioritizing is best-effort continuity across a
    // loader replacement, never a reason to pin a departed playlist's track.
    __weak AudioTrack           *_lastPrioritizedTrack;
    AudioLoadingConfiguration   *_loadingConfiguration;
}

- (uint64_t)cacheGeneration {
    return atomic_load_explicit(&_cacheGeneration, memory_order_relaxed);
}

+ (NSString *)cacheName {
    // The name embeds the archive-format version. Bump it whenever the
    // archived fields or their meaning change, as fileType labeling did, since
    // stale entries otherwise persist until the size-and-mtime cache key
    // changes, which can take up to the age limit.
    // v5: the tagged musical key joined the archive; older entries would
    // otherwise show no key until their cache key changed.
    // v6: display-art sidecar entries ("#displayArt"-suffixed keys) joined the
    // store; without them the display surfaces fall back to re-reading the
    // audio file, so old stores re-parse rather than staying slow.
    // v7: the sidecar became per-platform-sized (640 mac, 1024 iOS) and iOS
    // started reading it; v6 stores carry none on iOS and 640s on mac.
    return @"Audio Track Metadata v7";
}

- (instancetype)init {
    return [self initWithLoadingConfiguration:
            [AudioLoadingConfiguration productionConfiguration]];
}

- (instancetype)initWithLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    self = [super init];
    if (self) {
        NSParameterAssert(loadingConfiguration);
        _loadingConfiguration = [loadingConfiguration copy];
        _currentLoader = nil;
        _parseCoordinator = [[MetadataParseCoordinator alloc] init];
        _cacheQueue = dispatch_queue_create("com.vibe.metadatacache",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // Create the cache at utility QoS. Constructing it on the main thread
        // boosts PINCache's internal init-time disk scan to user-initiated,
        // which then priority-inverts against the utility worker ops, and the
        // Thread Performance Checker warns about it on the first drop.
        // Metadata loading usually starts well after init, since it is
        // deferred until playback begins, but a launch by double-click can
        // beat this block. The loader re-reads the property at each use.
        dispatch_async(_cacheQueue, ^{
            // Why the memory cache goes unused is with the shared policy.
            self.metadataCache = [PINCache audioCacheWithName:AudioTrackMetadataCache.cacheName];
        });
    }
    return self;
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    if (_loadingConfiguration == loadingConfiguration) {
        return;
    }
    // A loader snapshots its configuration; the next loadMetadata: (or the
    // next pre-sweep loadMetadataNow:) builds under the new one. Nothing to
    // retire: priority work lives in the current loader and dies with it.
    _loadingConfiguration = [loadingConfiguration copy];
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    // The queue is serial, so this runs after the deferred cache construction
    // in init and self.metadataCache is always set when this block executes.
    dispatch_async(_cacheQueue, ^{
        atomic_fetch_add_explicit(&self->_cacheGeneration, 1, memory_order_relaxed);
        [self.metadataCache removeAllObjects];
        if (completion) {
            completion();
        }
    });
}

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    // The serial queue guarantees the cache exists and keeps the blocking
    // enumeration off the caller's thread.
    dispatch_async(_cacheQueue, ^{
        [self.metadataCache audioDiskUsageWithCompletion:completion];
    });
}

- (void)cancelScan {
    // Release it, rather than merely cancelling. _queuedTracks strongly holds
    // every queued track, pinning the old playlist until a next loadMetadata:
    // that may never come. The current track's priority record dies with the
    // loader too — replacement drops everything, the guarantee's J1 half —
    // and duplicate parse waiters are weak, so leave those alone.
    [_currentLoader cancel];
    _currentLoader = nil;
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    [self cancelScan];
    if (!tracks.count) {
        return;
    }
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                              delegate:self.delegate
                                                                   loadingConfiguration:_loadingConfiguration];
    _currentLoader = loader;
    [loader setBackgroundMaterializationHeld:_backgroundMaterializationHeld];
    [loader setNeighborhoodURLs:_neighborhood];
    // Carry the current track's priority across the replacement: the shells'
    // loadMetadataNow: often lands on the loader this one replaces (the
    // single-track loader a pre-sweep prioritization built), and the track
    // the user is waiting on must not restart as an ordinary row. Weak and
    // re-checked, so a departed track re-prioritizes nothing. Before load:,
    // so the sweep's stage 1 dedupes against it rather than racing it.
    AudioTrack *priorityTrack = _lastPrioritizedTrack;
    if (priorityTrack && !priorityTrack.metadata.parsedOK) {
        [loader prioritizeTrack:priorityTrack];
    }
    [loader load:tracks];
}

- (void)setBackgroundMaterializationHeld:(BOOL)held {
    if (held == _backgroundMaterializationHeld) {
        return;
    }
    if (held) {
        _backgroundMaterializationHeld = YES;
        [_currentLoader setBackgroundMaterializationHeld:YES];
        _materializationHoldToken =
                [AudioFileMaterializationCoordinator.sharedCoordinator acquireMetadataHold];
    }
    else {
        _backgroundMaterializationHeld = NO;
        AudioFileMaterializationHoldToken *token = _materializationHoldToken;
        _materializationHoldToken = nil;
        [token invalidate];
        [_currentLoader setBackgroundMaterializationHeld:NO];
    }
    LogInfo(@"Metadata content lane %@", held ? @"held" : @"released");
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    _neighborhood = [urls copy];
    [_currentLoader setNeighborhoodURLs:_neighborhood];
}

// The tracks the listener reaches soonest, in the order they reach them: the
// next one, the one after it, then the one behind — a back-skip is the fourth
// thing a hand does, not the first.
static const NSInteger kNeighborhoodOffsets[] = {1, 2, -1};

- (void)setNeighborhoodAroundIndex:(NSUInteger)index inTracks:(NSArray<AudioTrack *> *)tracks {
    NSInteger current = (NSInteger)index;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < sizeof(kNeighborhoodOffsets) / sizeof(*kNeighborhoodOffsets); i++) {
        NSInteger neighbor = current + kNeighborhoodOffsets[i];
        if (neighbor < 0 || (NSUInteger)neighbor >= tracks.count) {
            continue;
        }
        NSURL *url = tracks[(NSUInteger)neighbor].url;
        if (url) {
            [urls addObject:url];
        }
    }
    [self setNeighborhoodURLs:urls];
}

#if DEBUG
// Declared in Debug/AudioTrackMetadataCache+Debug.h; implemented here because
// the loader and the hold flag are this file's.
- (NSUInteger)debugPendingBackgroundMaterializationCount {
    return [_currentLoader debugPendingBackgroundMaterializationCount];
}

- (BOOL)debugBackgroundMaterializationHeld {
    return _backgroundMaterializationHeld;
}

- (NSDictionary *)debugPriorityLaneState {
    return [_currentLoader debugPriorityLaneState] ?: @{};
}
#endif

- (void)loadMetadataNow:(AudioTrack *)track {
    if (!track || track.metadata.parsedOK) {
        return;
    }
    _lastPrioritizedTrack = track;
    if (!_currentLoader) {
        // No sweep yet — the deferred load has not fired, or none is coming.
        // A loader with just this track carries the record whose retries D3
        // depends on; the real playlist sweep replaces it wholesale (D10) and
        // loadMetadata: re-prioritizes the track on the replacement.
        _currentLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                     loadingConfiguration:_loadingConfiguration];
        [_currentLoader setBackgroundMaterializationHeld:_backgroundMaterializationHeld];
        [_currentLoader setNeighborhoodURLs:_neighborhood];
    }
    // A loader snapshots the delegate at creation; refresh it here because
    // prioritization can outlive the delegate wiring that existed then.
    _currentLoader.delegate = self.delegate;
    [_currentLoader prioritizeTrack:track];
}

@end
