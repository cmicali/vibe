//
//  HTTPTransferClient.m
//  Vibe
//

#import "HTTPTransferClientInternal.h"

#include <os/lock.h>
#include <sys/stat.h>
#include <sys/xattr.h>

#import "HTTPTransferRules.h"

NSErrorDomain const VibeHTTPErrorDomain = @"com.commonwealthrecordings.Vibe.HTTP";
NSErrorUserInfoKey const VibeHTTPErrorStatusCodeKey = @"VibeHTTPErrorStatusCode";

// A download whose connection dropped after its file was made resumes this
// many times in a row with no byte arriving between: one outlasts a handoff
// between networks, a second a flap, and past that the link is down and the
// open should fail rather than hold its materialization lane. A byte that
// arrives resets the count, so a long download over a poor link finishes.
static const NSInteger kMaximumNetworkRetries = 2;
static const NSTimeInterval kNetworkRetryDelay = 1;

// The version a download's file holds bytes of, on the file itself, so the
// next download of that destination continues it (downloadTarget:). The
// name must not change: a part kept under it would no longer resume.
static const char *const kVibeHTTPVersionAttribute = "com.commonwealthrecordings.Vibe.rev";

static NSString *_Nullable VibeHTTPVersionOfFile(NSURL *url) {
    char version[256] = {0};
    ssize_t length = getxattr(url.fileSystemRepresentation, kVibeHTTPVersionAttribute, version,
                              sizeof(version) - 1, 0, 0);
    return length > 0 ? [[NSString alloc] initWithBytes:version length:(NSUInteger)length
                                               encoding:NSUTF8StringEncoding] : nil;
}

#pragma mark - Transfer state

// A download, a ranged read, or a probe in flight. The cancel flag, the task,
// and bytesWritten are under the client's transfer lock; the rest belongs to
// whichever step runs, and attempts never overlap.
@interface HTTPTransfer : NSObject
@property (nonatomic) id target;
@property (nonatomic) NSMutableDictionary<NSString *, id> *state;
@property (nonatomic) NSInteger attempts;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) BOOL finished;
@property (nonatomic, nullable) NSURLSessionDataTask *task;
// The download's metadata, the read's or the probe's bytes; finishTransfer:
// calls it once.
@property (nonatomic, copy, nullable) void (^completion)(id _Nullable, NSError *_Nullable);
// A read's: readLength bytes from readOffset, the response carrying them,
// and those received. A probe is a read from byte 0 on the download session.
@property (nonatomic) uint64_t readOffset;
@property (nonatomic) uint64_t readLength;
@property (nonatomic) BOOL probe;
@property (nonatomic, nullable) NSHTTPURLResponse *response;
@property (nonatomic, nullable) NSMutableData *received;
// A download's only: the file, made at the first accepted response, and that
// response's metadata, version, and size span every attempt; bytesWritten is
// the resume offset. A read's metadata is its answer's. The rest is per
// response.
@property (nonatomic, copy, nullable) NSURL *destination;
@property (nonatomic, copy, nullable) void (^progress)(uint64_t, int64_t, NSString *_Nullable);
@property (nonatomic, nullable) NSFileHandle *file;
@property (nonatomic, nullable) NSDictionary *metadata;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic) int64_t size;
@property (nonatomic) uint64_t bytesWritten;
@property (nonatomic) NSInteger networkRetries;
@property (nonatomic) NSInteger status;
// Bytes of the answer before the ones wanted, skipped: a whole-file answer to
// a range, or a partial one from an earlier byte.
@property (nonatomic) uint64_t skip;
// The version of the bytes a kept destination held at the start, continued
// from (bytesWritten) until the first answer names it; another starts over.
@property (nonatomic, copy, nullable) NSString *resumeVersion;
@property (nonatomic) BOOL restart;
// The transfer has what it wanted and cancelled its own task: a read with its
// bytes, or a download whose kept part is the whole file.
@property (nonatomic) BOOL done;
@property (nonatomic, nullable) NSMutableData *errorData;
@property (nonatomic, copy, nullable) NSString *retryAfter;
// The transfer's own reason to stop: a disk write, a changed version, a bad
// range, a refused redirect.
@property (nonatomic, nullable) NSError *failure;
@end

@implementation HTTPTransfer

- (NSData *)dataPastSkip:(NSData *)data {
    NSUInteger skipped = (NSUInteger)MIN((uint64_t)data.length, self.skip);
    self.skip -= skipped;
    return skipped == 0 ? data : [data subdataWithRange:NSMakeRange(skipped, data.length - skipped)];
}

@end

#pragma mark - Client

@interface HTTPTransferClient () <NSURLSessionDataDelegate>
@end

@implementation HTTPTransferClient {
    NSURLSessionConfiguration *_configuration;
    os_unfair_lock _transferLock;
    // Every transfer with a task in flight, by the task object: two sessions
    // number their tasks apart, so an identifier names no one transfer.
    NSMapTable<NSURLSessionTask *, HTTPTransfer *> *_transfers;
}

- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (self) {
        _configuration = configuration;
        _transferLock = OS_UNFAIR_LOCK_INIT;
        _transfers = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                                            | NSPointerFunctionsObjectPointerPersonality
                                               valueOptions:NSPointerFunctionsStrongMemory
                                                   capacity:0];
        _retryDelayScale = 1;
        [self useSessionConfiguration:nil];
    }
    return self;
}

- (NSOperationQueue *)serialQueueNamed:(NSString *)name {
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.name = [NSString stringWithFormat:@"com.commonwealthrecordings.Vibe.%@.%@",
                  self.logName.lowercaseString, name];
    return queue;
}

- (void)useSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    configuration = configuration ?: _configuration;
    [_downloadSession finishTasksAndInvalidate];
    [_callSession finishTasksAndInvalidate];
    // TRAP: a delegate session retains its delegate until invalidated. The
    // client lives as long as the app, so only a replaced session is.
    _downloadSession = [NSURLSession sessionWithConfiguration:configuration
                                                     delegate:self
                                                delegateQueue:[self serialQueueNamed:@"downloads"]];
    _callSession = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:[self serialQueueNamed:@"calls"]];
}

#pragma mark - Hooks

- (void)makeRequestForTarget:(id)target
                       state:(NSMutableDictionary<NSString *, id> *)state
                  completion:(void (^)(NSMutableURLRequest *, NSError *))completion {
    if (![target isKindOfClass:NSURL.class]) {
        completion(nil, [self errorWithCode:VibeHTTPErrorRefusedURL description:@"not a URL"]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
    // TRAP: with no Accept-Encoding, NSURLSession asks for gzip and inflates
    // it, so a range's offsets stop matching the file's bytes.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    completion(request, nil);
}

- (void)handleFailureStatus:(NSInteger)status
                       data:(NSData *)data
                 retryAfter:(NSString *)retryAfter
                      state:(NSMutableDictionary<NSString *, id> *)state
                    attempt:(NSInteger)attempt
                     resend:(void (^)(NSInteger))resend
                       fail:(void (^)(NSError *))fail {
    NSTimeInterval delay = VibeHTTPRetryDelay(status, retryAfter);
    if (delay >= 0 && attempt < kVibeHTTPMaximumAttempts) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * self.retryDelayScale * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            resend(attempt + 1);
        });
        return;
    }
    NSString *summary = [NSString stringWithFormat:@"HTTP %ld", (long)status];
    LogWarn(@"%@: request failed: %@", self.logName, summary);
    fail([NSError errorWithDomain:VibeHTTPErrorDomain code:VibeHTTPErrorStatus
                         userInfo:@{NSLocalizedDescriptionKey: summary, VibeHTTPErrorStatusCodeKey: @(status)}]);
}

- (NSDictionary *)metadataOfResponse:(NSHTTPURLResponse *)response {
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"etag"] = [response valueForHTTPHeaderField:@"ETag"];
    metadata[@"lastModified"] = [response valueForHTTPHeaderField:@"Last-Modified"];
    metadata[@"contentType"] = [response valueForHTTPHeaderField:@"Content-Type"];
    metadata[@"contentDisposition"] = [response valueForHTTPHeaderField:@"Content-Disposition"];
    metadata[@"url"] = response.URL;
    int64_t size = VibeHTTPSizeFromHeaders(response.statusCode,
                                           [response valueForHTTPHeaderField:@"Content-Range"],
                                           [response valueForHTTPHeaderField:@"Content-Length"],
                                           [response valueForHTTPHeaderField:@"Content-Encoding"]);
    if (size >= 0) {
        metadata[@"size"] = @(size);
    }
    return metadata;
}

- (NSString *)versionOfMetadata:(NSDictionary *)metadata {
    NSString *etag = metadata[@"etag"];
    NSString *lastModified = metadata[@"lastModified"];
    return VibeHTTPVersionFromHeaders([etag isKindOfClass:NSString.class] ? etag : nil,
                                      [lastModified isKindOfClass:NSString.class] ? lastModified : nil);
}

// The CDN case (VibeHTTPIsSameFileUnderAnotherETag), on the default
// metadata's Last-Modified. A subclass whose metadata carries none never
// meets it.
- (BOOL)isSameFileUnderAnotherETag:(NSDictionary *)metadata asMetadata:(NSDictionary *)pinned {
    NSString *lastModified = metadata[@"lastModified"];
    NSString *pinnedLastModified = pinned[@"lastModified"];
    return VibeHTTPIsSameFileUnderAnotherETag(
            [self sizeOfMetadata:pinned],
            [pinnedLastModified isKindOfClass:NSString.class] ? pinnedLastModified : nil,
            [self sizeOfMetadata:metadata],
            [lastModified isKindOfClass:NSString.class] ? lastModified : nil);
}

- (int64_t)sizeOfMetadata:(NSDictionary *)metadata {
    id size = metadata[@"size"];
    return [size isKindOfClass:NSNumber.class] && [size longLongValue] >= 0 ? [size longLongValue] : -1;
}

- (NSError *)errorWithCode:(VibeHTTPError)code description:(NSString *)description {
    return [NSError errorWithDomain:VibeHTTPErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (BOOL)keepsPartAfterError:(NSError *)error {
    return ([error.domain isEqualToString:VibeHTTPErrorDomain] && error.code == VibeHTTPErrorCancelled)
            || VibeHTTPIsConnectionError(error);
}

- (NSString *)logName {
    return @"HTTP";
}

- (NSString *)descriptionOfTarget:(id)target {
    NSURL *url = [target isKindOfClass:NSURL.class] ? target : nil;
    NSString *name = url.lastPathComponent;
    if (name.length == 0 || [name isEqualToString:@"/"]) {
        return url.host ?: @"";
    }
    return [NSString stringWithFormat:@"%@/%@", url.host ?: @"", name];
}

#pragma mark - Transfers

- (NSError *)cancelledError {
    return [self errorWithCode:VibeHTTPErrorCancelled description:@"cancelled"];
}

- (BOOL)allowsRequestFrom:(NSURL *)from to:(NSURL *)url {
    BOOL (^allows)(NSURL *, NSURL *) = self.allowsURL;
    return !allows || allows(from, url);
}

- (HTTPTransfer *)transferForTarget:(id)target {
    HTTPTransfer *transfer = [[HTTPTransfer alloc] init];
    transfer.target = target;
    transfer.state = [NSMutableDictionary dictionary];
    transfer.attempts = 1;
    return transfer;
}

// Any thread. A transfer with a task in flight completes through that task's
// cancel. One with none — waiting on the request hook, or on a retry's delay
// after a task that already ended — settles here, at once: a cancel frees
// the caller's lane now, never when the hook or the delay comes back
// (System/AGENTS.md). Whichever step runs next sees the flag.
- (void)cancelTransfer:(HTTPTransfer *)transfer {
    os_unfair_lock_lock(&_transferLock);
    transfer.cancelled = YES;
    NSURLSessionDataTask *task = transfer.task;
    os_unfair_lock_unlock(&_transferLock);
    if (task && task.state != NSURLSessionTaskStateCompleted) {
        [task cancel];
        return;
    }
    [self finishTransfer:transfer result:nil error:[self cancelledError]];
}

// Exactly once per transfer, whichever path gets here first.
- (void)finishTransfer:(HTTPTransfer *)transfer result:(id)result error:(NSError *)error {
    os_unfair_lock_lock(&_transferLock);
    BOOL first = !transfer.finished;
    transfer.finished = YES;
    os_unfair_lock_unlock(&_transferLock);
    if (!first) {
        return;
    }
    NSError *closeError = nil;
    if (transfer.file && ![transfer.file closeAndReturnError:&closeError] && !error) {
        error = closeError;
    }
    transfer.file = nil;
    if (error && transfer.destination && ![self keepsPartAfterError:error]) {
        [NSFileManager.defaultManager removeItemAtURL:transfer.destination error:NULL];
    }
    transfer.completion(error ? nil : result, error);
}

// Runs the task for the transfer, unless a cancel came first. Adopted under
// the lock, so a cancel either finds the task or is seen here.
//
// TRAP: the transfer enters the delegate's table under the SAME lock.
// Written after the adopt, a cancel between the two cancelled a task whose
// completion found no transfer, and the download never finished: its caller
// waited on it for good, holding its materialization lane.
- (void)startTask:(NSURLSessionDataTask *)task forTransfer:(HTTPTransfer *)transfer {
    os_unfair_lock_lock(&_transferLock);
    BOOL cancelled = transfer.cancelled;
    if (!cancelled) {
        transfer.task = task;
        [_transfers setObject:transfer forKey:task];
    }
    os_unfair_lock_unlock(&_transferLock);
    if (cancelled) {
        [self finishTransfer:transfer result:nil error:[self cancelledError]];
        return;
    }
    [task resume];
}

- (HTTPTransfer *)transferForTask:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_transferLock);
    HTTPTransfer *transfer = [_transfers objectForKey:task];
    os_unfair_lock_unlock(&_transferLock);
    return transfer;
}

- (dispatch_block_t)cancelBlockForTransfer:(HTTPTransfer *)transfer {
    __weak HTTPTransferClient *weakSelf = self;
    return ^{
        [weakSelf cancelTransfer:transfer];
    };
}

// The hook's request for this attempt, unless allowsURL refuses it. A
// refusal or the hook's error finishes the transfer instead.
- (void)requestForTransfer:(HTTPTransfer *)transfer
                completion:(void (^)(NSMutableURLRequest *request))completion {
    [self makeRequestForTarget:transfer.target state:transfer.state
                    completion:^(NSMutableURLRequest *request, NSError *error) {
        if (!request) {
            [self finishTransfer:transfer result:nil
                           error:error ?: [self errorWithCode:VibeHTTPErrorRefusedURL description:@"no request"]];
            return;
        }
        if (![self allowsRequestFrom:nil to:request.URL]) {
            LogWarn(@"%@: refused a request to %@", self.logName, request.URL.host);
            [self finishTransfer:transfer result:nil
                           error:[self errorWithCode:VibeHTTPErrorRefusedURL description:@"the address is not allowed"]];
            return;
        }
        completion(request);
    }];
}

#pragma mark - Ranged read and probe

- (dispatch_block_t)readTarget:(id)target
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    HTTPTransfer *read = [self transferForTarget:target];
    read.readOffset = offset;
    read.readLength = MAX(length, (uint64_t)1);
    // Weak: the transfer holds this block, and finishTransfer: holds the transfer.
    __weak HTTPTransfer *weakRead = read;
    read.completion = ^(id data, NSError *error) {
        completion(data, error ? nil : weakRead.metadata, error);
    };
    [self startRead:read];
    return [self cancelBlockForTransfer:read];
}

- (dispatch_block_t)probeTarget:(id)target
                         length:(uint64_t)length
                     completion:(void (^)(NSDictionary *, NSHTTPURLResponse *, NSData *, NSError *))completion {
    HTTPTransfer *probe = [self transferForTarget:target];
    probe.probe = YES;
    probe.readLength = MAX(length, (uint64_t)1);
    __weak HTTPTransfer *weakProbe = probe;
    probe.completion = ^(id bytes, NSError *error) {
        HTTPTransfer *strongProbe = weakProbe;
        completion(error ? nil : strongProbe.metadata, error ? nil : strongProbe.response, bytes, error);
    };
    [self startRead:probe];
    return [self cancelBlockForTransfer:probe];
}

// A read streams through the session delegate, as a download does, so a
// server ignoring the range never holds the whole file in memory: the read
// cancels its own task once it holds its bytes. A probe streams on the
// download session. A tag read is answered on the call session, apart from
// the downloads' disk writes.
- (void)startRead:(HTTPTransfer *)read {
    [self requestForTransfer:read completion:^(NSMutableURLRequest *request) {
        [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", read.readOffset,
                           read.readOffset + read.readLength - 1]
       forHTTPHeaderField:@"Range"];
        NSURLSession *session = read.probe ? self.downloadSession : self.callSession;
        [self startTask:[session dataTaskWithRequest:request] forTransfer:read];
    }];
}

- (NSURLSessionResponseDisposition)read:(HTTPTransfer *)read didReceiveResponse:(NSHTTPURLResponse *)http {
    BOOL accepted = http.statusCode == 200 || http.statusCode == 206;
    read.response = accepted ? http : nil;
    read.metadata = accepted ? [self metadataOfResponse:http] : nil;
    read.received = accepted ? [NSMutableData data] : nil;
    if (!accepted) {
        read.errorData = [NSMutableData data];
        read.retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
        return NSURLSessionResponseAllow;
    }
    // A partial answer from another byte holds other bytes than the ones
    // asked for. One naming no range is taken at its word.
    int64_t start = http.statusCode == 206 ? VibeHTTPContentRangeStart([http valueForHTTPHeaderField:@"Content-Range"])
                                           : -1;
    if (start >= 0 && (uint64_t)start != read.readOffset) {
        LogWarn(@"%@: %@ answered a read at byte %llu from byte %lld", self.logName,
                [self descriptionOfTarget:read.target], read.readOffset, start);
        read.failure = [self errorWithCode:VibeHTTPErrorBadRange
                               description:@"the server answered another range than the one asked for"];
        return NSURLSessionResponseCancel;
    }
    // 200 is a server ignoring the range: the whole file, cut to the bytes
    // asked for, and a range past its end is nothing.
    read.skip = http.statusCode == 200 ? read.readOffset : 0;
    return NSURLSessionResponseAllow;
}

- (void)read:(HTTPTransfer *)read task:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (read.done) {
        return;
    }
    data = [read dataPastSkip:data];
    uint64_t room = read.readLength - MIN((uint64_t)read.received.length, read.readLength);
    [read.received appendData:[data subdataWithRange:NSMakeRange(0, (NSUInteger)MIN(room, (uint64_t)data.length))]];
    if (read.received.length >= read.readLength) {
        read.done = YES;
        [task cancel];
    }
}

- (void)completeRead:(HTTPTransfer *)read error:(NSError *)error {
    if (read.failure) {
        [self finishTransfer:read result:nil error:read.failure];
        return;
    }
    if (read.done || (!error && read.received)) {
        [self finishTransfer:read result:[read.received copy] error:nil];
        return;
    }
    if (error) {
        [self finishTransfer:read result:nil error:error];
        return;
    }
    [self handleFailureStatus:read.status data:read.errorData retryAfter:read.retryAfter
                        state:read.state attempt:read.attempts
                       resend:^(NSInteger nextAttempt) {
        read.attempts = nextAttempt;
        [self startRead:read];
    } fail:^(NSError *failure) {
        [self finishTransfer:read result:nil error:failure];
    }];
}

#pragma mark - Download

- (dispatch_block_t)downloadTarget:(id)target
                             toURL:(NSURL *)destination
                          progress:(void (^)(uint64_t, int64_t, NSString *))progress
                        completion:(void (^)(NSDictionary *, NSError *))completion {
    HTTPTransfer *download = [self transferForTarget:target];
    download.destination = destination;
    download.progress = progress;
    download.completion = completion;
    // A destination holding bytes of a version, kept by a transfer the link
    // ended, is continued from its last byte; one with no version is replaced.
    struct stat kept;
    NSString *version = stat(destination.fileSystemRepresentation, &kept) == 0 && kept.st_size > 0
            ? VibeHTTPVersionOfFile(destination) : nil;
    if (version) {
        download.resumeVersion = version;
        download.bytesWritten = (uint64_t)kept.st_size;
    }
    [self startDownload:download];
    return [self cancelBlockForTransfer:download];
}

- (void)startDownload:(HTTPTransfer *)download {
    [self requestForTransfer:download completion:^(NSMutableURLRequest *request) {
        os_unfair_lock_lock(&self->_transferLock);
        uint64_t offset = download.bytesWritten;
        os_unfair_lock_unlock(&self->_transferLock);
        // A resend continues the file, never starts it over: a reader may
        // hold it open, and a new file would leave it waiting on one that
        // never grows.
        if (offset > 0) {
            [request setValue:[NSString stringWithFormat:@"bytes=%llu-", offset] forHTTPHeaderField:@"Range"];
        }
        [self startTask:[self.downloadSession dataTaskWithRequest:request] forTransfer:download];
    }];
}

- (NSURLSessionResponseDisposition)download:(HTTPTransfer *)download didReceiveResponse:(NSHTTPURLResponse *)http {
    // A ranged resend answers 206 from where the file stopped, or 200 with the
    // whole file from a server ignoring the range. A request with no range,
    // the first or one before any byte was written, takes only 200.
    uint64_t offset = download.bytesWritten;
    NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
    if (http.statusCode == 416 && download.resumeVersion && !download.file) {
        NSDictionary *metadata = [self metadataOfResponse:http];
        NSString *version = [self versionOfMetadata:metadata];
        // A kept part as long as its version now is the whole file.
        if (VibeHTTPContentRangeTotal(contentRange) == (int64_t)offset
                && [version isEqualToString:download.resumeVersion]) {
            LogInfo(@"%@: %@'s kept part is the whole file, %llu bytes", self.logName,
                    [self descriptionOfTarget:download.target], offset);
            NSMutableDictionary *whole = [metadata mutableCopy];
            whole[@"size"] = @(offset);
            download.metadata = whole;
            download.version = version;
            download.size = (int64_t)offset;
            download.done = YES;
            return NSURLSessionResponseCancel;
        }
        // A kept part longer than the version now current asks past its end:
        // started over, whole, as another version's part is (restart).
        LogInfo(@"%@: %@ does not continue its kept part's %llu bytes; downloading it whole",
                self.logName, [self descriptionOfTarget:download.target], offset);
        download.restart = YES;
        return NSURLSessionResponseCancel;
    }
    if (http.statusCode != 200 && !(http.statusCode == 206 && offset > 0)) {
        download.errorData = [NSMutableData data];
        download.retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
        return NSURLSessionResponseAllow;
    }
    NSDictionary *metadata = [self metadataOfResponse:http];
    NSString *version = [self versionOfMetadata:metadata];
    // TRAP: a resend answers whatever version is current, so bytes continuing
    // a file, a resend's or a kept part's, must be the version it holds, or
    // two versions splice into one; with no version to compare, nothing
    // proves they match. A resend of another version fails the transfer; a
    // kept part's starts it over, whole, from the completion (restart).
    // A resend under another ETag with the first response's size and
    // Last-Modified continues: a CDN's edges can each tag one file with an
    // ETag of their own. A kept part holds only its version, so it starts over.
    NSString *pinned = download.file ? download.version : download.resumeVersion;
    BOOL continues = !(download.file || download.resumeVersion) || [version isEqualToString:pinned];
    if (!continues && download.file && [self isSameFileUnderAnotherETag:metadata asMetadata:download.metadata]) {
        LogInfo(@"%@: %@ answered another ETag with the same size and date (version %@, now %@); continuing",
                self.logName, [self descriptionOfTarget:download.target], pinned, version);
        continues = YES;
    }
    // A partial answer naming no range is taken at its word. Bytes before the
    // offset are skipped, as a whole answer's are. One from past the offset
    // leaves a gap, never appended.
    int64_t start = http.statusCode == 206 ? VibeHTTPContentRangeStart(contentRange) : 0;
    uint64_t from = start >= 0 ? (uint64_t)start : offset;
    BOOL gap = from > offset;
    if (!continues || gap) {
        if (download.file) {
            LogWarn(@"%@: %@ %@ during its download (version %@, now %@, from byte %llu of %llu)",
                    self.logName, [self descriptionOfTarget:download.target],
                    continues ? @"skipped bytes" : @"changed", pinned, version, from, offset);
            download.failure = continues
                    ? [self errorWithCode:VibeHTTPErrorBadRange
                              description:@"the server answered another range than the one asked for"]
                    : [self errorWithCode:VibeHTTPErrorVersionChanged
                              description:@"the file changed during its download"];
        }
        else {
            LogInfo(@"%@: %@ does not continue its kept part (version %@, now %@, from byte %llu of %llu); "
                    @"downloading it whole", self.logName, [self descriptionOfTarget:download.target], pinned,
                    version, from, offset);
            download.restart = YES;
        }
        return NSURLSessionResponseCancel;
    }
    download.skip = offset - from;
    if (download.file) {
        return NSURLSessionResponseAllow;
    }
    // Made once per transfer, at its first accepted response, unless it
    // continues a kept part.
    download.metadata = metadata;
    download.version = version;
    download.size = [self sizeOfMetadata:metadata];
    if (!download.resumeVersion) {
        NSFileManager *files = NSFileManager.defaultManager;
        [files removeItemAtURL:download.destination error:NULL];
        if (![files createFileAtPath:download.destination.path contents:nil attributes:nil]) {
            download.failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NSURLSessionResponseCancel;
        }
        if (version) {
            setxattr(download.destination.fileSystemRepresentation, kVibeHTTPVersionAttribute,
                     version.UTF8String, strlen(version.UTF8String), 0, 0);
        }
    }
    NSError *error = nil;
    download.file = [NSFileHandle fileHandleForWritingToURL:download.destination error:&error];
    download.failure = error;
    if (download.file && download.resumeVersion && ![download.file seekToEndReturningOffset:NULL error:&error]) {
        download.failure = error;
    }
    if (download.file && !download.failure && download.progress) {
        download.progress(offset, download.size, version);
    }
    return download.file && !download.failure ? NSURLSessionResponseAllow : NSURLSessionResponseCancel;
}

- (void)download:(HTTPTransfer *)download task:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!download.file || download.failure) {
        return;
    }
    data = [download dataPastSkip:data];
    if (data.length == 0) {
        return;
    }
    NSError *error = nil;
    if (![download.file writeData:data error:&error]) {
        download.failure = error;
        [task cancel];
        return;
    }
    download.networkRetries = 0;
    os_unfair_lock_lock(&_transferLock);
    uint64_t written = download.bytesWritten += data.length;
    os_unfair_lock_unlock(&_transferLock);
    // After the write: a reader told of these bytes finds them on disk.
    if (download.progress) {
        download.progress(written, download.size, download.version);
    }
}

- (void)completeDownload:(HTTPTransfer *)download error:(NSError *)error {
    if (download.done) {
        [self finishTransfer:download result:download.metadata error:nil];
        return;
    }
    if (download.restart) {
        download.restart = NO;
        download.resumeVersion = nil;
        download.metadata = nil;
        download.version = nil;
        [NSFileManager.defaultManager removeItemAtURL:download.destination error:NULL];
        os_unfair_lock_lock(&_transferLock);
        download.bytesWritten = 0;
        os_unfair_lock_unlock(&_transferLock);
        [self startDownload:download];
        return;
    }
    if (download.failure) {
        [self finishTransfer:download result:nil error:download.failure];
        return;
    }
    // Every byte is here: a resend would ask for bytes=<size>-, which 416s.
    BOOL whole = download.file && download.size >= 0 && download.bytesWritten == (uint64_t)download.size;
    if (error && whole && !download.errorData && VibeHTTPIsConnectionError(error)) {
        error = nil;
    }
    if (error) {
        if (download.file && download.networkRetries < kMaximumNetworkRetries && VibeHTTPIsConnectionError(error)) {
            download.networkRetries++;
            LogInfo(@"%@: resuming %@ at byte %llu: %@", self.logName, [self descriptionOfTarget:download.target],
                    download.bytesWritten, error.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(kNetworkRetryDelay * self.retryDelayScale * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self startDownload:download];
            });
            return;
        }
        [self finishTransfer:download result:nil error:error];
        return;
    }
    if (!download.errorData) {
        // A file of another length than its version's is not that version.
        NSError *mismatch = download.size < 0 || whole ? nil
                : [self errorWithCode:VibeHTTPErrorLengthMismatch
                          description:@"the download's length differs from its file's size"];
        if (mismatch) {
            LogWarn(@"%@: %@ ended at byte %llu of %lld", self.logName, [self descriptionOfTarget:download.target],
                    download.bytesWritten, download.size);
        }
        [self finishTransfer:download result:download.metadata ?: @{} error:mismatch];
        return;
    }
    [self handleFailureStatus:download.status data:download.errorData retryAfter:download.retryAfter
                        state:download.state attempt:download.attempts
                       resend:^(NSInteger nextAttempt) {
        download.attempts = nextAttempt;
        [self startDownload:download];
    } fail:^(NSError *failure) {
        [self finishTransfer:download result:nil error:failure];
    }];
}

#pragma mark - Session delegate

// A refused redirect completes its task with the 3xx itself, so the step
// that sees that answer fails the transfer with this failure instead.
- (void)URLSession:(NSURLSession *)session
                          task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    if ([self allowsRequestFrom:response.URL to:request.URL]) {
        completionHandler(request);
        return;
    }
    LogWarn(@"%@: refused a redirect from %@ to %@", self.logName, response.URL.host, request.URL.host);
    [self transferForTask:task].failure = [self errorWithCode:VibeHTTPErrorRefusedURL
                                                  description:@"the redirect's address is not allowed"];
    completionHandler(nil);
}

// Each session's delegate queue is serial, so a transfer's response, data, and
// completion callbacks never overlap, and it alone writes the file. A task
// with no transfer is a subclass's own call, answered by its handler.
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    HTTPTransfer *transfer = [self transferForTask:dataTask];
    if (!transfer) {
        completionHandler(NSURLSessionResponseAllow);
        return;
    }
    if (transfer.failure) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    transfer.status = http.statusCode;
    transfer.errorData = nil;
    transfer.skip = 0;
    completionHandler(transfer.readLength > 0 ? [self read:transfer didReceiveResponse:http]
                                              : [self download:transfer didReceiveResponse:http]);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    HTTPTransfer *transfer = [self transferForTask:dataTask];
    if (transfer.errorData) {
        [transfer.errorData appendData:data];
    }
    else if (transfer.readLength > 0) {
        [self read:transfer task:dataTask didReceiveData:data];
    }
    else if (transfer) {
        [self download:transfer task:dataTask didReceiveData:data];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    os_unfair_lock_lock(&_transferLock);
    HTTPTransfer *transfer = [_transfers objectForKey:task];
    if (transfer) {
        [_transfers removeObjectForKey:task];
    }
    BOOL cancelled = transfer.cancelled;
    os_unfair_lock_unlock(&_transferLock);
    if (!transfer) {
        return;
    }
    if (cancelled) {
        [self finishTransfer:transfer result:nil error:[self cancelledError]];
    }
    else if (transfer.readLength > 0) {
        [self completeRead:transfer error:error];
    }
    else {
        [self completeDownload:transfer error:error];
    }
}

@end
