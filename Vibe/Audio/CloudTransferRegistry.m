//
//  CloudTransferRegistry.m
//  Vibe
//
//  See the header. Everything here runs on main; the coordinator's edges
//  arrive by dispatch_async from its state queue, FIFO, so an end-then-begin
//  restart cannot marshal out of order.
//

#import "CloudTransferRegistry.h"
#import "CloudTransferRegistryInternal.h"

#import "AudioFileOpenRules.h"
#import "DownloadProgressMonitor.h"

// One transfer's registry-side state. The monitor is nil when the shell's own
// monitor feeds this path through noteProgress:forURL:, or when the factory
// could not build one — both read as indeterminate until a fraction lands.
@interface VibeCloudTransferEntry : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) float progress;                 // <0 while indeterminate
@property (nonatomic, strong, nullable) id<VibeCloudTransferMonitor> monitor;
@property (nonatomic) BOOL externallyFed;
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
    // The production factory only paints: currentURL pins the fraction to the
    // path's own URL, and movement is nil because the open's abandon deadline
    // is fed by the shell's monitor and must not be extended from here.
    return [self initWithMonitorFactory:^id<VibeCloudTransferMonitor>(
            NSURL *url, void (^handler)(float fraction)) {
        return [DownloadProgressMonitor monitorReplacing:nil
                                                  forURL:url
                                              currentURL:^NSURL * { return url; }
                                                movement:nil
                                                 handler:handler];
    }];
}

- (instancetype)initWithMonitorFactory:(VibeCloudTransferMonitorFactory)monitorFactory {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionary];
        _monitorFactory = [monitorFactory copy];
    }
    return self;
}

#pragma mark - Reads

- (BOOL)isTransferringURL:(NSURL *)url {
    NSString *path = VibeStandardizedAudioOpenPath(url);
    return path != nil && _entries[path] != nil;
}

- (float)progressForURL:(NSURL *)url {
    NSString *path = VibeStandardizedAudioOpenPath(url);
    VibeCloudTransferEntry *entry = path ? _entries[path] : nil;
    return entry ? entry.progress : -1;
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
        return; // an end-then-begin restart re-begins through endedTransferForPath: first
    }
    VibeCloudTransferEntry *entry = [[VibeCloudTransferEntry alloc] init];
    entry.url = url;
    entry.progress = -1;
    _entries[path] = entry;
    __weak CloudTransferRegistry *weakSelf = self;
    entry.monitor = _monitorFactory(url, ^(float fraction) {
        [weakSelf monitorReportedProgress:fraction forPath:path];
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

- (void)monitorReportedProgress:(float)fraction forPath:(NSString *)path {
    VibeCloudTransferEntry *entry = _entries[path];
    // A cancelled monitor delivers nothing, but the entry check also drops a
    // fraction already in flight to main when the transfer ended under it.
    if (!entry || entry.externallyFed) {
        return;
    }
    entry.progress = fraction;
    [self scheduleObserverNotification];
}

- (void)noteProgress:(float)fraction forURL:(NSURL *)url {
    NSParameterAssert(NSThread.isMainThread);
    NSString *path = VibeStandardizedAudioOpenPath(url);
    VibeCloudTransferEntry *entry = path ? _entries[path] : nil;
    if (!entry) {
        return;
    }
    if (!entry.externallyFed) {
        // The shell's own monitor owns this path now; the registry's would be
        // a second NSMetadataQuery and File Provider subscription on the same
        // file. Cancel rather than merely ignore, so nothing keeps observing.
        entry.externallyFed = YES;
        [entry.monitor cancel];
        entry.monitor = nil;
    }
    entry.progress = fraction;
    [self scheduleObserverNotification];
}

#pragma mark - Notification

- (void)scheduleObserverNotification {
    if (_notifyPending) {
        return;
    }
    _notifyPending = YES;
    __weak CloudTransferRegistry *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CloudTransferRegistry *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_notifyPending = NO;
        [strongSelf.observer cloudTransferRegistryDidChange:strongSelf];
    });
}

@end
