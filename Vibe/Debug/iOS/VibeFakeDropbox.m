//
//  VibeFakeDropbox.m
//  Vibe (iOS)
//

#if DEBUG

#import "VibeFakeDropbox.h"

#import <os/lock.h>
#import <sys/stat.h>

#import "TailWindowMath.h"
#import "DropboxClientInternal.h"
#import "DropboxRules.h"
#import "NSURL+Hash.h"
#import "VibeFakeHTTPProtocol.h"

static NSString *const kFakeAccountID = @"dbid:fake";
static NSString *const kFakeAccountName = @"Fake Dropbox";
static const NSUInteger kSearchLimit = 50;
static const NSUInteger kLogLimit = 200;

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
// TRAP: the walk names each entry relative to the root. A walked absolute
// path need not spell the root as the caller did: standardizing drops
// /private from /private/tmp, and a walk through a symlink answers the
// resolved path. Cutting the root's length off one crashed past its end.
static NSDictionary<NSString *, VibeFakeDropboxItem *> *VibeFakeDropboxIndex(NSURL *root) {
    NSMutableDictionary<NSString *, VibeFakeDropboxItem *> *items = [NSMutableDictionary dictionary];
    VibeFakeDropboxItem *account = [[VibeFakeDropboxItem alloc] init];
    account.url = root;
    account.path = @"";
    account.folder = YES;
    items[@""] = account;
    NSDirectoryEnumerator<NSString *> *walk = [NSFileManager.defaultManager enumeratorAtPath:root.path];
    for (NSString *relative in walk) {
        BOOL folder = [walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory];
        if ([relative.lastPathComponent hasPrefix:@"."]) {
            if (folder) {
                [walk skipDescendants];
            }
            continue;
        }
        VibeFakeDropboxItem *item = [[VibeFakeDropboxItem alloc] init];
        item.url = [root URLByAppendingPathComponent:relative isDirectory:folder];
        item.path = [@"/" stringByAppendingString:relative];
        item.folder = folder;
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

// The engine's answer for a response sent whole and at once.
static VibeFakeHTTPAnswer *VibeFakeDropboxAnswer(NSURLRequest *request, VibeFakeDropboxResponse response) {
    NSData *body = response.body ?: [NSData data];
    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:response.status
                                                 HTTPVersion:@"HTTP/1.1" headerFields:response.headers];
    answer.length = body.length;
    answer.piece = MAX(body.length, (NSUInteger)1);
    answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
        return [body subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)count)];
    };
    return answer;
}

// A download's log line, as its answer proceeds. A cancel marks only a line
// still running. Under sLock.
static void VibeFakeDropboxNote(NSMutableDictionary *entry, NSString *outcome, uint64_t delivered) {
    NSString *was = entry[@"outcome"];
    if ([outcome isEqualToString:@"cancelled"]) {
        if ([was isEqualToString:@"running"] || [was isEqualToString:@"stalled"]) {
            entry[@"outcome"] = outcome;
        }
        return;
    }
    entry[@"delivered"] = @(delivered);
    entry[@"outcome"] = outcome;
}

// vibe-libs' engine (VibeFakeHTTPProtocol.h) delivers each answer: the
// pieces, the hold, the lost connection and the pace. This class answers as
// the account.
@interface VibeFakeDropboxProtocol : VibeFakeHTTPProtocol
@end

@implementation VibeFakeDropboxProtocol

- (VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request {
    NSString *endpoint = request.URL.path;
    os_unfair_lock_lock(&sLock);
    NSDictionary<NSString *, VibeFakeDropboxItem *> *items = sItems;
    sStatistics[endpoint] = @(sStatistics[endpoint].unsignedIntegerValue + 1);
    os_unfair_lock_unlock(&sLock);

    if ([endpoint isEqualToString:@"/2/files/download"]) {
        return [self answerDownload:request items:items];
    }
    NSData *body = VibeFakeHTTPBodyOfRequest(request);
    NSDictionary *json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        json = nil;
    }
    return VibeFakeDropboxAnswer(request, [self respondTo:endpoint json:json items:items]);
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
// (`bytes=N-`) the client's resend, both paced; a closed one is a tag read,
// or the tail window when it is the file's last VibeAudioFileTailWindowBytes,
// answered at once. A refusal answers at once too. The request-time faults
// land here, the delivery-time ones in pace:.
- (VibeFakeHTTPAnswer *)answerDownload:(NSURLRequest *)request
                                 items:(NSDictionary<NSString *, VibeFakeDropboxItem *> *)items {
    NSString *argument = [request valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    NSDictionary *arg = argument
            ? [NSJSONSerialization JSONObjectWithData:[argument dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL]
            : nil;
    NSString *path = [arg[@"path"] isKindOfClass:NSString.class] ? arg[@"path"] : @"";
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    unsigned long long first = 0, last = ULLONG_MAX;
    if (range) {
        sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
    }
    BOOL closed = range && ![range hasSuffix:@"-"];
    BOOL byRev = [path hasPrefix:@"rev:"];

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
    VibeFakeDropboxResponse refusal = {0, nil, nil};
    // A server's time to first byte. A closed range waits for its slow fault too.
    NSTimeInterval latency = [VibeFakeDropboxFault(@"latency", name)[@"seconds"] doubleValue];
    if (!closed) {
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
        latency += [VibeFakeDropboxFault(@"slow-tail", name)[@"seconds"] doubleValue];
    }
    else {
        latency += [VibeFakeDropboxFault(@"slow-tags", name)[@"seconds"] doubleValue];
    }
    NSTimeInterval transferSeconds = sTransferSeconds;
    os_unfair_lock_unlock(&sLock);

    NSFileHandle *file = item && !item.folder ? [NSFileHandle fileHandleForReadingFromURL:item.url error:NULL] : nil;
    NSDictionary *metadata = file ? VibeFakeDropboxEntry(item, rev) : nil;
    uint64_t length = [metadata[@"size"] unsignedLongLongValue];
    if (!file) {
        refusal = VibeFakeDropboxNotFound();
    }
    else if (!refusal.status && range && first >= length) {
        refusal = (VibeFakeDropboxResponse){416, @{@"Content-Range": [NSString stringWithFormat:@"bytes */%llu", length]}, nil};
    }
    VibeFakeHTTPAnswer *answer = nil;
    if (refusal.status) {
        answer = VibeFakeDropboxAnswer(request, refusal);
    }
    else {
        // files/download's headers as Dropbox sends them, a 206 included: the
        // version's metadata, and a type, since with none the session sniffs
        // the first 512 bytes before handing the client the response.
        NSMutableDictionary<NSString *, NSString *> *headers =
                [@{@"Dropbox-API-Result": VibeDropboxAPIArgHeader(metadata) ?: @"{}",
                   @"Content-Type": @"application/octet-stream"} mutableCopy];
        uint64_t offset = 0, count = 0;
        NSInteger status = VibeFakeHTTPRangeStatus(range, length, headers, &offset, &count);
        answer = [[VibeFakeHTTPAnswer alloc] init];
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status
                                                     HTTPVersion:@"HTTP/1.1" headerFields:headers];
        answer.length = count;
        answer.latency = latency;
        answer.bytes = ^NSData *(uint64_t at, uint64_t bytes) {
            return [file seekToOffset:offset + at error:NULL] ? [file readDataUpToLength:(NSUInteger)bytes error:NULL]
                                                              : nil;
        };
        if (closed) {
            answer.piece = MAX(count, (uint64_t)1);
        }
        else {
            [self pace:answer item:item entry:entry first:offset size:length transferSeconds:transferSeconds];
        }
    }
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(answer.response.statusCode);
    if (!refusal.status && !closed) {
        entry[@"size"] = @(length);
    }
    os_unfair_lock_unlock(&sLock);
    if (!answer.progress) {
        answer.progress = ^(NSString *outcome, uint64_t delivered) {
            os_unfair_lock_lock(&sLock);
            VibeFakeDropboxNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
            os_unfair_lock_unlock(&sLock);
        };
    }
    return answer;
}

// A download's body, paced in pieces so the whole file takes about
// transferSeconds. The bytes written, which the loading bar reads, grow as a
// real transfer's do. The faults are read before every piece, so one set
// mid-transfer applies to it.
- (void)pace:(VibeFakeHTTPAnswer *)answer
             item:(VibeFakeDropboxItem *)item
            entry:(NSMutableDictionary *)entry
            first:(uint64_t)first
             size:(uint64_t)size
  transferSeconds:(NSTimeInterval)transferSeconds {
    NSString *name = item.url.lastPathComponent;
    NSTimeInterval paced = transferSeconds > 0 && size > 0 ? transferSeconds * kVibeFakeHTTPPieceBytes / size : 0;
    answer.interval = paced;
    // The fault that cuts this body, should the next piece reach it.
    __block NSMutableDictionary *cut = nil;
    answer.beforePiece = ^(VibeFakeHTTPAnswer *body, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        NSMutableDictionary *stall = VibeFakeDropboxFault(@"stall", name);
        uint64_t stallAt = [stall[@"after"] unsignedLongLongValue];
        body.holdAt = stall ? (stallAt > first ? stallAt - first : 0) : UINT64_MAX;
        BOOL stalled = stall && delivered >= body.holdAt;
        cut = stalled ? nil : (VibeFakeDropboxFault(@"drop", name) ?: VibeFakeDropboxFault(@"rev-change", name));
        uint64_t cutAt = [cut[@"after"] unsignedLongLongValue];
        body.cutAt = cut ? (cutAt > first ? cutAt - first : 0) : UINT64_MAX;
        uint64_t rate = [VibeFakeDropboxFault(@"rate", name)[@"rate"] unsignedLongLongValue];
        body.interval = rate > 0 ? (double)kVibeFakeHTTPPieceBytes / rate : paced;
        os_unfair_lock_unlock(&sLock);
    };
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        if ([outcome isEqualToString:@"dropped"] && cut) {
            [sFaults removeObject:cut];
            if ([cut[@"kind"] isEqualToString:@"rev-change"]) {
                VibeFakeDropboxIssueRev(item);
            }
        }
        VibeFakeDropboxNote(entry, outcome, delivered);
        os_unfair_lock_unlock(&sLock);
    };
}

@end

@implementation VibeFakeDropbox

+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client {
    os_unfair_lock_lock(&sLock);
    // TRAP: an install over a linked fake never links the account again. A
    // link is an account change. It clears a playlist that reaches into the
    // mirror, and it moves the account generation under the transfers in
    // flight. A session swap alone is safe: the old sessions finish their
    // tasks, and the client keys a transfer by its task object.
    BOOL installed = sItems != nil;
    sRevs = [NSMutableDictionary dictionary];
    sItems = VibeFakeDropboxIndex(directory.URLByStandardizingPath);
    sTransferSeconds = transferSeconds;
    sInstallTime = CFAbsoluteTimeGetCurrent();
    sStatistics = [NSMutableDictionary dictionary];
    sDownloadKinds = [NSMutableDictionary dictionary];
    sFaults = [NSMutableArray array];
    sLog = [NSMutableArray array];
    os_unfair_lock_unlock(&sLock);
    if (installed && client.isLinked) {
        return;
    }
    [client useSessionConfiguration:VibeFakeDropboxProtocol.sessionConfiguration];
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
