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
    // The last component of every key, so a read can rule a URL out without
    // standardizing it (entryForURL:).
    NSCountedSet<NSString *> *_fileNames;
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
        _fileNames = [NSCountedSet set];
        _monitorFactory = [monitorFactory copy];
    }
    return self;
}

#pragma mark - Reads

- (BOOL)isTransferringURL:(NSURL *)url {
    return [self entryForURL:url] != nil;
}

- (float)progressForURL:(NSURL *)url {
    VibeCloudTransferEntry *entry = [self entryForURL:url];
    return entry ? entry.progress : -1;
}

// TRAP: VibeStandardizedAudioOpenPath is not free. URLByStandardizingPath
// stats the file to strip a /private prefix, and every cloud path has one
// (/private/var/mobile/Library/CloudStorage/...), so a list row asking for its
// loading state paid two stats on main — 81% of an iOS library cell's render,
// measured. Standardizing never changes a file path's last component unless
// that component is "." or "..", so a name no key ends in is not transferring,
// and the common case, nothing in flight, costs nothing.
- (nullable VibeCloudTransferEntry *)entryForURL:(NSURL *)url {
    if (_entries.count == 0) {
        return nil;
    }
    NSString *name = url.lastPathComponent;
    if (url.isFileURL && name.length && ![name isEqualToString:@"."] && ![name isEqualToString:@".."]
            && ![_fileNames containsObject:name]) {
        return nil;
    }
    NSString *path = VibeStandardizedAudioOpenPath(url);
    return path ? _entries[path] : nil;
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
    [_fileNames addObject:path.lastPathComponent];
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
    [_fileNames removeObject:path.lastPathComponent];
    [self scheduleObserverNotification];
}

// A zero (or negative) sample is the provider's initial-status shape, not
// progress: the row stays indeterminate until the provider demonstrates real
// movement, and a stray non-positive sample after that never downgrades a
// fraction already shown.
- (float)displayFraction:(float)fraction over:(float)current {
    return fraction > 0 ? fraction : current;
}

- (void)monitorReportedProgress:(float)fraction forPath:(NSString *)path {
    VibeCloudTransferEntry *entry = _entries[path];
    // A cancelled monitor delivers nothing, but the entry check also drops a
    // fraction already in flight to main when the transfer ended under it.
    if (!entry || entry.externallyFed) {
        return;
    }
    entry.progress = [self displayFraction:fraction over:entry.progress];
    [self scheduleObserverNotification];
}

- (void)noteProgress:(float)fraction forURL:(NSURL *)url {
    NSParameterAssert(NSThread.isMainThread);
    VibeCloudTransferEntry *entry = [self entryForURL:url];
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
    entry.progress = [self displayFraction:fraction over:entry.progress];
    [self scheduleObserverNotification];
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
        [strongSelf.observer cloudTransferRegistryDidChange:strongSelf];
    });
}

@end
