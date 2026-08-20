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

@interface AudioTrackMetadataLoader (CacheRetirement)
- (void)retireWithCompletion:(dispatch_block_t)completion;
@end

#if DEBUG
@interface AudioTrackMetadataLoader (CacheDebug)
- (NSUInteger)debugPendingBackgroundMaterializationCount;
- (NSDictionary *)debugPriorityLaneState;
@end
#endif

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
    // The priority lane, loadMetadataNow:. It normally lives for the
    // cache's lifetime and is never cancelled; applying a new immutable loading
    // configuration retires it after its submitted work. Unlike the scan
    // loaders, its work is per-track and a stale publish is harmless, because
    // the delegate's reloadTrack: and currentTrack checks drop deliveries for
    // departed tracks.
    AudioTrackMetadataLoader*   _priorityLoader;
    // Exists only to construct the cache off the main thread at utility QoS;
    // see init.
    dispatch_queue_t            _cacheQueue;
    // Bumped by invalidateWithCompletion:; see the class-extension comment.
    atomic_uint_fast64_t        _cacheGeneration;
    // The foreground-download hold and scan ranking, kept here
    // rather than only on the loader because loadMetadata: mints a new one:
    // neither a hold set during an open nor the neighborhood the screen last
    // named may be lost by the sweep that open is racing.
    BOOL                        _backgroundMaterializationHeld;
    AudioFileMaterializationHoldToken *_materializationHoldToken;
    NSArray<NSURL *>            *_neighborhood;
    AudioLoadingConfiguration   *_loadingConfiguration;
    // Applying a new immutable configuration takes the priority loader out of
    // service without changing its live queue. A barrier releases it after all
    // work submitted under its old snapshot finishes.
    NSMutableSet<AudioTrackMetadataLoader *> *_retiredPriorityLoaders;
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
        _retiredPriorityLoaders = [NSMutableSet set];
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
    _loadingConfiguration = [loadingConfiguration copy];

    AudioTrackMetadataLoader *retiringLoader = _priorityLoader;
    _priorityLoader = nil;
    if (!retiringLoader) {
        return;
    }
    [_retiredPriorityLoaders addObject:retiringLoader];
    __weak __typeof(self) weakSelf = self;
    __weak AudioTrackMetadataLoader *weakRetiringLoader = retiringLoader;
    [retiringLoader retireWithCompletion:^{
        __typeof(self) strongSelf = weakSelf;
        AudioTrackMetadataLoader *finishedLoader = weakRetiringLoader;
        if (strongSelf && finishedLoader) {
            [strongSelf->_retiredPriorityLoaders removeObject:finishedLoader];
        }
    }];
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
    // that may never come. Duplicate parse waiters are weak, and the priority
    // lane holds only in-flight tracks, so leave both alone.
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
                                                                                  lane:VibeMetadataLaneScan
                                                                   loadingConfiguration:_loadingConfiguration];
    _currentLoader = loader;
    [loader setBackgroundMaterializationHeld:_backgroundMaterializationHeld];
    [loader setNeighborhoodURLs:_neighborhood];
    [loader load:tracks];
}

- (void)setBackgroundMaterializationHeld:(BOOL)held {
    if (held == _backgroundMaterializationHeld) {
        return;
    }
    if (held) {
        _backgroundMaterializationHeld = YES;
        [_currentLoader setBackgroundMaterializationHeld:YES];
        [_priorityLoader setBackgroundMaterializationHeld:YES];
        for (AudioTrackMetadataLoader *loader in _retiredPriorityLoaders.allObjects) {
            [loader setBackgroundMaterializationHeld:YES];
        }
        _materializationHoldToken =
                [AudioFileMaterializationCoordinator.sharedCoordinator acquireMetadataHold];
    }
    else {
        _backgroundMaterializationHeld = NO;
        AudioFileMaterializationHoldToken *token = _materializationHoldToken;
        _materializationHoldToken = nil;
        [token invalidate];
        [_currentLoader setBackgroundMaterializationHeld:NO];
        [_priorityLoader setBackgroundMaterializationHeld:NO];
        // A retired loader can still own a priority request that yielded after
        // didStartPlaying:. Its parked track must drain before retirement ends.
        for (AudioTrackMetadataLoader *loader in _retiredPriorityLoaders.allObjects) {
            [loader setBackgroundMaterializationHeld:NO];
        }
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
    return [_priorityLoader debugPriorityLaneState] ?: @{};
}
#endif

- (void)loadMetadataNow:(AudioTrack *)track {
    if (!track || track.metadata.parsedOK) {
        return;
    }
    if (!_priorityLoader) {
        _priorityLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                                     lane:VibeMetadataLanePriority
                                                      loadingConfiguration:_loadingConfiguration];
        [_priorityLoader setBackgroundMaterializationHeld:_backgroundMaterializationHeld];
    }
    // The scan loaders snapshot the delegate once per loadMetadata:, whereas
    // the long-lived priority loader refreshes it on every call.
    _priorityLoader.delegate = self.delegate;
    [_priorityLoader loadPriorityTrack:track];
}

@end
