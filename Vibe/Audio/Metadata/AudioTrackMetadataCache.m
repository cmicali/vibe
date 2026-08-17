//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <stdatomic.h>

#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataLoader.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MetadataParseCoordinator.h"
#if DEBUG
#import "AudioTrackMetadataCache+Debug.h"   // the loader's debug selector, declared there
#endif

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
    // The current-track lane, loadMetadataNow:. It lives for the cache's
    // lifetime and is never cancelled. Unlike the scan loaders, its work is
    // per-track and a stale publish is harmless, because the delegate's
    // reloadTrack: and currentTrack checks drop deliveries for departed tracks.
    AudioTrackMetadataLoader*   _priorityLoader;
    // Exists only to construct the cache off the main thread at utility QoS;
    // see init.
    dispatch_queue_t            _cacheQueue;
    // Bumped by invalidateWithCompletion:; see the class-extension comment.
    atomic_uint_fast64_t        _cacheGeneration;
    // The foreground-download hold and the cloud lane's ranking, kept here
    // rather than only on the loader because loadMetadata: mints a new one:
    // neither a hold set during an open nor the neighborhood the screen last
    // named may be lost by the sweep that open is racing.
    BOOL                        _cloudParsesHeld;
    NSArray<NSURL *>            *_neighborhood;
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
    return @"Audio Track Metadata v5";
}

- (instancetype)init {
    self = [super init];
    if (self) {
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

- (void)cancelAll {
    // Release it, rather than merely cancelling. _queuedTracks strongly holds
    // every queued track, pinning the old playlist until a next loadMetadata:
    // that may never come. Duplicate parse waiters are weak, and the priority
    // lane holds only in-flight tracks, so leave both alone.
    [_currentLoader cancel];
    _currentLoader = nil;
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    [self cancelAll];
    if (!tracks.count) {
        return;
    }
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                              delegate:self.delegate
                                                                                  lane:VibeMetadataLaneScan];
    _currentLoader = loader;
    [loader setCloudParsesHeld:_cloudParsesHeld];
    [loader setNeighborhoodURLs:_neighborhood];
    [loader load:tracks];
}

- (void)setCloudParsesHeld:(BOOL)held {
    if (held == _cloudParsesHeld) {
        return;
    }
    _cloudParsesHeld = held;
    LogInfo(@"Metadata cloud lane %@", held ? @"held" : @"released");
    [_currentLoader setCloudParsesHeld:held];
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    _neighborhood = [urls copy];
    [_currentLoader setNeighborhoodURLs:_neighborhood];
}

- (void)prependNeighborhoodURL:(NSURL *)url {
    if (!url) {
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithObject:url];
    for (NSURL *existing in _neighborhood) {
        if (![existing isEqual:url]) {
            [urls addObject:existing];
        }
    }
    [self setNeighborhoodURLs:urls];
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
- (NSUInteger)debugPendingCloudParseCount {
    return [_currentLoader debugPendingCloudParseCount];
}

- (BOOL)debugCloudParsesHeld {
    return _cloudParsesHeld;
}
#endif

- (void)loadMetadataNow:(AudioTrack *)track {
    if (!track || track.metadata.parsedOK) {
        return;
    }
    if (!_priorityLoader) {
        _priorityLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                                     lane:VibeMetadataLaneCurrentTrack];
    }
    // The scan loaders snapshot the delegate once per loadMetadata:, whereas
    // the long-lived priority loader refreshes it on every call.
    _priorityLoader.delegate = self.delegate;
    [_priorityLoader loadSingleTrack:track];
}

@end
