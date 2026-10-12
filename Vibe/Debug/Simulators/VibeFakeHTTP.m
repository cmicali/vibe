//
//  VibeFakeHTTP.m
//  Vibe
//

#if DEBUG

#import "VibeFakeHTTP.h"
#import "VibeFakeHTTPProtocol.h"

#import <os/lock.h>
#import <sys/stat.h>

#import "HTTPTransferClientInternal.h"
#import "ICloudLinkRules.h"

static const NSUInteger kLogLimit = 200;

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

// The host of iCloud's signed addresses. The lookup's is the client's own
// (kVibeICloudLinkLookupURL).
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

static BOOL VibeFakeHTTPIsLookupHost(NSString *host) {
    return [host.lowercaseString isEqualToString:[NSURL URLWithString:kVibeICloudLinkLookupURL].host];
}

static BOOL VibeFakeHTTPServesHost(NSString *host) {
    NSString *name = host.lowercaseString;
    return [name isEqualToString:@"fake.vibe.test"] || [name isEqualToString:@"fake.local"]
        || VibeFakeHTTPIsLookupHost(name) || [name isEqualToString:kVibeFakeHTTPSignedHost];
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

// The share a lookup's body names.
static NSString *VibeFakeHTTPShortGUIDOfLookup(NSURLRequest *request) {
    NSData *body = VibeFakeHTTPBodyOfRequest(request);
    id answer = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    id shares = [answer isKindOfClass:NSDictionary.class] ? answer[@"shortGUIDs"] : nil;
    id share = [shares isKindOfClass:NSArray.class] ? [shares firstObject] : nil;
    id value = [share isKindOfClass:NSDictionary.class] ? share[@"value"] : nil;
    return [value isKindOfClass:NSString.class] ? value : @"";
}

// A lookup's answer in the shape iCloud sends, with no owner. The share is
// the root's entry named shortGUID without its extension: a file, a
// folder, or no share. The address lives 15 minutes, or an expiry fault's
// seconds. The checksum is the file's version, which etag-change moves.
// Under sLock.
static NSData *VibeFakeHTTPLookup(NSString *root, NSString *shortGUID, NSMutableDictionary *line) {
    NSString *entry = nil;
    for (NSString *candidate in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL]) {
        if (shortGUID.length > 0 && [candidate.stringByDeletingPathExtension isEqualToString:shortGUID]) {
            entry = candidate;
            break;
        }
    }
    struct stat info;
    BOOL exists = entry && stat([root stringByAppendingPathComponent:entry].fileSystemRepresentation, &info) == 0;
    NSMutableDictionary *result = [@{@"shortGUID": @{@"value": shortGUID}, @"requireAppleLogin": @NO,
                                     @"minimallyResolved": @NO} mutableCopy];
    if (!exists) {
        result[@"reason"] = @"Cannot resolve shortGUID";
        result[@"serverErrorCode"] = @"NOT_FOUND";
    }
    else if (S_ISDIR(info.st_mode)) {
        result[@"anonymousPublicAccess"] = @{@"token": @"fake", @"tokenTTL": @1200000};
        result[@"rootRecord"] = @{@"recordType": @"folder", @"fields": @{}};
    }
    else {
        NSMutableDictionary *expiry = VibeFakeHTTPFault(@"expiry", entry);
        if (expiry) {
            VibeFakeHTTPApply(expiry, line);
        }
        NSTimeInterval lifetime = expiry ? [expiry[@"seconds"] doubleValue] : kVibeFakeHTTPAddressLifetime;
        VibeFakeHTTPVersion version = VibeFakeHTTPVersionOf([@"/" stringByAppendingString:entry], &info);
        NSString *checksum = [version.etag stringByTrimmingCharactersInSet:
                              [NSCharacterSet characterSetWithCharactersInString:@"\""]];
        NSString *address = [NSString stringWithFormat:@"https://%@/B/%@/${f}?p=%@&e=%lld&s=fake",
                             kVibeFakeHTTPSignedHost, checksum, VibeICloudLinkEncodedName(entry),
                             (long long)(NSDate.date.timeIntervalSince1970 + lifetime)];
        NSString *basename = [[entry.stringByDeletingPathExtension dataUsingEncoding:NSUTF8StringEncoding]
                              base64EncodedStringWithOptions:0];
        result[@"anonymousPublicAccess"] = @{@"token": @"fake", @"tokenTTL": @1200000};
        result[@"rootRecord"] = @{@"recordType": @"content", @"fields": @{
            @"extension": @{@"value": entry.pathExtension, @"type": @"STRING"},
            @"size": @{@"value": @(version.size), @"type": @"NUMBER_INT64"},
            @"encryptedBasename": @{@"value": basename, @"type": @"ENCRYPTED_BYTES"},
            @"mtime": @{@"value": @(version.modified), @"type": @"NUMBER_INT64"},
            @"fileContent": @{@"value": @{@"fileChecksum": checksum, @"size": @(version.size),
                                          @"downloadURL": address},
                              @"type": @"ASSETID"},
        }};
    }
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

#pragma mark The directory

// One request on its way to an answer. The address and lookup steps fill in
// what it names, and the fault step what the faults make of it. The range and pace
// steps read it. A block copies what it keeps out of it, never the struct.
typedef struct {
    NSURL *url;
    NSString *range;
    BOOL lookup;
    BOOL signedAddress;
    NSString *shortGUID;
    NSString *servedPath;
    BOOL expired;
    // The request's line in the log.
    NSMutableDictionary *entry;
    NSString *root;
    NSString *path;
    NSString *relativePath;
    NSString *name;
    BOOL found;
    VibeFakeHTTPVersion version;
    // The status, headers, and body that answer in place of the file. 0 for
    // the file's own.
    NSInteger refusal;
    NSDictionary<NSString *, NSString *> *refusalHeaders;
    NSData *refusalBody;
    // A shape a server with no ranges, no length, or a compressor answers in.
    NSString *shape;
} VibeFakeHTTPExchange;

@implementation VibeFakeHTTPProtocol (Directory)

- (VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request {
    VibeFakeHTTPExchange exchange = {.url = request.URL, .range = [request valueForHTTPHeaderField:@"Range"]};
    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    [self readAddress:request into:&exchange];

    os_unfair_lock_lock(&sLock);
    if (![self lookUp:&exchange]) {
        os_unfair_lock_unlock(&sLock);
        return nil;
    }
    [self applyFaultsTo:&exchange answer:answer];
    NSTimeInterval transferSeconds = sTransferSeconds;
    exchange.entry[@"size"] = @(exchange.version.size);
    exchange.entry[@"etag"] = exchange.version.etag ?: NSNull.null;
    os_unfair_lock_unlock(&sLock);

    uint64_t first = 0;
    BOOL paced = [self answerRangeOf:&exchange answer:answer first:&first];
    [self paceAnswer:answer of:&exchange paced:paced first:first transferSeconds:transferSeconds];
    return answer;
}

// The address step, before the lock: what the request names. A lookup answers
// for the entry its share names. A signed address serves the entry in its p
// item until its e item has passed.
- (void)readAddress:(NSURLRequest *)request into:(VibeFakeHTTPExchange *)exchange {
    NSURL *url = exchange->url;
    BOOL lookup = VibeFakeHTTPIsLookupHost(url.host);
    BOOL signedAddress = [url.host.lowercaseString isEqualToString:kVibeFakeHTTPSignedHost];
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
    exchange->lookup = lookup;
    exchange->signedAddress = signedAddress;
    exchange->shortGUID = shortGUID;
    exchange->servedPath = servedPath;
    exchange->expired = expired;
}

// The lookup step, under sLock: the request's line in the log, and the file
// it names under the root. NO with no root, or for a host the fake does not
// serve.
- (BOOL)lookUp:(VibeFakeHTTPExchange *)exchange {
    NSURL *url = exchange->url;
    NSString *range = exchange->range;
    sRequests++;
    NSMutableDictionary *entry = [@{@"seq": @(++sLogSequence), @"t": @(VibeFakeHTTPNow()),
                                    @"host": url.host ?: @"", @"path": url.path ?: @"",
                                    @"range": range ?: NSNull.null, @"status": @0, @"delivered": @0,
                                    @"faults": [NSMutableArray array], @"outcome": @"running"} mutableCopy];
    [sLog addObject:entry];
    if (sLog.count > kLogLimit) {
        [sLog removeObjectAtIndex:0];
    }
    exchange->entry = entry;
    NSString *root = sRootPath;
    if (!root || !VibeFakeHTTPServesHost(url.host)) {
        entry[@"outcome"] = @"unknown-host";
        entry[@"finished"] = @(VibeFakeHTTPNow());
        return NO;
    }
    NSString *path = [root stringByAppendingPathComponent:exchange->servedPath].stringByStandardizingPath;
    NSString *relativePath = [path hasPrefix:[root stringByAppendingString:@"/"]]
            ? [path substringFromIndex:root.length] : nil;
    NSString *name = path.lastPathComponent;
    struct stat info;
    BOOL found = !exchange->lookup && relativePath && stat(path.fileSystemRepresentation, &info) == 0
        && S_ISREG(info.st_mode);
    VibeFakeHTTPVersion version = found ? VibeFakeHTTPVersionOf(relativePath, &info) : (VibeFakeHTTPVersion){0};
    exchange->root = root;
    exchange->path = path;
    exchange->relativePath = relativePath;
    exchange->name = name;
    exchange->found = found;
    exchange->version = version;
    return YES;
}

// The fault step, under sLock: the latency, the answer a lookup, a fault, or
// a missing file puts in place of the file's, and the shape the faults give
// the file's own.
- (void)applyFaultsTo:(VibeFakeHTTPExchange *)exchange answer:(VibeFakeHTTPAnswer *)answer {
    NSString *name = exchange->name;
    NSMutableDictionary *entry = exchange->entry;
    NSMutableDictionary *fault = VibeFakeHTTPFault(@"latency", name);
    if (fault) {
        answer.latency = [fault[@"seconds"] doubleValue];
        VibeFakeHTTPApply(fault, entry);
    }
    NSInteger refusal = 0;
    NSDictionary<NSString *, NSString *> *refusalHeaders = @{@"Content-Type": @"text/plain"};
    NSData *refusalBody = nil;
    if (exchange->lookup) {
        refusal = 200;
        refusalHeaders = @{@"Content-Type": @"application/json; charset=UTF-8"};
        refusalBody = VibeFakeHTTPLookup(exchange->root, exchange->shortGUID, entry);
    }
    else if ((fault = VibeFakeHTTPFault(@"status", name))) {
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
    else if (!exchange->found) {
        refusal = 404;
        refusalBody = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
    }
    else if (exchange->expired) {
        refusal = 410;
        refusalBody = [@"Gone" dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSString *shape = nil;
    for (NSString *kind in @[@"icy", @"no-length", @"gzip", @"no-range"]) {
        if (!refusal && (fault = VibeFakeHTTPFault(kind, name))) {
            shape = kind;
            VibeFakeHTTPApply(fault, entry);
            break;
        }
    }
    exchange->refusal = refusal;
    exchange->refusalHeaders = refusalHeaders;
    exchange->refusalBody = refusalBody;
    exchange->shape = shape;
}

// The range step: the status, the headers, and the body's bytes. A refusal
// answers whole. The file answers by the Range rule, in the shape the faults
// gave it. Returns whether the body is paced, and the file offset it starts
// at.
- (BOOL)answerRangeOf:(VibeFakeHTTPExchange *)exchange answer:(VibeFakeHTTPAnswer *)answer first:(uint64_t *)firstOut {
    NSURL *url = exchange->url;
    NSString *range = exchange->range;
    NSString *path = exchange->path;
    NSString *name = exchange->name;
    NSString *shape = exchange->shape;
    NSMutableDictionary *entry = exchange->entry;
    VibeFakeHTTPVersion version = exchange->version;
    NSInteger refusal = exchange->refusal;
    NSData *refusalBody = exchange->refusalBody;
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
        headers = [exchange->refusalHeaders mutableCopy];
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
        if (exchange->signedAddress) {
            [headers removeObjectForKey:@"ETag"];
            headers[@"Last-Modified"] = VibeFakeHTTPDate((time_t)NSDate.date.timeIntervalSince1970);
            headers[@"Content-Disposition"] = VibeICloudLinkContentDisposition(url.lastPathComponent);
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
    *firstOut = first;
    return paced;
}

// The pace step: how the body goes out, and how its line in the log follows
// it. A paced body takes about transferSeconds, and its faults may hold,
// throttle, or cut it. Any other goes out in one piece.
- (void)paceAnswer:(VibeFakeHTTPAnswer *)answer of:(VibeFakeHTTPExchange *)exchange paced:(BOOL)paced
             first:(uint64_t)first transferSeconds:(NSTimeInterval)transferSeconds {
    NSString *name = exchange->name;
    NSString *relativePath = exchange->relativePath;
    NSMutableDictionary *entry = exchange->entry;
    uint64_t size = exchange->version.size;
    uint64_t length = answer.length;
    if (!paced) {
        answer.piece = MAX(length, (uint64_t)1);
    }
    else {
        answer.interval = transferSeconds > 0 && size > 0 ? transferSeconds * kVibeFakeHTTPPieceBytes / size : 0;
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
            body.interval = rate ? (double)kVibeFakeHTTPPieceBytes / [rate[@"rate"] unsignedLongLongValue]
                                 : paceInterval;
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
        return;
    }
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        VibeFakeHTTPNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
        os_unfair_lock_unlock(&sLock);
    };
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
