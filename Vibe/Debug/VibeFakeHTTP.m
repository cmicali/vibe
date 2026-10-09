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
static const NSTimeInterval kStallPollSeconds = 0.02;
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

// iCloud Drive's two hosts: the lookup, and the signed addresses it hands out.
static NSString *const kVibeFakeHTTPLookupHost = @"ckdatabasews.icloud.com";
static NSString *const kVibeFakeHTTPSignedHost = @"cvws.icloud-content.com";
// How long a signed address lives unless an expiry fault says otherwise.
// iCloud's own live about 15 minutes.
static const NSTimeInterval kVibeFakeHTTPAddressLifetime = 15 * 60;

static NSArray<NSString *> *VibeFakeHTTPFaultKinds(void) {
    return @[@"stall", @"drop", @"etag-change", @"rate", @"latency", @"no-range", @"no-length", @"icy",
             @"status", @"html", @"gzip", @"expiry"];
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
    return [name isEqualToString:@"fake.vibe.test"] || [name isEqualToString:@"fake.local"]
        || [name isEqualToString:kVibeFakeHTTPLookupHost] || [name isEqualToString:kVibeFakeHTTPSignedHost];
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
    time_t modified;
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
        modified,
    };
}

// The share a lookup's body names. A protocol sees the body as a stream.
static NSString *VibeFakeHTTPShortGUIDOfLookup(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body && request.HTTPBodyStream) {
        NSMutableData *read = [NSMutableData data];
        NSInputStream *stream = request.HTTPBodyStream;
        [stream open];
        uint8_t buffer[4096];
        NSInteger count;
        while ((count = [stream read:buffer maxLength:sizeof buffer]) > 0) {
            [read appendBytes:buffer length:(NSUInteger)count];
        }
        [stream close];
        body = read;
    }
    id answer = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    id shares = [answer isKindOfClass:NSDictionary.class] ? answer[@"shortGUIDs"] : nil;
    id share = [shares isKindOfClass:NSArray.class] ? [shares firstObject] : nil;
    id value = [share isKindOfClass:NSDictionary.class] ? share[@"value"] : nil;
    return [value isKindOfClass:NSString.class] ? value : @"";
}

// The entry of the root a share names: its name without its extension.
static NSString *VibeFakeHTTPEntryOfShare(NSString *root, NSString *shortGUID) {
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL]) {
        if (shortGUID.length > 0 && [entry.stringByDeletingPathExtension isEqualToString:shortGUID]) {
            return entry;
        }
    }
    return nil;
}

// A lookup's answer in the shape iCloud sends, with no owner: one file, a
// folder, or no share. The checksum is the file's version, which
// etag-change moves.
static NSData *VibeFakeHTTPLookup(NSString *shortGUID, NSString *entry, const struct stat *info,
                                  VibeFakeHTTPVersion version, NSTimeInterval lifetime) {
    NSMutableDictionary *result = [@{@"shortGUID": @{@"value": shortGUID}, @"requireAppleLogin": @NO,
                                     @"minimallyResolved": @NO} mutableCopy];
    if (!entry) {
        result[@"reason"] = @"Cannot resolve shortGUID";
        result[@"serverErrorCode"] = @"NOT_FOUND";
        return [NSJSONSerialization dataWithJSONObject:@{@"results": @[result]} options:0 error:NULL];
    }
    result[@"anonymousPublicAccess"] = @{@"token": @"fake", @"tokenTTL": @1200000};
    if (S_ISDIR(info->st_mode)) {
        result[@"rootRecord"] = @{@"recordType": @"folder", @"fields": @{}};
        return [NSJSONSerialization dataWithJSONObject:@{@"results": @[result]} options:0 error:NULL];
    }
    NSString *checksum = [version.etag stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"\""]];
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:
                                  @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    NSString *address = [NSString stringWithFormat:@"https://%@/B/%@/${f}?p=%@&e=%lld&s=fake", kVibeFakeHTTPSignedHost,
                         checksum, [entry stringByAddingPercentEncodingWithAllowedCharacters:unreserved],
                         (long long)(NSDate.date.timeIntervalSince1970 + lifetime)];
    NSString *basename = [[entry.stringByDeletingPathExtension dataUsingEncoding:NSUTF8StringEncoding]
                          base64EncodedStringWithOptions:0];
    result[@"rootRecord"] = @{@"recordType": @"content", @"fields": @{
        @"extension": @{@"value": entry.pathExtension, @"type": @"STRING"},
        @"size": @{@"value": @(version.size), @"type": @"NUMBER_INT64"},
        @"encryptedBasename": @{@"value": basename, @"type": @"ENCRYPTED_BYTES"},
        @"mtime": @{@"value": @(version.modified), @"type": @"NUMBER_INT64"},
        @"fileContent": @{@"value": @{@"fileChecksum": checksum, @"size": @(version.size), @"downloadURL": address},
                          @"type": @"ASSETID"},
    }};
    return [NSJSONSerialization dataWithJSONObject:@{@"results": @[result]} options:0 error:NULL];
}

// A request's line, as its body proceeds. A cancel marks only a line still
// running. Under sLock.
static void VibeFakeHTTPNote(NSMutableDictionary *entry, NSString *outcome, uint64_t delivered) {
    NSString *was = entry[@"outcome"];
    if ([outcome isEqualToString:@"cancelled"]) {
        if ([was isEqualToString:@"running"] || [was isEqualToString:@"stalled"]) {
            entry[@"outcome"] = outcome;
            entry[@"finished"] = @(VibeFakeHTTPNow());
        }
        return;
    }
    if (!entry[@"firstByte"]) {
        entry[@"firstByte"] = @(VibeFakeHTTPNow());
    }
    entry[@"delivered"] = @(delivered);
    entry[@"outcome"] = outcome;
    if (![outcome isEqualToString:@"running"] && ![outcome isEqualToString:@"stalled"]) {
        entry[@"finished"] = @(VibeFakeHTTPNow());
    }
}

NSInteger VibeFakeHTTPRangeStatus(NSString *range, uint64_t size, NSMutableDictionary<NSString *, NSString *> *headers,
                                  uint64_t *first, uint64_t *length) {
    unsigned long long from = 0, last = ULLONG_MAX;
    if (!range || sscanf(range.UTF8String, "bytes=%llu-%llu", &from, &last) < 1) {
        *first = 0;
        *length = size;
        headers[@"Content-Length"] = @(size).stringValue;
        return 200;
    }
    if (from >= size) {
        *first = 0;
        *length = 0;
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%llu", size];
        headers[@"Content-Length"] = @"0";
        return 416;
    }
    last = MIN(last, size - 1);
    *first = from;
    *length = last >= from ? last - from + 1 : 0;
    headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", from, last, size];
    headers[@"Content-Length"] = @(*length).stringValue;
    return 206;
}

@implementation VibeFakeHTTPAnswer

- (instancetype)init {
    self = [super init];
    if (self) {
        _piece = kPieceBytes;
        _holdAt = UINT64_MAX;
        _cutAt = UINT64_MAX;
    }
    return self;
}

@end

// Pieces of a body are delivered here, never on CFNetwork's protocol thread:
// a wait there would queue every other request behind it and hold a cancel
// until the whole file had gone out. HTTPStub's bodies too.
static dispatch_queue_t VibeFakeHTTPDeliveryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.commonwealthrecordings.Vibe.fake-http", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface VibeFakeHTTPProtocol ()
@property (atomic) BOOL cancelled;
// The last step is on its way. A stop after it is no cancel.
@property (atomic) BOOL ended;
@property (nonatomic, nullable) VibeFakeHTTPAnswer *answer;
@end

@implementation VibeFakeHTTPProtocol {
    NSThread *_loader;
    NSArray<NSRunLoopMode> *_modes;
}

// Installed on sessions their owner alone uses. Every request is the fake's.
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
    VibeFakeHTTPAnswer *answer = [self answerForRequest:self.request];
    self.answer = answer;
    if (!answer || answer.error) {
        self.ended = YES;
        [self.client URLProtocol:self didFailWithError:answer.error ?: [NSError errorWithDomain:NSURLErrorDomain
                                                                                           code:NSURLErrorCannotFindHost
                                                                                       userInfo:nil]];
        return;
    }
    if (answer.redirect) {
        // Followed, the session loads the new request through a new instance.
        // Refused, it answers the task with this response. Either way this
        // load is over.
        self.ended = YES;
        [self.client URLProtocol:self wasRedirectedToRequest:answer.redirect redirectResponse:answer.response];
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorCancelled userInfo:nil]];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(answer.latency * NSEC_PER_SEC)),
                   VibeFakeHTTPDeliveryQueue(), ^{
        if (self.cancelled) {
            return;
        }
        if (answer.progress) {
            answer.progress(@"running", 0);
        }
        [self tellClient:^{
            [self.client URLProtocol:self didReceiveResponse:answer.response
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }];
        [self deliverFrom:0 after:answer.interval];
    });
}

// One piece per step. The bytes written grow as a real transfer's do, and
// the loading bar reads them. A cancel lands between pieces. beforePiece is
// asked at every step, so a fault set mid-transfer applies to it.
- (void)deliverFrom:(uint64_t)delivered after:(NSTimeInterval)wait {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), VibeFakeHTTPDeliveryQueue(), ^{
        if (self.cancelled) {
            return;
        }
        VibeFakeHTTPAnswer *answer = self.answer;
        if (answer.beforePiece) {
            answer.beforePiece(answer, delivered);
        }
        uint64_t length = answer.length;
        if (delivered < length && delivered >= answer.holdAt) {
            if (answer.progress) {
                answer.progress(@"stalled", delivered);
            }
            [self deliverFrom:delivered after:kStallPollSeconds];
            return;
        }
        uint64_t piece = MIN(answer.piece, length - MIN(delivered, length));
        BOOL cut = answer.cutAt != UINT64_MAX && delivered + piece >= answer.cutAt;
        if (cut) {
            piece = answer.cutAt > delivered ? answer.cutAt - delivered : 0;
        }
        else if (answer.holdAt > delivered && answer.holdAt != UINT64_MAX) {
            // A hold not reached yet stops this piece at its offset.
            piece = MIN(piece, answer.holdAt - delivered);
        }
        NSData *bytes = piece > 0 ? answer.bytes(delivered, piece) ?: [NSData data] : [NSData data];
        if (bytes.length > 0) {
            [self tellClient:^{
                [self.client URLProtocol:self didLoadData:bytes];
            }];
        }
        uint64_t reached = delivered + bytes.length;
        BOOL complete = !cut && (reached >= length || (piece > 0 && bytes.length == 0));
        if (cut || complete) {
            self.ended = YES;
        }
        if (answer.progress) {
            answer.progress(cut ? @"dropped" : complete ? @"complete" : @"running", reached);
        }
        if (cut) {
            [self loseConnectionOnceTaskHolds:reached waited:0];
            return;
        }
        if (complete) {
            [self tellClient:^{
                [self.client URLProtocolDidFinishLoading:self];
            }];
            return;
        }
        [self deliverFrom:reached after:answer.interval];
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
    BOOL (^ready)(void) = self.answer.ready;
    BOOL held = self.task.countOfBytesReceived >= (int64_t)delivered || waited >= kLostConnectionWaitSeconds;
    if (!held || (ready && !ready())) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLostConnectionPollSeconds * NSEC_PER_SEC)),
                       VibeFakeHTTPDeliveryQueue(), ^{
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

// Also sent after a load that finished. Only one still running was cancelled.
- (void)stopLoading {
    self.cancelled = YES;
    VibeFakeHTTPAnswer *answer = self.answer;
    if (!self.ended && answer.progress) {
        answer.progress(@"cancelled", 0);
    }
}

#pragma mark The directory

- (VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    // A lookup serves the entry its share names. A signed address serves the
    // entry in its p item until its e item has passed.
    NSString *host = url.host.lowercaseString;
    BOOL lookup = [host isEqualToString:kVibeFakeHTTPLookupHost];
    BOOL signedAddress = [host isEqualToString:kVibeFakeHTTPSignedHost];
    NSString *shortGUID = lookup ? VibeFakeHTTPShortGUIDOfLookup(request) : nil;
    NSString *servedPath = url.path ?: @"";
    BOOL expired = NO;
    if (signedAddress) {
        servedPath = @"";
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
            if ([item.name isEqualToString:@"p"]) {
                servedPath = item.value ?: @"";
            }
            if ([item.name isEqualToString:@"e"]) {
                expired = item.value.longLongValue <= (long long)NSDate.date.timeIntervalSince1970;
            }
        }
    }

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
    NSString *root = sRootPath;
    if (!root || !VibeFakeHTTPServesHost(url.host)) {
        entry[@"outcome"] = @"unknown-host";
        entry[@"finished"] = @(VibeFakeHTTPNow());
        os_unfair_lock_unlock(&sLock);
        return nil;
    }
    NSString *entryOfShare = lookup ? VibeFakeHTTPEntryOfShare(root, shortGUID) : nil;
    if (lookup) {
        servedPath = entryOfShare ?: @"";
    }
    NSString *path = [root stringByAppendingPathComponent:servedPath].stringByStandardizingPath;
    NSString *relativePath = [path hasPrefix:[root stringByAppendingString:@"/"]]
            ? [path substringFromIndex:root.length] : nil;
    NSString *name = path.lastPathComponent;
    struct stat info = {0};
    BOOL exists = relativePath && stat(path.fileSystemRepresentation, &info) == 0;
    BOOL found = exists && S_ISREG(info.st_mode);
    VibeFakeHTTPVersion version = found ? VibeFakeHTTPVersionOf(relativePath, &info) : (VibeFakeHTTPVersion){0};
    if (lookup) {
        NSMutableDictionary *expiry = VibeFakeHTTPFault(@"expiry", entryOfShare);
        NSTimeInterval lifetime = expiry ? [expiry[@"seconds"] doubleValue] : kVibeFakeHTTPAddressLifetime;
        if (expiry) {
            VibeFakeHTTPApply(expiry, entry);
        }
        entry[@"status"] = @200;
        os_unfair_lock_unlock(&sLock);
        NSData *body = VibeFakeHTTPLookup(shortGUID, exists ? entryOfShare : nil, &info, version, lifetime);
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{@"Content-Type": @"application/json; charset=UTF-8"}];
        answer.length = body.length;
        answer.piece = MAX(body.length, (NSUInteger)1);
        answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
            return [body subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)count)];
        };
        answer.progress = ^(NSString *outcome, uint64_t delivered) {
            os_unfair_lock_lock(&sLock);
            VibeFakeHTTPNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
            os_unfair_lock_unlock(&sLock);
        };
        return answer;
    }
    NSMutableDictionary *fault = VibeFakeHTTPFault(@"latency", name);
    if (fault) {
        answer.latency = [fault[@"seconds"] doubleValue];
        VibeFakeHTTPApply(fault, entry);
    }
    NSInteger refusal = 0;
    NSDictionary<NSString *, NSString *> *refusalHeaders = @{@"Content-Type": @"text/plain"};
    NSData *refusalBody = nil;
    if ((fault = VibeFakeHTTPFault(@"status", name))) {
        refusal = [fault[@"status"] integerValue];
        refusalBody = [[NSString stringWithFormat:@"HTTP %ld", (long)refusal] dataUsingEncoding:NSUTF8StringEncoding];
        VibeFakeHTTPApply(fault, entry);
    }
    else if ((fault = VibeFakeHTTPFault(@"html", name))) {
        refusal = 200;
        refusalHeaders = @{@"Content-Type": @"text/html; charset=utf-8"};
        refusalBody = [@"<!doctype html><html><head><title>Vibe</title></head>"
                       @"<body>Not a song.</body></html>" dataUsingEncoding:NSUTF8StringEncoding];
        VibeFakeHTTPApply(fault, entry);
    }
    else if (!found) {
        refusal = 404;
        refusalBody = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
    }
    else if (expired) {
        refusal = 410;
        refusalBody = [@"Gone" dataUsingEncoding:NSUTF8StringEncoding];
    }
    // A shape a server with no ranges, no length, or a compressor answers in.
    NSString *shape = nil;
    for (NSString *kind in @[@"icy", @"no-length", @"gzip", @"no-range"]) {
        if (!refusal && (fault = VibeFakeHTTPFault(kind, name))) {
            shape = kind;
            VibeFakeHTTPApply(fault, entry);
            break;
        }
    }
    NSTimeInterval transferSeconds = sTransferSeconds;
    entry[@"size"] = @(version.size);
    entry[@"etag"] = version.etag ?: NSNull.null;
    os_unfair_lock_unlock(&sLock);

    NSFileHandle *file = refusal ? nil : [NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path]
                                                                            error:NULL];
    if (!refusal && !file) {
        refusal = 500;
    }
    NSMutableDictionary<NSString *, NSString *> *headers = nil;
    NSInteger status = refusal;
    uint64_t first = 0, length = 0;
    BOOL paced = NO;
    if (refusal) {
        headers = [refusalHeaders mutableCopy];
        length = refusalBody.length;
        headers[@"Content-Length"] = @(length).stringValue;
        answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
            return [refusalBody subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)count)];
        };
    }
    else {
        headers = [@{
            @"ETag": version.etag,
            @"Last-Modified": version.lastModified,
            @"Content-Type": VibeFakeHTTPContentType(name.pathExtension),
            @"Accept-Ranges": @"bytes",
        } mutableCopy];
        status = VibeFakeHTTPRangeStatus(shape ? nil : range, version.size, headers, &first, &length);
        if (status == 416) {
            [headers removeObjectForKey:@"Content-Type"];
        }
        // An open range is the rest of the file, paced. A closed one, the
        // probe, a tag read, or the tail window, answers at once.
        paced = status == 200 || (status == 206 && [range hasSuffix:@"-"]);
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
        // iCloud sends no ETag, Last-Modified when it signed the address, and
        // the name in the address back as the file's.
        if (signedAddress) {
            [headers removeObjectForKey:@"ETag"];
            headers[@"Last-Modified"] = VibeFakeHTTPDate((time_t)NSDate.date.timeIntervalSince1970);
            NSString *echo = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO]
                    .percentEncodedPath.lastPathComponent;
            headers[@"Content-Disposition"] = [NSString stringWithFormat:@"attachment; filename*=UTF-8''%@", echo];
        }
        answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
            return [file seekToOffset:first + offset error:NULL] ? [file readDataUpToLength:(NSUInteger)count error:NULL]
                                                                 : nil;
        };
    }
    answer.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1"
                                                headerFields:headers];
    answer.length = length;
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(status);
    entry[@"paced"] = @(paced);
    os_unfair_lock_unlock(&sLock);
    if (!paced) {
        answer.piece = MAX(length, (uint64_t)1);
    }
    else {
        answer.interval = transferSeconds > 0 && version.size > 0 ? transferSeconds * kPieceBytes / version.size : 0;
        NSTimeInterval paceInterval = answer.interval;
        // The fault that cuts this body, should the next piece reach it.
        __block NSMutableDictionary *cut = nil;
        answer.beforePiece = ^(VibeFakeHTTPAnswer *body, uint64_t delivered) {
            os_unfair_lock_lock(&sLock);
            NSMutableDictionary *stall = VibeFakeHTTPFault(@"stall", name);
            uint64_t stallAt = [stall[@"after"] unsignedLongLongValue];
            body.holdAt = stall ? (stallAt > first ? stallAt - first : 0) : UINT64_MAX;
            BOOL stalled = stall && delivered >= body.holdAt;
            if (stalled && ![entry[@"faults"] containsObject:@"stall"]) {
                VibeFakeHTTPApply(stall, entry);
            }
            cut = stalled ? nil : (VibeFakeHTTPFault(@"drop", name) ?: VibeFakeHTTPFault(@"etag-change", name));
            uint64_t cutAt = [cut[@"after"] unsignedLongLongValue];
            body.cutAt = cut ? (cutAt > first ? cutAt - first : 0) : UINT64_MAX;
            NSMutableDictionary *rate = VibeFakeHTTPFault(@"rate", name);
            body.interval = rate ? (double)kPieceBytes / [rate[@"rate"] unsignedLongLongValue] : paceInterval;
            if (rate && ![entry[@"faults"] containsObject:@"rate"]) {
                VibeFakeHTTPApply(rate, entry);
            }
            os_unfair_lock_unlock(&sLock);
        };
        answer.progress = ^(NSString *outcome, uint64_t delivered) {
            os_unfair_lock_lock(&sLock);
            if ([outcome isEqualToString:@"dropped"] && cut) {
                if ([cut[@"kind"] isEqualToString:@"etag-change"]) {
                    sVersions[relativePath] = @(sVersions[relativePath].unsignedIntegerValue + 1);
                }
                VibeFakeHTTPApply(cut, entry);
            }
            VibeFakeHTTPNote(entry, outcome, delivered);
            os_unfair_lock_unlock(&sLock);
        };
        return answer;
    }
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        VibeFakeHTTPNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
        os_unfair_lock_unlock(&sLock);
    };
    return answer;
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
