//
//  VibeFakeDropbox.m
//  Vibe (iOS)
//

#if DEBUG

#import "VibeFakeDropbox.h"

#import <os/lock.h>
#import <sys/stat.h>

#import "AudioFileOpenRules.h"
#import "DropboxClientInternal.h"
#import "DropboxRules.h"
#import "NSURL+Hash.h"

static NSString *const kFakeAccountID = @"dbid:fake";
static NSString *const kFakeAccountName = @"Fake Dropbox";
static const NSUInteger kSearchLimit = 50;
static const uint64_t kPieceBytes = 64 * 1024;
static const NSUInteger kLogLimit = 200;
static const NSTimeInterval kStallPollSeconds = 0.1;

// One record per fixture entry: where it is, and its Dropbox path with the
// disk's case. Keyed by lowercase Dropbox path, which is also the id.
@interface VibeFakeDropboxItem : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL folder;
// The current version, under sLock: a new rev whenever the file's size or
// mtime moves (a re-upload) or a rev-change fault fires.
@property (atomic, copy) NSString *rev;
@property (nonatomic, copy) NSString *revStamp;
@end

@implementation VibeFakeDropboxItem
@end

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, VibeFakeDropboxItem *> *sItems;
// Every rev issued, the replaced ones too: Dropbox serves a `rev:` path for
// any version it still has.
static NSMutableDictionary<NSString *, VibeFakeDropboxItem *> *sRevs;
static uint64_t sRevCounter;
static NSTimeInterval sTransferSeconds;
static CFAbsoluteTime sInstallTime;
static NSMutableDictionary<NSString *, NSNumber *> *sStatistics;
static NSMutableDictionary<NSString *, NSNumber *> *sDownloadKinds;
static NSMutableArray<NSMutableDictionary *> *sFaults;
// The downloads and reads, each line updated as its request proceeds; under
// sLock, copied out by statistics.
static NSMutableArray<NSMutableDictionary *> *sLog;
static NSUInteger sLogSequence;
// Pieces of a download are delivered here, never on CFNetwork's protocol
// thread: a sleep there would queue every other request behind it and hold
// a cancel until the whole file had gone out.
static dispatch_queue_t sDeliveryQueue;

static NSArray<NSString *> *VibeFakeDropboxFaultKinds(void) {
    return @[@"stall", @"drop", @"rev-change", @"throttle", @"expired-token", @"tail-fail", @"slow-tail", @"slow-tags", @"rate", @"latency"];
}

// Under sLock.
static void VibeFakeDropboxIssueRev(VibeFakeDropboxItem *item) {
    NSString *rev = [NSString stringWithFormat:@"%09llx", ++sRevCounter];
    sRevs[rev] = item;
    item.rev = rev;
}

// A file changed on disk since its rev was issued is a new version, as a
// re-upload is: its cacheKey moved. Under sLock.
static NSString *VibeFakeDropboxRefreshRev(VibeFakeDropboxItem *item) {
    NSString *stamp = [item.url cacheKey] ?: @"";
    if (!item.rev || ![stamp isEqualToString:item.revStamp]) {
        item.revStamp = stamp;
        VibeFakeDropboxIssueRev(item);
    }
    return item.rev;
}

// The whole fixture, once: a walk of the tree keyed by lowercase path. Under
// sLock, since it issues revs.
static NSDictionary<NSString *, VibeFakeDropboxItem *> *VibeFakeDropboxIndex(NSURL *root) {
    NSMutableDictionary<NSString *, VibeFakeDropboxItem *> *items = [NSMutableDictionary dictionary];
    VibeFakeDropboxItem *account = [[VibeFakeDropboxItem alloc] init];
    account.url = root;
    account.path = @"";
    account.folder = YES;
    items[@""] = account;
    NSString *rootPath = root.path;
    NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
            enumeratorAtURL:root
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        VibeFakeDropboxItem *item = [[VibeFakeDropboxItem alloc] init];
        item.url = url;
        item.path = [url.URLByStandardizingPath.path substringFromIndex:rootPath.length];
        item.folder = isDirectory.boolValue;
        if (!item.folder) {
            VibeFakeDropboxRefreshRev(item);
        }
        items[item.path.lowercaseString] = item;
    }
    return items;
}

// An item as a list_folder entry, at `rev`: the shape the mirror reads, and
// the Dropbox-API-Result of a download.
static NSDictionary *VibeFakeDropboxEntry(VibeFakeDropboxItem *item, NSString *rev) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @".tag": item.folder ? @"folder" : @"file",
        @"name": item.url.lastPathComponent,
        @"path_display": item.path,
        @"path_lower": item.path.lowercaseString,
        @"id": [@"id:" stringByAppendingString:item.path.lowercaseString],
    }];
    if (!item.folder) {
        if (!rev) {
            os_unfair_lock_lock(&sLock);
            rev = VibeFakeDropboxRefreshRev(item);
            os_unfair_lock_unlock(&sLock);
        }
        // One stat, since NSURL caches resource values.
        struct stat info;
        BOOL stated = stat(item.url.fileSystemRepresentation, &info) == 0;
        NSDate *modified = stated ? [NSDate dateWithTimeIntervalSince1970:info.st_mtimespec.tv_sec] : nil;
        entry[@"size"] = @(stated ? info.st_size : 0);
        // Dropbox's form, UTC to the second: what VibeDropboxParseTimestamp reads.
        entry[@"server_modified"] = [NSISO8601DateFormatter stringFromDate:modified ?: NSDate.date
                                                                  timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]
                                                             formatOptions:NSISO8601DateFormatWithInternetDateTime];
        entry[@"client_modified"] = entry[@"server_modified"];
        entry[@"rev"] = rev;
    }
    return entry;
}

static VibeFakeDropboxItem *VibeFakeDropboxLookup(NSDictionary<NSString *, VibeFakeDropboxItem *> *items,
                                                  NSString *pathOrID) {
    NSString *path = [pathOrID hasPrefix:@"id:"] ? [pathOrID substringFromIndex:3] : pathOrID;
    return items[path.lowercaseString];
}

// The first fault of `kind` for the file of that basename. Under sLock.
static NSMutableDictionary *VibeFakeDropboxFault(NSString *kind, NSString *name) {
    for (NSMutableDictionary *fault in sFaults) {
        NSString *file = fault[@"file"];
        if ([fault[@"kind"] isEqualToString:kind]
                && (!file || (name && [file caseInsensitiveCompare:name] == NSOrderedSame))) {
            return fault;
        }
    }
    return nil;
}

typedef struct {
    NSInteger status;
    NSDictionary<NSString *, NSString *> *headers;
    NSData *body;
} VibeFakeDropboxResponse;

static VibeFakeDropboxResponse VibeFakeDropboxJSON(NSInteger status, id object) {
    return (VibeFakeDropboxResponse){status, @{@"Content-Type": @"application/json"},
                                     [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]};
}

static VibeFakeDropboxResponse VibeFakeDropboxNotFound(void) {
    return VibeFakeDropboxJSON(409, @{@"error_summary": @"path/not_found/",
                                      @"error": @{@".tag": @"path", @"path": @{@".tag": @"not_found"}}});
}

// files/download's headers as Dropbox sends them, a 206 included: the
// version's metadata, and a type, since with none the session sniffs the
// first 512 bytes before handing the client the response.
static NSMutableDictionary<NSString *, NSString *> *VibeFakeDropboxContentHeaders(NSDictionary *metadata,
                                                                                 uint64_t length) {
    return [@{@"Dropbox-API-Result": VibeDropboxAPIArgHeader(metadata) ?: @"{}",
              @"Content-Type": @"application/octet-stream",
              @"Content-Length": @(length).stringValue} mutableCopy];
}

@interface VibeFakeDropboxProtocol : NSURLProtocol
@property (atomic) BOOL cancelled;
// This request's log line; mutated under sLock.
@property (nonatomic, nullable) NSMutableDictionary *entry;
@end

@implementation VibeFakeDropboxProtocol

// On sessions the client alone owns, so every request is Dropbox's.
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

// The body, which a POST made with a stream carries as one.
static NSData *VibeFakeDropboxBody(NSURLRequest *request) {
    if (request.HTTPBody) {
        return request.HTTPBody;
    }
    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    [stream open];
    while (stream.hasBytesAvailable) {
        NSInteger read = [stream read:buffer maxLength:sizeof buffer];
        if (read <= 0) {
            break;
        }
        [data appendBytes:buffer length:(NSUInteger)read];
    }
    [stream close];
    return data;
}

- (void)startLoading {
    NSURLRequest *request = self.request;
    NSString *endpoint = request.URL.path;
    os_unfair_lock_lock(&sLock);
    NSDictionary<NSString *, VibeFakeDropboxItem *> *items = sItems;
    sStatistics[endpoint] = @(sStatistics[endpoint].unsignedIntegerValue + 1);
    os_unfair_lock_unlock(&sLock);

    if ([endpoint isEqualToString:@"/2/files/download"]) {
        [self serveDownloadFrom:items];
        return;
    }
    NSData *body = VibeFakeDropboxBody(request);
    NSDictionary *json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        json = nil;
    }
    [self finishWith:[self respondTo:endpoint json:json items:items]];
}

- (VibeFakeDropboxResponse)respondTo:(NSString *)endpoint
                                json:(NSDictionary *)json
                               items:(NSDictionary<NSString *, VibeFakeDropboxItem *> *)items {
    if ([endpoint isEqualToString:@"/oauth2/token"]) {
        return VibeFakeDropboxJSON(200, @{@"access_token": @"fake-access", @"expires_in": @14400,
                                          @"token_type": @"bearer"});
    }
    if ([endpoint isEqualToString:@"/2/auth/token/revoke"]) {
        return VibeFakeDropboxJSON(200, @{});
    }
    if ([endpoint isEqualToString:@"/2/users/get_current_account"]) {
        return VibeFakeDropboxJSON(200, @{@"account_id": kFakeAccountID,
                                          @"name": @{@"display_name": kFakeAccountName}});
    }
    if ([endpoint isEqualToString:@"/2/files/list_folder"]) {
        NSString *path = [json[@"path"] isKindOfClass:NSString.class] ? json[@"path"] : @"";
        VibeFakeDropboxItem *folder = VibeFakeDropboxLookup(items, path);
        if (!folder.folder) {
            return VibeFakeDropboxNotFound();
        }
        NSString *prefix = [folder.path.lowercaseString stringByAppendingString:@"/"];
        NSMutableArray *entries = [NSMutableArray array];
        for (NSString *key in items) {
            // Direct children: under the prefix, with no slash left over.
            if (key.length > prefix.length && [key hasPrefix:prefix]
                    && [[key substringFromIndex:prefix.length] rangeOfString:@"/"].location == NSNotFound) {
                [entries addObject:VibeFakeDropboxEntry(items[key], nil)];
            }
        }
        return VibeFakeDropboxJSON(200, @{@"entries": entries, @"cursor": @"fake", @"has_more": @NO});
    }
    if ([endpoint isEqualToString:@"/2/files/search_v2"]) {
        NSString *query = [json[@"query"] isKindOfClass:NSString.class] ? json[@"query"] : @"";
        NSMutableArray *matches = [NSMutableArray array];
        for (NSString *key in [items.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (matches.count >= kSearchLimit) {
                break;
            }
            VibeFakeDropboxItem *item = items[key];
            if (key.length == 0 || (query.length > 0 && [item.url.lastPathComponent rangeOfString:query
                                                            options:NSCaseInsensitiveSearch].location == NSNotFound)) {
                continue;
            }
            [matches addObject:@{@"match_type": @{@".tag": @"filename"},
                                 @"metadata": @{@".tag": @"metadata", @"metadata": VibeFakeDropboxEntry(item, nil)}}];
        }
        return VibeFakeDropboxJSON(200, @{@"matches": matches, @"has_more": @NO});
    }
    return VibeFakeDropboxJSON(400, @{@"error_summary": [@"unexpected endpoint " stringByAppendingString:endpoint]});
}

// files/download: the path, id or rev from the Dropbox-API-Arg header. Four
// kinds by their Range: none is a whole download and an open one
// (`bytes=N-`) the client's resend, both paced off this thread, each piece
// read as it is sent; a closed one is a tag read, or the tail window when it
// is the file's last VibeAudioFileTailWindowBytes, answered at once. The
// request-time faults land here, the delivery-time ones in deliverPieceOf:.
- (void)serveDownloadFrom:(NSDictionary<NSString *, VibeFakeDropboxItem *> *)items {
    NSString *argument = [self.request valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    NSDictionary *arg = argument
            ? [NSJSONSerialization JSONObjectWithData:[argument dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL]
            : nil;
    NSString *path = [arg[@"path"] isKindOfClass:NSString.class] ? arg[@"path"] : @"";
    NSString *range = [self.request valueForHTTPHeaderField:@"Range"];
    unsigned long long first = 0, last = ULLONG_MAX;
    if (range) {
        sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
    }
    BOOL closed = range && ![range hasSuffix:@"-"];
    BOOL byRev = [path hasPrefix:@"rev:"];
    BOOL download = !closed;

    os_unfair_lock_lock(&sLock);
    VibeFakeDropboxItem *item = byRev ? sRevs[[path substringFromIndex:4]] : VibeFakeDropboxLookup(items, path);
    NSString *name = item.url.lastPathComponent;
    // The tail read goes by id as a tag read does: it is the one closed range
    // spanning exactly the file's window up to its last byte.
    struct stat info;
    uint64_t size = item && !item.folder && stat(item.url.fileSystemRepresentation, &info) == 0 ? (uint64_t)info.st_size : 0;
    uint64_t window = VibeAudioFileTailWindowBytes(name.pathExtension ?: @"", size);
    BOOL tail = closed && window > 0 && last == size - 1 && last - first + 1 == window;
    NSString *kind = !range ? @"whole" : !closed ? @"resume" : tail ? @"tail" : @"ranged";
    NSString *rev = byRev ? [path substringFromIndex:4] : item && !item.folder ? VibeFakeDropboxRefreshRev(item) : nil;
    sDownloadKinds[kind] = @(sDownloadKinds[kind].unsignedIntegerValue + 1);
    NSMutableDictionary *entry = [@{@"seq": @(++sLogSequence),
                                    @"t": @(round((CFAbsoluteTimeGetCurrent() - sInstallTime) * 1000) / 1000),
                                    @"file": name ?: path, @"kind": kind, @"range": range ?: NSNull.null,
                                    @"rev": rev ?: NSNull.null, @"status": @0, @"delivered": @0,
                                    @"outcome": @"running"} mutableCopy];
    [sLog addObject:entry];
    if (sLog.count > kLogLimit) {
        [sLog removeObjectAtIndex:0];
    }
    self.entry = entry;
    VibeFakeDropboxResponse refusal = {0, nil, nil};
    NSTimeInterval delay = 0;
    if (download) {
        NSMutableDictionary *fault = VibeFakeDropboxFault(@"throttle", name);
        if (fault) {
            [sFaults removeObject:fault];
            refusal = VibeFakeDropboxJSON(429, @{@"error_summary": @"too_many_requests/",
                                                 @"error": @{@"reason": @{@".tag": @"too_many_requests"},
                                                             @"retry_after": fault[@"seconds"]}});
            NSMutableDictionary *headers = [refusal.headers mutableCopy];
            headers[@"Retry-After"] = [fault[@"seconds"] stringValue];
            refusal.headers = headers;
        }
        else if ((fault = VibeFakeDropboxFault(@"expired-token", name))) {
            [sFaults removeObject:fault];
            refusal = VibeFakeDropboxJSON(401, @{@"error_summary": @"expired_access_token/",
                                                 @"error": @{@".tag": @"expired_access_token"}});
        }
    }
    else if (tail) {
        if (VibeFakeDropboxFault(@"tail-fail", name)) {
            refusal = (VibeFakeDropboxResponse){500, @{@"Content-Type": @"text/plain"},
                                                [@"Internal Server Error" dataUsingEncoding:NSUTF8StringEncoding]};
        }
        delay = [VibeFakeDropboxFault(@"slow-tail", name)[@"seconds"] doubleValue];
    }
    else {
        delay = [VibeFakeDropboxFault(@"slow-tags", name)[@"seconds"] doubleValue];
    }
    NSTimeInterval latency = [VibeFakeDropboxFault(@"latency", name)[@"seconds"] doubleValue];
    delay += latency;
    NSTimeInterval transferSeconds = sTransferSeconds;
    os_unfair_lock_unlock(&sLock);

    NSFileHandle *file = item && !item.folder ? [NSFileHandle fileHandleForReadingFromURL:item.url error:NULL] : nil;
    if (!file) {
        [self finishWith:VibeFakeDropboxNotFound()];
        return;
    }
    if (refusal.status) {
        [self finishWith:refusal];
        return;
    }
    NSDictionary *metadata = VibeFakeDropboxEntry(item, rev);
    uint64_t length = [metadata[@"size"] unsignedLongLongValue];
    if (range && first >= length) {
        [self finishWith:(VibeFakeDropboxResponse){416, @{@"Content-Range": [NSString stringWithFormat:@"bytes */%llu", length]}, nil}];
        return;
    }
    if (closed) {
        last = MIN(last, length - 1);
        NSData *slice = [NSData data];
        if (first <= last && [file seekToOffset:first error:NULL]) {
            slice = [file readDataUpToLength:(NSUInteger)(last - first + 1) error:NULL] ?: slice;
        }
        NSMutableDictionary *headers = VibeFakeDropboxContentHeaders(metadata, slice.length);
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", first, last, length];
        VibeFakeDropboxResponse answer = {206, headers, slice};
        if (delay <= 0) {
            [self finishWith:answer];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), sDeliveryQueue, ^{
            if (!self.cancelled) {
                [self finishWith:answer];
            }
        });
        return;
    }
    if (first > 0 && ![file seekToOffset:first error:NULL]) {
        [self finishWith:VibeFakeDropboxNotFound()];
        return;
    }
    NSMutableDictionary *headers = VibeFakeDropboxContentHeaders(metadata, length - first);
    if (range) {
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", first, length - 1, length];
    }
    NSInteger status = range ? 206 : 200;
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(status);
    entry[@"size"] = @(length);
    os_unfair_lock_unlock(&sLock);
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers];
    NSTimeInterval interval = transferSeconds > 0 && length > 0 ? transferSeconds * kPieceBytes / length : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(latency * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self deliverPieceOf:file item:item at:first from:first size:length every:interval after:interval];
    });
}

// One piece per step, so the bytes written — the progress the loading bar
// reads — grow as a real transfer's do, and a cancel lands between pieces.
// The faults are read at every step, so one set mid-transfer applies to it.
- (void)deliverPieceOf:(NSFileHandle *)file
                  item:(VibeFakeDropboxItem *)item
                    at:(uint64_t)offset
                  from:(uint64_t)from
                  size:(uint64_t)length
                 every:(NSTimeInterval)interval
                 after:(NSTimeInterval)wait {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        NSString *name = item.url.lastPathComponent;
        uint64_t piece = MIN(kPieceBytes, length - offset);
        NSTimeInterval next = interval;
        os_unfair_lock_lock(&sLock);
        NSMutableDictionary *stall = VibeFakeDropboxFault(@"stall", name);
        BOOL stalled = stall && offset >= [stall[@"after"] unsignedLongLongValue];
        NSMutableDictionary *cut = stalled ? nil
                : (VibeFakeDropboxFault(@"drop", name) ?: VibeFakeDropboxFault(@"rev-change", name));
        uint64_t cutAt = [cut[@"after"] unsignedLongLongValue];
        if (cut && offset + piece < cutAt) {
            cut = nil;
        }
        if (cut) {
            piece = cutAt > offset ? cutAt - offset : 0;
            [sFaults removeObject:cut];
            if ([cut[@"kind"] isEqualToString:@"rev-change"]) {
                VibeFakeDropboxIssueRev(item);
            }
        }
        else if (!stalled && stall) {
            // A stall not reached yet stops this piece at its offset.
            piece = MIN(piece, [stall[@"after"] unsignedLongLongValue] - offset);
        }
        uint64_t rate = [VibeFakeDropboxFault(@"rate", name)[@"rate"] unsignedLongLongValue];
        if (rate > 0) {
            next = (double)kPieceBytes / rate;
        }
        self.entry[@"outcome"] = stalled ? @"stalled" : @"running";
        os_unfair_lock_unlock(&sLock);
        if (stalled) {
            [self deliverPieceOf:file item:item at:offset from:from size:length every:interval after:kStallPollSeconds];
            return;
        }
        NSData *bytes = piece > 0 ? [file readDataUpToLength:(NSUInteger)piece error:NULL] : [NSData data];
        if (bytes.length > 0) {
            [self.client URLProtocol:self didLoadData:bytes];
        }
        uint64_t reached = offset + bytes.length;
        BOOL complete = !cut && (reached >= length || (piece > 0 && bytes.length == 0));
        os_unfair_lock_lock(&sLock);
        self.entry[@"delivered"] = @(reached - from);
        if (cut || complete) {
            self.entry[@"outcome"] = cut ? @"dropped" : @"complete";
        }
        os_unfair_lock_unlock(&sLock);
        if (cut) {
            [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                               code:NSURLErrorNetworkConnectionLost
                                                                           userInfo:nil]];
            return;
        }
        if (complete) {
            [self.client URLProtocolDidFinishLoading:self];
            return;
        }
        [self deliverPieceOf:file item:item at:reached from:from size:length every:interval after:next];
    });
}

- (void)finishWith:(VibeFakeDropboxResponse)answer {
    os_unfair_lock_lock(&sLock);
    if (self.entry) {
        self.entry[@"status"] = @(answer.status);
        self.entry[@"delivered"] = @(answer.body.length);
        self.entry[@"outcome"] = @"answered";
    }
    os_unfair_lock_unlock(&sLock);
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:answer.status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:answer.headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (answer.body.length > 0) {
        [self.client URLProtocol:self didLoadData:answer.body];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

// Also sent after a load that finished, so only a line still running was
// cancelled.
- (void)stopLoading {
    self.cancelled = YES;
    os_unfair_lock_lock(&sLock);
    NSString *outcome = self.entry[@"outcome"];
    if ([outcome isEqualToString:@"running"] || [outcome isEqualToString:@"stalled"]) {
        self.entry[@"outcome"] = @"cancelled";
    }
    os_unfair_lock_unlock(&sLock);
}

@end

@implementation VibeFakeDropbox

+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client {
    os_unfair_lock_lock(&sLock);
    // TRAP: never rebuild the sessions under transfers in flight. The client
    // keys a download by its task's identifier, which counts from 1 in every
    // session, so a new session's download takes an old one's entry and the
    // old one's callbacks land on it.
    BOOL installed = sItems != nil;
    sRevs = [NSMutableDictionary dictionary];
    sItems = VibeFakeDropboxIndex(directory.URLByStandardizingPath);
    sTransferSeconds = transferSeconds;
    sInstallTime = CFAbsoluteTimeGetCurrent();
    sStatistics = [NSMutableDictionary dictionary];
    sDownloadKinds = [NSMutableDictionary dictionary];
    sFaults = [NSMutableArray array];
    sLog = [NSMutableArray array];
    if (!sDeliveryQueue) {
        sDeliveryQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.fake-dropbox", DISPATCH_QUEUE_SERIAL);
    }
    os_unfair_lock_unlock(&sLock);
    if (installed && client.isLinked) {
        return;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[VibeFakeDropboxProtocol.class];
    [client useSessionConfiguration:configuration];
    [client adoptRefreshToken:@"fake-refresh" accountID:kFakeAccountID];
}

+ (void)uninstallFromClient:(DropboxClient *)client {
    if (![self isInstalled]) {
        return;
    }
    [client signOut];
    [client useSessionConfiguration:nil];
    os_unfair_lock_lock(&sLock);
    sItems = nil;
    [sFaults removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sItems != nil;
    os_unfair_lock_unlock(&sLock);
    return installed;
}

+ (BOOL)addFaultOfKind:(NSString *)kind
                  file:(NSString *)file
                 after:(uint64_t)after
               seconds:(NSTimeInterval)seconds
                  rate:(uint64_t)rate {
    if (![VibeFakeDropboxFaultKinds() containsObject:kind]) {
        return NO;
    }
    NSMutableDictionary *fault = [@{@"kind": kind, @"after": @(after), @"seconds": @(seconds),
                                    @"rate": @(rate)} mutableCopy];
    fault[@"file"] = file;
    os_unfair_lock_lock(&sLock);
    [sFaults addObject:fault];
    os_unfair_lock_unlock(&sLock);
    return YES;
}

+ (void)clearFaults {
    os_unfair_lock_lock(&sLock);
    [sFaults removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

+ (void)resumeStalls {
    os_unfair_lock_lock(&sLock);
    [sFaults filterUsingPredicate:[NSPredicate predicateWithFormat:@"kind != 'stall'"]];
    os_unfair_lock_unlock(&sLock);
}

+ (NSDictionary *)statistics {
    os_unfair_lock_lock(&sLock);
    NSMutableArray *log = [NSMutableArray arrayWithCapacity:sLog.count];
    NSMutableArray *transfers = [NSMutableArray array];
    for (NSDictionary *entry in sLog) {
        [log addObject:[entry copy]];
        BOOL download = [entry[@"kind"] isEqualToString:@"whole"] || [entry[@"kind"] isEqualToString:@"resume"];
        if (download && ([entry[@"outcome"] isEqualToString:@"running"]
                         || [entry[@"outcome"] isEqualToString:@"stalled"])) {
            [transfers addObject:[entry copy]];
        }
    }
    NSMutableArray *faults = [NSMutableArray arrayWithCapacity:sFaults.count];
    for (NSDictionary *fault in sFaults) {
        [faults addObject:[fault copy]];
    }
    NSDictionary *statistics = @{
        @"requests": [sStatistics copy] ?: @{},
        @"downloads": [sDownloadKinds copy] ?: @{},
        @"faults": faults,
        @"transfers": transfers,
        @"log": log,
    };
    os_unfair_lock_unlock(&sLock);
    return statistics;
}

@end

#endif
