//
//  CloudTransferRegistry.m
//  Vibe
//

#import "CloudTransferRegistry.h"
#import "CloudTransferRegistryInternal.h"

#import "AudioFileOpenRules.h"
#import "DownloadProgressMonitor.h"

@interface VibeCloudTransferEntry : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) float progress;                 // <0 while indeterminate
@property (nonatomic, strong, nullable) id<VibeCloudTransferMonitor> monitor; // nil: the factory built none
@end

@implementation VibeCloudTransferEntry
@end

@interface DownloadProgressMonitor (VibeCloudTransferMonitor) <VibeCloudTransferMonitor>
@end
@implementation DownloadProgressMonitor (VibeCloudTransferMonitor)
@end

@implementation CloudTransferRegistry {
    NSMutableDictionary<NSString *, VibeCloudTransferEntry *> *_entries;
    VibeCloudTransferMonitorFactory _monitorFactory;
    NSHashTable<id<CloudTransferRegistryObserver>> *_observers;
    BOOL _notifyPending;
}

+ (instancetype)sharedRegistry {
    static CloudTransferRegistry *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CloudTransferRegistry alloc] init];
    });
    return shared;
}

- (instancetype)init {
    return [self initWithMonitorFactory:^id<VibeCloudTransferMonitor>(
            NSURL *url, void (^handler)(float fraction), void (^movement)(void)) {
        return [DownloadProgressMonitor monitorForURL:url movement:movement handler:handler];
    }];
}

- (instancetype)initWithMonitorFactory:(VibeCloudTransferMonitorFactory)monitorFactory {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionary];
        _monitorFactory = [monitorFactory copy];
        _observers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)addObserver:(id<CloudTransferRegistryObserver>)observer {
    NSParameterAssert(NSThread.isMainThread);
    [_observers addObject:observer];
}

- (void)removeObserver:(id<CloudTransferRegistryObserver>)observer {
    NSParameterAssert(NSThread.isMainThread);
    [_observers removeObject:observer];
}

#pragma mark - Reads

- (BOOL)isTransferringURL:(NSURL *)url {
    return [self entryForURL:url] != nil;
}

- (float)progressForURL:(NSURL *)url {
    VibeCloudTransferEntry *entry = [self entryForURL:url];
    return entry ? entry.progress : -1;
}

- (nullable VibeCloudTransferEntry *)entryForURL:(NSURL *)url {
    if (_entries.count == 0) {
        return nil;
    }
    return _entries[VibeStandardizedAudioOpenPath(url)];
}

- (NSDictionary<NSString *, NSNumber *> *)transferSnapshot {
    NSMutableDictionary<NSString *, NSNumber *> *snapshot =
            [NSMutableDictionary dictionaryWithCapacity:_entries.count];
    [_entries enumerateKeysAndObjectsUsingBlock:^(NSString *path,
            VibeCloudTransferEntry *entry, BOOL *stop) {
        snapshot[path] = @(entry.progress);
    }];
    return snapshot;
}

#pragma mark - Writes

- (void)beganTransferForPath:(NSString *)path url:(NSURL *)url {
    NSParameterAssert(NSThread.isMainThread);
    if (_entries[path]) {
        return;
    }
    VibeCloudTransferEntry *entry = [[VibeCloudTransferEntry alloc] init];
    entry.url = url;
    entry.progress = -1;
    _entries[path] = entry;
    __weak CloudTransferRegistry *weakSelf = self;
    entry.monitor = _monitorFactory(url, ^(float fraction) {
        [weakSelf monitorReportedProgress:fraction forPath:path];
    }, ^{
        [weakSelf monitorReportedMovementForPath:path];
    });
    [self scheduleObserverNotification];
}

- (void)endedTransferForPath:(NSString *)path {
    NSParameterAssert(NSThread.isMainThread);
    VibeCloudTransferEntry *entry = _entries[path];
    if (!entry) {
        return;
    }
    [entry.monitor cancel];
    [_entries removeObjectForKey:path];
    [self scheduleObserverNotification];
}

// A non-positive sample is status, not progress: it neither leaves
// indeterminate nor downgrades a fraction already shown.
- (float)displayFraction:(float)fraction over:(float)current {
    return fraction > 0 ? fraction : current;
}

// Both drop a sample already queued to main when the transfer ended.
- (void)monitorReportedProgress:(float)fraction forPath:(NSString *)path {
    VibeCloudTransferEntry *entry = _entries[path];
    if (!entry) {
        return;
    }
    float progress = [self displayFraction:fraction over:entry.progress];
    if (progress == entry.progress) {
        return;
    }
    entry.progress = progress;
    [self scheduleObserverNotification];
}

- (void)monitorReportedMovementForPath:(NSString *)path {
    if (!_entries[path]) {
        return;
    }
    for (id<CloudTransferRegistryObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(cloudTransferRegistry:didMoveTransferForPath:)]) {
            [observer cloudTransferRegistry:self didMoveTransferForPath:path];
        }
    }
}

#pragma mark - Notification

- (void)scheduleObserverNotification {
    if (_notifyPending) {
        return;
    }
    _notifyPending = YES;
    __weak CloudTransferRegistry *weakSelf = self;
    run_on_main_thread({
        CloudTransferRegistry *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_notifyPending = NO;
        for (id<CloudTransferRegistryObserver> observer in strongSelf->_observers.allObjects) {
            [observer cloudTransferRegistryDidChange:strongSelf];
        }
    });
}

@end
