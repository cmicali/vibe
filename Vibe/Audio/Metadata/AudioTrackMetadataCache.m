//
//  AudioTrackMetadataCache.m
//  Vibe
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
#import "AudioTrackMetadataLoader+Debug.h"
#endif

@interface AudioTrackMetadataCache ()
@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;
- (instancetype)initWithLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;
+ (NSString *)cacheName;
- (void)setNeighborhoodURLs:(nullable NSArray<NSURL *> *)urls;
@end

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
    // Serializes construction, invalidation and disk usage at utility QoS.
    dispatch_queue_t            _cacheQueue;
    atomic_uint_fast64_t        _cacheGeneration;
    // Kept here, not only on the loader, so a replacement loader inherits them.
    NSArray<NSURL *>            *_neighborhood;
    // Weak: never pins a departed playlist's track.
    __weak AudioTrack           *_lastPrioritizedTrack;
    AudioLoadingConfiguration   *_loadingConfiguration;
}

- (uint64_t)cacheGeneration {
    return atomic_load_explicit(&_cacheGeneration, memory_order_relaxed);
}

+ (NSString *)cacheName {
    // The archive-format version: bump it whenever the archived fields, the
    // rendition or their meaning change, or stale entries live until their
    // cache key changes.
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
        // Off main: constructing on main boosts PINCache's init-time disk scan
        // to user-initiated, which priority-inverts against the utility
        // workers. A loader can run before this lands; it re-reads the
        // property at each use.
        dispatch_async(_cacheQueue, ^{
            self.metadataCache = [PINCache audioCacheWithName:AudioTrackMetadataCache.cacheName rootPath:nil];
        });
    }
    return self;
}

- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration {
    NSParameterAssert(loadingConfiguration);
    if (_loadingConfiguration == loadingConfiguration) {
        return;
    }
    // A loader snapshots its configuration; the next one built uses this.
    _loadingConfiguration = [loadingConfiguration copy];
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    // Serial behind init's construction, so metadataCache is set.
    dispatch_async(_cacheQueue, ^{
        atomic_fetch_add_explicit(&self->_cacheGeneration, 1, memory_order_relaxed);
        [self.metadataCache removeAllObjects];
        if (completion) {
            completion();
        }
    });
}

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    dispatch_async(_cacheQueue, ^{
        [self.metadataCache audioDiskUsageWithCompletion:completion];
    });
}

- (void)cancelScan {
    // Release, not just cancel: the loader holds every queued track.
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
    [loader setNeighborhoodURLs:_neighborhood];
    // Carry the current track's priority across the replacement, which often
    // replaces a pre-sweep single-track loader. Before load:, so stage 1
    // dedupes against it.
    AudioTrack *priorityTrack = _lastPrioritizedTrack;
    if (priorityTrack && !priorityTrack.metadata.parsedOK) {
        [loader prioritizeTrack:priorityTrack];
    }
    [loader load:tracks];
}

- (void)abandonQueuedTrack:(AudioTrack *)track {
    [_currentLoader abandonQueuedTrack:track];
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    _neighborhood = [urls copy];
    [_currentLoader setNeighborhoodURLs:_neighborhood];
}

- (void)setNeighborhoodTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (AudioTrack *track in tracks) {
        if (track.url) {
            [urls addObject:track.url];
        }
    }
    [self setNeighborhoodURLs:urls];
}

#if DEBUG
// Debug/AudioTrackMetadataCache+Debug.h; here because the loader is this file's.
- (NSUInteger)debugPendingBackgroundMaterializationCount {
    return [_currentLoader debugPendingBackgroundMaterializationCount];
}

- (BOOL)debugBackgroundMaterializationHeld {
    // Stopped and settled means no foreground claims, so this must read NO.
    return [AudioFileMaterializationCoordinator.sharedCoordinator
            isForegroundTransferActive];
}

- (NSDictionary *)debugPriorityLaneState {
    return [_currentLoader debugPriorityLaneState] ?: @{};
}

- (NSDictionary *)debugScanLaneState {
    return [_currentLoader debugScanLaneState] ?: @{};
}
#endif

- (void)loadMetadataNow:(AudioTrack *)track {
    if (!track || track.metadata.parsedOK) {
        return;
    }
    _lastPrioritizedTrack = track;
    if (!_currentLoader) {
        // No sweep yet: a loader over this one track, which the sweep
        // replaces wholesale (D10), re-prioritizing the track.
        _currentLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                     loadingConfiguration:_loadingConfiguration];
        [_currentLoader setNeighborhoodURLs:_neighborhood];
    }
    // The delegate may have been wired after the loader was built.
    _currentLoader.delegate = self.delegate;
    [_currentLoader prioritizeTrack:track];
}

@end
