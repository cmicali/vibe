//
//  VibeFakeHTTP.m
//  Vibe
//

#if DEBUG

#import "VibeFakeHTTP.h"

#import <os/lock.h>
#import <sys/stat.h>

#import "HTTPTransferClientInternal.h"

static const uint64_t kPieceBytes = 64 * 1024;
static const NSUInteger kLogLimit = 200;
static const NSTimeInterval kStallPollSeconds = 0.1;
static const NSTimeInterval kLostConnectionPollSeconds = 0.005;
static const NSTimeInterval kLostConnectionWaitSeconds = 2;

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSString *sRootPath;
static __weak HTTPTransferClient *sClient;
static NSTimeInterval sTransferSeconds;
static CFAbsoluteTime sInstallTime;
static NSUInteger sRequests;
static NSMutableArray<NSMutableDictionary *> *sFaults;
// Each request's line, updated as it proceeds. Under sLock. statistics
// copies it out.
static NSMutableArray<NSMutableDictionary *> *sLog;
static NSUInteger sLogSequence;
// How many times etag-change moved each file's version, by its path under
// the root.
static NSMutableDictionary<NSString *, NSNumber *> *sVersions;
// Pieces of a body are delivered here, never on CFNetwork's protocol thread:
// a wait there would queue every other request behind it and hold a cancel
// until the whole file had gone out.
static dispatch_queue_t sDeliveryQueue;

static NSArray<NSString *> *VibeFakeHTTPFaultKinds(void) {
    return @[@"stall", @"drop", @"etag-change", @"rate", @"latency", @"no-range", @"no-length", @"icy",
             @"status", @"html", @"gzip"];
}

// A held or throttled body is one state, not one change. It lasts.
static BOOL VibeFakeHTTPFaultIsOnce(NSString *kind, NSNumber *once) {
    if ([kind isEqualToString:@"stall"] || [kind isEqualToString:@"rate"]) {
        return NO;
    }
    return once ? once.boolValue : [kind isEqualToString:@"drop"] || [kind isEqualToString:@"etag-change"];
}

static BOOL VibeFakeHTTPServesHost(NSString *host) {
    NSString *name = host.lowercaseString;
    return [name isEqualToString:@"fake.vibe.test"] || [name isEqualToString:@"fake.local"];
}

static double VibeFakeHTTPNow(void) {
    return round((CFAbsoluteTimeGetCurrent() - sInstallTime) * 1000) / 1000;
}

static NSString *VibeFakeHTTPContentType(NSString *extension) {
    static NSDictionary<NSString *, NSString *> *types;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        types = @{@"mp3": @"audio/mpeg", @"mp2": @"audio/mpeg", @"m4a": @"audio/mp4", @"mp4": @"audio/mp4",
                  @"m4b": @"audio/mp4", @"aac": @"audio/aac", @"flac": @"audio/flac", @"wav": @"audio/wav",
                  @"aif": @"audio/aiff", @"aiff": @"audio/aiff", @"caf": @"audio/x-caf", @"ogg": @"audio/ogg",
                  @"oga": @"audio/ogg", @"opus": @"audio/ogg", @"html": @"text/html", @"txt": @"text/plain"};
    });
    return types[extension.lowercaseString] ?: @"application/octet-stream";
}

static NSString *VibeFakeHTTPDate(time_t seconds) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
    });
    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]];
    }
}

// The first fault of `kind` for the file of that basename. Under sLock.
static NSMutableDictionary *VibeFakeHTTPFault(NSString *kind, NSString *name) {
    for (NSMutableDictionary *fault in sFaults) {
        NSString *file = fault[@"file"];
        if ([fault[@"kind"] isEqualToString:kind]
                && (!file || (name && [file caseInsensitiveCompare:name] == NSOrderedSame))) {
            return fault;
        }
    }
    return nil;
}

// A fault that changed this request: logged on its line, and gone if it
// lasts once. Under sLock.
static void VibeFakeHTTPApply(NSMutableDictionary *fault, NSMutableDictionary *entry) {
    [entry[@"faults"] addObject:fault[@"kind"]];
    if ([fault[@"once"] boolValue]) {
        [sFaults removeObjectIdenticalTo:fault];
    }
}

// What a file answers as: its size, and the headers naming its version.
typedef struct {
    uint64_t size;
    NSString *etag;
    NSString *lastModified;
} VibeFakeHTTPVersion;

// Under sLock.
static VibeFakeHTTPVersion VibeFakeHTTPVersionOf(NSString *relativePath, const struct stat *info) {
    NSUInteger moved = sVersions[relativePath].unsignedIntegerValue;
    time_t modified = info->st_mtimespec.tv_sec + (time_t)moved;
    return (VibeFakeHTTPVersion){
        (uint64_t)info->st_size,
        [NSString stringWithFormat:@"\"%llx-%lx-%lx\"", (unsigned long long)info->st_size, (long)modified,
                                   (unsigned long)moved],
        VibeFakeHTTPDate(modified),
    };
}

typedef struct {
    NSInteger status;
    NSDictionary<NSString *, NSString *> *headers;
    NSData *body;
} VibeFakeHTTPAnswer;

@interface VibeFakeHTTPProtocol : NSURLProtocol
@property (atomic) BOOL cancelled;
// This request's log line. Mutated under sLock.
@property (nonatomic) NSMutableDictionary *entry;
@end

@implementation VibeFakeHTTPProtocol {
    NSThread *_loader;
    NSArray<NSRunLoopMode> *_modes;
}

// Installed on sessions the client alone owns. Every request is the fake's.
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

// The client is told on the thread that started the load, as NSURLProtocol
// asks, never on the delivery queue.
- (void)tellClient:(dispatch_block_t)block {
    [self performSelector:@selector(runOnLoader:) onThread:_loader withObject:[block copy] waitUntilDone:NO
                    modes:_modes];
}

- (void)runOnLoader:(dispatch_block_t)block {
    if (!self.cancelled) {
        block();
    }
}

- (void)startLoading {
    _loader = NSThread.currentThread;
    NSMutableArray<NSRunLoopMode> *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    NSRunLoopMode mode = NSRunLoop.currentRunLoop.currentMode;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode]) {
        [modes addObject:mode];
    }
    _modes = modes;
    NSURL *url = self.request.URL;
    NSString *range = [self.request valueForHTTPHeaderField:@"Range"];
    unsigned long long first = 0, last = ULLONG_MAX;
    BOOL ranged = range && sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last) >= 1;
    BOOL closed = ranged && ![range hasSuffix:@"-"];

    os_unfair_lock_lock(&sLock);
    sRequests++;
    NSMutableDictionary *entry = [@{@"seq": @(++sLogSequence), @"t": @(VibeFakeHTTPNow()),
                                    @"host": url.host ?: @"", @"path": url.path ?: @"",
                                    @"range": range ?: NSNull.null, @"status": @0, @"delivered": @0,
                                    @"faults": [NSMutableArray array], @"outcome": @"running"} mutableCopy];
    [sLog addObject:entry];
    if (sLog.count > kLogLimit) {
        [sLog removeObjectAtIndex:0];
    }
    self.entry = entry;
    NSString *root = sRootPath;
    if (!root || !VibeFakeHTTPServesHost(url.host)) {
        entry[@"outcome"] = @"unknown-host";
        entry[@"finished"] = @(VibeFakeHTTPNow());
        os_unfair_lock_unlock(&sLock);
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorCannotFindHost
                                                                       userInfo:nil]];
        return;
    }
    NSString *path = [root stringByAppendingPathComponent:url.path ?: @""].stringByStandardizingPath;
    NSString *relativePath = [path hasPrefix:[root stringByAppendingString:@"/"]]
            ? [path substringFromIndex:root.length] : nil;
    NSString *name = path.lastPathComponent;
    struct stat info;
    BOOL found = relativePath && stat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode);
    VibeFakeHTTPVersion version = found ? VibeFakeHTTPVersionOf(relativePath, &info) : (VibeFakeHTTPVersion){0};
    NSTimeInterval latency = 0;
    NSMutableDictionary *fault = VibeFakeHTTPFault(@"latency", name);
    if (fault) {
        latency = [fault[@"seconds"] doubleValue];
        VibeFakeHTTPApply(fault, entry);
    }
    VibeFakeHTTPAnswer refusal = {0, nil, nil};
    if ((fault = VibeFakeHTTPFault(@"status", name))) {
        NSInteger status = [fault[@"status"] integerValue];
        refusal = (VibeFakeHTTPAnswer){status, @{@"Content-Type": @"text/plain"},
                                       [[NSString stringWithFormat:@"HTTP %ld", (long)status]
                                               dataUsingEncoding:NSUTF8StringEncoding]};
        VibeFakeHTTPApply(fault, entry);
    }
    else if ((fault = VibeFakeHTTPFault(@"html", name))) {
        refusal = (VibeFakeHTTPAnswer){200, @{@"Content-Type": @"text/html; charset=utf-8"},
                                       [@"<!doctype html><html><head><title>Vibe</title></head>"
                                        @"<body>Not a song.</body></html>" dataUsingEncoding:NSUTF8StringEncoding]};
        VibeFakeHTTPApply(fault, entry);
    }
    else if (!found) {
        refusal = (VibeFakeHTTPAnswer){404, @{@"Content-Type": @"text/plain"},
                                       [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding]};
    }
    // A shape a server with no ranges, no length or a compressor answers in.
    NSString *shape = nil;
    for (NSString *kind in @[@"icy", @"no-length", @"gzip", @"no-range"]) {
        if (!refusal.status && (fault = VibeFakeHTTPFault(kind, name))) {
            shape = kind;
            VibeFakeHTTPApply(fault, entry);
            break;
        }
    }
    NSTimeInterval transferSeconds = sTransferSeconds;
    entry[@"size"] = @(version.size);
    entry[@"etag"] = version.etag ?: NSNull.null;
    os_unfair_lock_unlock(&sLock);

    if (refusal.status) {
        [self answer:refusal after:latency];
        return;
    }
    NSMutableDictionary<NSString *, NSString *> *headers = [@{
        @"ETag": version.etag,
        @"Last-Modified": version.lastModified,
        @"Content-Type": VibeFakeHTTPContentType(name.pathExtension),
        @"Accept-Ranges": @"bytes",
    } mutableCopy];
    uint64_t size = version.size;
    if (!shape && ranged && first >= size) {
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%llu", size];
        [headers removeObjectForKey:@"Content-Type"];
        [self answer:(VibeFakeHTTPAnswer){416, headers, nil} after:latency];
        return;
    }
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:NULL];
    if (!file) {
        [self answer:(VibeFakeHTTPAnswer){500, @{@"Content-Type": @"text/plain"}, nil} after:latency];
        return;
    }
    if (!shape && closed) {
        last = MIN(last, size - 1);
        NSData *slice = [NSData data];
        if (first <= last && [file seekToOffset:first error:NULL]) {
            slice = [file readDataUpToLength:(NSUInteger)(last - first + 1) error:NULL] ?: slice;
        }
        headers[@"Content-Length"] = @(slice.length).stringValue;
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", first, last, size];
        [self answer:(VibeFakeHTTPAnswer){206, headers, slice} after:latency];
        return;
    }
    // A paced body: the whole file, or the rest of it from an open range.
    uint64_t from = shape ? 0 : first;
    NSInteger status = !shape && ranged ? 206 : 200;
    if (status == 206) {
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", from, size - 1, size];
    }
    headers[@"Content-Length"] = @(size - from).stringValue;
    if ([shape isEqualToString:@"no-length"] || [shape isEqualToString:@"icy"]) {
        [headers removeObjectForKey:@"Content-Length"];
        [headers removeObjectForKey:@"Accept-Ranges"];
    }
    if ([shape isEqualToString:@"icy"]) {
        headers[@"icy-name"] = @"Vibe Fake Radio";
        headers[@"icy-genre"] = @"Test";
        headers[@"icy-br"] = @"128";
    }
    if ([shape isEqualToString:@"gzip"]) {
        headers[@"Content-Encoding"] = @"gzip";
    }
    if ([shape isEqualToString:@"no-range"]) {
        [headers removeObjectForKey:@"Accept-Ranges"];
    }
    if (from > 0 && ![file seekToOffset:from error:NULL]) {
        [self answer:(VibeFakeHTTPAnswer){500, @{@"Content-Type": @"text/plain"}, nil} after:latency];
        return;
    }
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(status);
    entry[@"paced"] = @YES;
    os_unfair_lock_unlock(&sLock);
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    NSTimeInterval interval = transferSeconds > 0 && size > 0 ? transferSeconds * kPieceBytes / size : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(latency * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        os_unfair_lock_lock(&sLock);
        entry[@"firstByte"] = @(VibeFakeHTTPNow());
        os_unfair_lock_unlock(&sLock);
        [self tellClient:^{
            [self.client URLProtocol:self didReceiveResponse:response
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }];
        [self deliverPieceOf:file path:relativePath at:from from:from size:size every:interval after:interval];
    });
}

// One piece per step. The bytes written grow as a real transfer's do, and
// the loading bar reads them. A cancel lands between pieces. The faults are
// read at every step. One set mid-transfer applies to it. Offsets are the
// file's.
- (void)deliverPieceOf:(NSFileHandle *)file
                  path:(NSString *)relativePath
                    at:(uint64_t)offset
                  from:(uint64_t)from
                  size:(uint64_t)size
                 every:(NSTimeInterval)interval
                 after:(NSTimeInterval)wait {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        NSString *name = relativePath.lastPathComponent;
        uint64_t piece = MIN(kPieceBytes, size - offset);
        NSTimeInterval next = interval;
        os_unfair_lock_lock(&sLock);
        NSMutableDictionary *stall = VibeFakeHTTPFault(@"stall", name);
        BOOL stalled = stall && offset >= [stall[@"after"] unsignedLongLongValue];
        NSMutableDictionary *cut = stalled ? nil
                : (VibeFakeHTTPFault(@"drop", name) ?: VibeFakeHTTPFault(@"etag-change", name));
        uint64_t cutAt = [cut[@"after"] unsignedLongLongValue];
        if (cut && offset + piece < cutAt) {
            cut = nil;
        }
        if (cut) {
            piece = cutAt > offset ? cutAt - offset : 0;
            if ([cut[@"kind"] isEqualToString:@"etag-change"]) {
                sVersions[relativePath] = @(sVersions[relativePath].unsignedIntegerValue + 1);
            }
            VibeFakeHTTPApply(cut, self.entry);
        }
        else if (stall && !stalled) {
            // A stall not reached yet stops this piece at its offset.
            piece = MIN(piece, [stall[@"after"] unsignedLongLongValue] - offset);
        }
        if (stalled && ![self.entry[@"faults"] containsObject:@"stall"]) {
            VibeFakeHTTPApply(stall, self.entry);
        }
        NSMutableDictionary *rate = VibeFakeHTTPFault(@"rate", name);
        if (rate) {
            next = (double)kPieceBytes / [rate[@"rate"] unsignedLongLongValue];
            if (![self.entry[@"faults"] containsObject:@"rate"]) {
                VibeFakeHTTPApply(rate, self.entry);
            }
        }
        self.entry[@"outcome"] = stalled ? @"stalled" : @"running";
        os_unfair_lock_unlock(&sLock);
        if (stalled) {
            [self deliverPieceOf:file path:relativePath at:offset from:from size:size every:interval
                           after:kStallPollSeconds];
            return;
        }
        NSData *bytes = piece > 0 ? [file readDataUpToLength:(NSUInteger)piece error:NULL] : [NSData data];
        if (bytes.length > 0) {
            [self tellClient:^{
                [self.client URLProtocol:self didLoadData:bytes];
            }];
        }
        uint64_t reached = offset + bytes.length;
        BOOL complete = !cut && (reached >= size || (piece > 0 && bytes.length == 0));
        os_unfair_lock_lock(&sLock);
        self.entry[@"delivered"] = @(reached - from);
        if (cut || complete) {
            self.entry[@"outcome"] = cut ? @"dropped" : @"complete";
            self.entry[@"finished"] = @(VibeFakeHTTPNow());
        }
        os_unfair_lock_unlock(&sLock);
        if (cut) {
            [self loseConnectionOnceTaskHolds:reached - from waited:0];
            return;
        }
        if (complete) {
            [self tellClient:^{
                [self.client URLProtocolDidFinishLoading:self];
            }];
            return;
        }
        [self deliverPieceOf:file path:relativePath at:reached from:from size:size every:interval after:next];
    });
}

// TRAP: a failure sent straight after the bytes overtakes them on the
// client's side. The session then takes the connection as lost before any
// byte, and sends the request again itself, whole, never the client's
// Range resend. So the failure waits until the task holds the bytes.
- (void)loseConnectionOnceTaskHolds:(uint64_t)delivered waited:(NSTimeInterval)waited {
    if (self.cancelled) {
        return;
    }
    if (self.task.countOfBytesReceived < (int64_t)delivered && waited < kLostConnectionWaitSeconds) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLostConnectionPollSeconds * NSEC_PER_SEC)),
                       sDeliveryQueue, ^{
            [self loseConnectionOnceTaskHolds:delivered waited:waited + kLostConnectionPollSeconds];
        });
        return;
    }
    [self tellClient:^{
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorNetworkConnectionLost
                                                                       userInfo:nil]];
    }];
}

// A whole answer, after the first byte's latency.
- (void)answer:(VibeFakeHTTPAnswer)answer after:(NSTimeInterval)latency {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(latency * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        NSMutableDictionary *headers = [answer.headers mutableCopy] ?: [NSMutableDictionary dictionary];
        if (!headers[@"Content-Length"]) {
            headers[@"Content-Length"] = @(answer.body.length).stringValue;
        }
        os_unfair_lock_lock(&sLock);
        self.entry[@"status"] = @(answer.status);
        self.entry[@"delivered"] = @(answer.body.length);
        self.entry[@"firstByte"] = @(VibeFakeHTTPNow());
        self.entry[@"finished"] = self.entry[@"firstByte"];
        self.entry[@"outcome"] = @"answered";
        os_unfair_lock_unlock(&sLock);
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                  statusCode:answer.status
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:headers];
        [self tellClient:^{
            [self.client URLProtocol:self didReceiveResponse:response
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (answer.body.length > 0) {
                [self.client URLProtocol:self didLoadData:answer.body];
            }
            [self.client URLProtocolDidFinishLoading:self];
        }];
    });
}

// Also sent after a load that finished. Only a line still running was
// cancelled.
- (void)stopLoading {
    self.cancelled = YES;
    os_unfair_lock_lock(&sLock);
    NSString *outcome = self.entry[@"outcome"];
    if ([outcome isEqualToString:@"running"] || [outcome isEqualToString:@"stalled"]) {
        self.entry[@"outcome"] = @"cancelled";
        self.entry[@"finished"] = @(VibeFakeHTTPNow());
    }
    os_unfair_lock_unlock(&sLock);
}

@end

@implementation VibeFakeHTTP

+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(HTTPTransferClient *)client {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sRootPath != nil && sClient == client;
    sRootPath = directory.URLByStandardizingPath.path;
    sClient = client;
    sTransferSeconds = transferSeconds;
    sInstallTime = CFAbsoluteTimeGetCurrent();
    sRequests = 0;
    sFaults = [NSMutableArray array];
    sLog = [NSMutableArray array];
    sVersions = [NSMutableDictionary dictionary];
    if (!sDeliveryQueue) {
        sDeliveryQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.fake-http", DISPATCH_QUEUE_SERIAL);
    }
    os_unfair_lock_unlock(&sLock);
    if (!installed) {
        [client useSessionConfiguration:[self sessionConfiguration]];
    }
}

+ (NSURLSessionConfiguration *)sessionConfiguration {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.protocolClasses = @[VibeFakeHTTPProtocol.class];
    return configuration;
}

+ (void)uninstallFromClient:(HTTPTransferClient *)client {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sRootPath != nil;
    sRootPath = nil;
    sClient = nil;
    [sFaults removeAllObjects];
    os_unfair_lock_unlock(&sLock);
    if (installed) {
        [client useSessionConfiguration:nil];
    }
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sRootPath != nil;
    os_unfair_lock_unlock(&sLock);
    return installed;
}

+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate
                status:(NSInteger)status
                  once:(NSNumber *)once {
    if (![VibeFakeHTTPFaultKinds() containsObject:kind]) {
        return NO;
    }
    if (([kind isEqualToString:@"rate"] && rate == 0) || ([kind isEqualToString:@"status"] && status < 100)) {
        return NO;
    }
    NSMutableDictionary *fault = [@{@"kind": kind, @"after": @(after), @"seconds": @(seconds), @"rate": @(rate),
                                    @"status": @(status),
                                    @"once": @(VibeFakeHTTPFaultIsOnce(kind, once))} mutableCopy];
    fault[@"file"] = file;
    os_unfair_lock_lock(&sLock);
    if (!sFaults) {
        sFaults = [NSMutableArray array];
    }
    [sFaults addObject:fault];
    os_unfair_lock_unlock(&sLock);
    return YES;
}

+ (void)clearFaults {
    os_unfair_lock_lock(&sLock);
    [sFaults removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

+ (NSDictionary *)statistics {
    os_unfair_lock_lock(&sLock);
    NSMutableArray *log = [NSMutableArray arrayWithCapacity:sLog.count];
    NSMutableArray *transfers = [NSMutableArray array];
    for (NSDictionary *entry in sLog) {
        NSMutableDictionary *line = [entry mutableCopy];
        line[@"faults"] = [entry[@"faults"] copy];
        [log addObject:line];
        if ([entry[@"paced"] boolValue] && ([entry[@"outcome"] isEqualToString:@"running"]
                                            || [entry[@"outcome"] isEqualToString:@"stalled"])) {
            [transfers addObject:line];
        }
    }
    NSMutableArray *faults = [NSMutableArray arrayWithCapacity:sFaults.count];
    for (NSDictionary *fault in sFaults) {
        [faults addObject:[fault copy]];
    }
    NSDictionary *statistics = @{
        @"fake": @(sRootPath != nil),
        @"directory": sRootPath ?: NSNull.null,
        @"transferSeconds": @(sTransferSeconds),
        @"requests": @(sRequests),
        @"faults": faults,
        @"transfers": transfers,
        @"log": log,
    };
    os_unfair_lock_unlock(&sLock);
    return statistics;
}

@end

#endif
