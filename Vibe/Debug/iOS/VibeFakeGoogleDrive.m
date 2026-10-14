//
//  VibeFakeGoogleDrive.m
//  Vibe (iOS)
//

#if DEBUG

#import "VibeFakeGoogleDrive.h"

#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#import <sys/stat.h>

#import "GoogleDriveClient.h"
#import "GoogleDriveRules.h"
#import "NSURL+Hash.h"
#import "OAuthAccountClientInternal.h"
#import "VibeFakeHTTPProtocol.h"

static NSString *const kFakeRootID = @"fakeroot";
static NSString *const kFakePermissionID = @"fakepermission";
static NSString *const kFakeEmail = @"fake@vibe.test";
static const NSUInteger kLogLimit = 200;
static const NSUInteger kSearchLimit = 100;

// One record per fixture entry, keyed by its id.
@interface VibeFakeGoogleDriveItem : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic, copy) NSString *identifier;
// Nil for My Drive itself.
@property (nonatomic, copy, nullable) NSString *parent;
@property (nonatomic) BOOL folder;
// How many version-change faults this file has taken, under sLock.
@property (nonatomic) NSUInteger changes;
@end

@implementation VibeFakeGoogleDriveItem
@end

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, VibeFakeGoogleDriveItem *> *sItems;
static NSTimeInterval sTransferSeconds;
static CFAbsoluteTime sInstallTime;
static NSMutableDictionary<NSString *, NSNumber *> *sRequests;
static NSMutableArray<NSMutableDictionary *> *sFaults;
// Each request's line, updated as it proceeds; under sLock.
static NSMutableArray<NSMutableDictionary *> *sLog;
static NSUInteger sLogSequence;

static NSArray<NSString *> *VibeFakeGoogleDriveFaultKinds(void) {
    return @[@"stall", @"drop", @"version-change", @"throttle", @"expired-token", @"rate", @"latency"];
}

static NSString *VibeFakeGoogleDriveHex(NSString *text, NSUInteger length) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:sizeof digest * 2];
    for (size_t i = 0; i < sizeof digest; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex substringToIndex:MIN(length, hex.length)];
}

// The whole fixture, once: a walk of the tree, each item's id made from its
// path, so a relaunch names the same files the same way.
static NSDictionary<NSString *, VibeFakeGoogleDriveItem *> *VibeFakeGoogleDriveIndex(NSURL *root) {
    NSMutableDictionary<NSString *, VibeFakeGoogleDriveItem *> *items = [NSMutableDictionary dictionary];
    VibeFakeGoogleDriveItem *drive = [[VibeFakeGoogleDriveItem alloc] init];
    drive.url = root;
    drive.identifier = kFakeRootID;
    drive.folder = YES;
    items[kFakeRootID] = drive;
    NSString *rootPath = root.path;
    NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
            enumeratorAtURL:root
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:nil];
    for (NSURL *url in walk) {
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        NSString *relative = [url.URLByStandardizingPath.path substringFromIndex:rootPath.length];
        NSString *parentRelative = relative.stringByDeletingLastPathComponent;
        VibeFakeGoogleDriveItem *item = [[VibeFakeGoogleDriveItem alloc] init];
        item.url = url;
        item.identifier = [@"f" stringByAppendingString:VibeFakeGoogleDriveHex(relative, 24)];
        item.parent = parentRelative.length <= 1 ? kFakeRootID
                : [@"f" stringByAppendingString:VibeFakeGoogleDriveHex(parentRelative, 24)];
        item.folder = isDirectory.boolValue;
        items[item.identifier] = item;
    }
    return items;
}

// A file's version: moves when its size or mtime does, as a re-upload's
// would, and at each version-change fault. Under sLock.
static NSString *VibeFakeGoogleDriveVersion(VibeFakeGoogleDriveItem *item) {
    NSString *stamp = [NSString stringWithFormat:@"%@#%lu", [item.url cacheKey] ?: @"", (unsigned long)item.changes];
    return VibeFakeGoogleDriveHex(stamp, 32);
}

// An item as files.get and files.list answer it.
static NSDictionary *VibeFakeGoogleDriveEntry(VibeFakeGoogleDriveItem *item) {
    BOOL root = [item.identifier isEqualToString:kFakeRootID];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @"kind": @"drive#file",
        @"id": item.identifier,
        @"name": root ? @"My Drive" : item.url.lastPathComponent,
        @"mimeType": item.folder ? VIBE_GOOGLE_DRIVE_FOLDER_TYPE : @"application/octet-stream",
    }];
    if (item.parent) {
        entry[@"parents"] = @[item.parent];
    }
    if (!item.folder) {
        struct stat info;
        BOOL stated = stat(item.url.fileSystemRepresentation, &info) == 0;
        NSDate *modified = stated ? [NSDate dateWithTimeIntervalSince1970:info.st_mtimespec.tv_sec] : NSDate.date;
        entry[@"size"] = [NSString stringWithFormat:@"%lld", stated ? (long long)info.st_size : 0LL];
        entry[@"modifiedTime"] = [NSISO8601DateFormatter stringFromDate:modified
                                                               timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]
                                                          formatOptions:NSISO8601DateFormatWithInternetDateTime
                                                                        | NSISO8601DateFormatWithFractionalSeconds];
        os_unfair_lock_lock(&sLock);
        NSString *version = VibeFakeGoogleDriveVersion(item);
        os_unfair_lock_unlock(&sLock);
        entry[@"md5Checksum"] = version;
        entry[@"headRevisionId"] = [@"rev" stringByAppendingString:version];
    }
    return entry;
}

// The first fault of `kind` for the file of that basename. Under sLock.
static NSMutableDictionary *VibeFakeGoogleDriveFault(NSString *kind, NSString *name) {
    for (NSMutableDictionary *fault in sFaults) {
        NSString *file = fault[@"file"];
        if ([fault[@"kind"] isEqualToString:kind]
                && (!file || (name && [file caseInsensitiveCompare:name] == NSOrderedSame))) {
            return fault;
        }
    }
    return nil;
}

// Under sLock.
static void VibeFakeGoogleDriveNote(NSMutableDictionary *entry, NSString *outcome, uint64_t delivered) {
    NSString *was = entry[@"outcome"];
    if ([outcome isEqualToString:@"cancelled"] && !([was isEqualToString:@"running"] || [was isEqualToString:@"stalled"])) {
        return;
    }
    entry[@"delivered"] = @(delivered);
    entry[@"outcome"] = outcome;
}

// An answer whose body is one JSON object, in one piece.
static VibeFakeHTTPAnswer *VibeFakeGoogleDriveJSON(NSURL *url, NSInteger status, id object,
                                                   NSMutableDictionary *entry) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] ?: [NSData data];
    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    answer.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1"
                                                headerFields:@{@"Content-Type": @"application/json; charset=UTF-8",
                                                               @"Content-Length": @(body.length).stringValue}];
    answer.length = body.length;
    answer.piece = MAX((uint64_t)body.length, (uint64_t)1);
    answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
        return [body subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)count)];
    };
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        VibeFakeGoogleDriveNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
        os_unfair_lock_unlock(&sLock);
    };
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(status);
    os_unfair_lock_unlock(&sLock);
    return answer;
}

static NSDictionary *VibeFakeGoogleDriveError(NSInteger status, NSString *reason, NSString *message) {
    return @{@"error": @{@"code": @(status), @"message": message,
                         @"errors": @[@{@"reason": reason, @"message": message}]}};
}

// The text between the quotes of q's first `'…' <operator>` term, unescaped.
static NSString *VibeFakeGoogleDriveQuoted(NSString *q, NSString *suffix, NSString *prefix) {
    NSString *pattern = [NSString stringWithFormat:@"%@'((?:[^'\\\\]|\\\\.)*)'%@",
                         [NSRegularExpression escapedPatternForString:prefix],
                         [NSRegularExpression escapedPatternForString:suffix]];
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *match = [expression firstMatchInString:q options:0 range:NSMakeRange(0, q.length)];
    if (!match) {
        return nil;
    }
    NSString *quoted = [q substringWithRange:[match rangeAtIndex:1]];
    quoted = [quoted stringByReplacingOccurrencesOfString:@"\\'" withString:@"'"];
    return [quoted stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
}

// Drive matches a name by the prefix of each of its words.
static BOOL VibeFakeGoogleDriveNameMatches(NSString *name, NSString *text) {
    if (text.length == 0) {
        return NO;
    }
    NSCharacterSet *separators = NSCharacterSet.alphanumericCharacterSet.invertedSet;
    for (NSString *word in [name componentsSeparatedByCharactersInSet:separators]) {
        if ([word rangeOfString:text options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            return YES;
        }
    }
    return [name rangeOfString:text options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound;
}

@interface VibeFakeGoogleDriveProtocol : VibeFakeHTTPProtocol
@end

@implementation VibeFakeGoogleDriveProtocol

- (VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path ?: @"";
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        query[item.name] = item.value ?: @"";
    }
    NSString *endpoint = [query[@"alt"] isEqualToString:@"media"] ? @"media" : path;
    os_unfair_lock_lock(&sLock);
    NSDictionary<NSString *, VibeFakeGoogleDriveItem *> *items = sItems;
    sRequests[endpoint] = @(sRequests[endpoint].unsignedIntegerValue + 1);
    NSMutableDictionary *entry = [@{@"seq": @(++sLogSequence),
                                    @"t": @(round((CFAbsoluteTimeGetCurrent() - sInstallTime) * 1000) / 1000),
                                    @"endpoint": endpoint, @"range": [request valueForHTTPHeaderField:@"Range"] ?: NSNull.null,
                                    @"status": @0, @"delivered": @0, @"outcome": @"running"} mutableCopy];
    [sLog addObject:entry];
    if (sLog.count > kLogLimit) {
        [sLog removeObjectAtIndex:0];
    }
    os_unfair_lock_unlock(&sLock);
    if (!items) {
        return nil;
    }

    if ([host isEqualToString:@"oauth2.googleapis.com"]) {
        if ([path isEqualToString:@"/token"]) {
            return VibeFakeGoogleDriveJSON(url, 200, @{@"access_token": @"fake-access", @"expires_in": @3599,
                                                       @"token_type": @"Bearer"}, entry);
        }
        if ([path isEqualToString:@"/revoke"]) {
            return VibeFakeGoogleDriveJSON(url, 200, @{}, entry);
        }
        return nil;
    }
    if (![host isEqualToString:@"www.googleapis.com"] || ![path hasPrefix:@"/drive/v3/"]) {
        return nil;
    }
    NSString *resource = [path substringFromIndex:@"/drive/v3/".length];
    if ([resource isEqualToString:@"about"]) {
        return VibeFakeGoogleDriveJSON(url, 200, @{@"user": @{@"permissionId": kFakePermissionID,
                                                              @"emailAddress": kFakeEmail,
                                                              @"displayName": @"Fake Drive"}}, entry);
    }
    if ([resource isEqualToString:@"files"]) {
        return VibeFakeGoogleDriveJSON(url, 200, [self listingForQuery:query[@"q"] ?: @"" items:items], entry);
    }
    if ([resource hasPrefix:@"files/"]) {
        NSString *identifier = [resource substringFromIndex:@"files/".length];
        VibeFakeGoogleDriveItem *item = items[[identifier isEqualToString:@"root"] ? kFakeRootID : identifier];
        if (!item) {
            return VibeFakeGoogleDriveJSON(url, 404, VibeFakeGoogleDriveError(404, @"notFound",
                    [NSString stringWithFormat:@"File not found: %@.", identifier]), entry);
        }
        os_unfair_lock_lock(&sLock);
        entry[@"file"] = item.url.lastPathComponent;
        os_unfair_lock_unlock(&sLock);
        if ([query[@"alt"] isEqualToString:@"media"]) {
            return [self mediaOfItem:item request:request entry:entry];
        }
        return VibeFakeGoogleDriveJSON(url, 200, VibeFakeGoogleDriveEntry(item), entry);
    }
    return VibeFakeGoogleDriveJSON(url, 400, VibeFakeGoogleDriveError(400, @"badRequest", @"unexpected request"), entry);
}

// files.list: a folder's children for "'<id>' in parents", or a search for
// "name contains '<text>'". One page, with no token.
- (NSDictionary *)listingForQuery:(NSString *)q items:(NSDictionary<NSString *, VibeFakeGoogleDriveItem *> *)items {
    NSString *parent = VibeFakeGoogleDriveQuoted(q, @" in parents", @"");
    NSString *text = parent ? nil : VibeFakeGoogleDriveQuoted(q, @"", @"name contains ");
    if ([parent isEqualToString:@"root"]) {
        parent = kFakeRootID;
    }
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *identifier in [items.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        VibeFakeGoogleDriveItem *item = items[identifier];
        BOOL wanted = parent ? [item.parent isEqualToString:parent]
                             : (item.parent && VibeFakeGoogleDriveNameMatches(item.url.lastPathComponent, text));
        if (wanted) {
            [files addObject:VibeFakeGoogleDriveEntry(item)];
        }
        if (!parent && files.count >= kSearchLimit) {
            break;
        }
    }
    return @{@"kind": @"drive#fileList", @"incompleteSearch": @NO, @"files": files};
}

// files.get?alt=media by the Range rule. An open range (none, or
// `bytes=N-`) is paced and takes the delivery faults. A closed one answers
// at once.
- (VibeFakeHTTPAnswer *)mediaOfItem:(VibeFakeGoogleDriveItem *)item
                            request:(NSURLRequest *)request
                              entry:(NSMutableDictionary *)entry {
    NSURL *url = request.URL;
    NSString *name = item.url.lastPathComponent;
    NSString *range = [request valueForHTTPHeaderField:@"Range"];
    if (item.folder) {
        return VibeFakeGoogleDriveJSON(url, 403, VibeFakeGoogleDriveError(403, @"fileNotDownloadable",
                                                                          @"Only files with binary content can be downloaded."), entry);
    }
    BOOL open = !range || [range hasSuffix:@"-"];
    os_unfair_lock_lock(&sLock);
    NSMutableDictionary *refusal = open ? (VibeFakeGoogleDriveFault(@"throttle", name)
                                           ?: VibeFakeGoogleDriveFault(@"expired-token", name)) : nil;
    if (refusal) {
        [sFaults removeObjectIdenticalTo:refusal];
    }
    NSTimeInterval latency = [VibeFakeGoogleDriveFault(@"latency", name)[@"seconds"] doubleValue];
    NSTimeInterval transferSeconds = sTransferSeconds;
    os_unfair_lock_unlock(&sLock);
    if ([refusal[@"kind"] isEqualToString:@"throttle"]) {
        return VibeFakeGoogleDriveJSON(url, 403, VibeFakeGoogleDriveError(403, @"rateLimitExceeded", @"Rate Limit Exceeded"),
                                       entry);
    }
    if (refusal) {
        return VibeFakeGoogleDriveJSON(url, 401, VibeFakeGoogleDriveError(401, @"authError", @"Invalid Credentials"),
                                       entry);
    }
    struct stat info;
    NSFileHandle *file = stat(item.url.fileSystemRepresentation, &info) == 0
            ? [NSFileHandle fileHandleForReadingFromURL:item.url error:NULL] : nil;
    if (!file) {
        return VibeFakeGoogleDriveJSON(url, 404, VibeFakeGoogleDriveError(404, @"notFound", @"File not found."), entry);
    }
    uint64_t size = (uint64_t)info.st_size;
    NSMutableDictionary<NSString *, NSString *> *headers = [@{@"Content-Type": @"application/octet-stream"} mutableCopy];
    uint64_t first = 0, length = 0;
    NSInteger status = VibeFakeHTTPRangeStatus(range, size, headers, &first, &length);
    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    answer.latency = latency;
    answer.response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1"
                                                headerFields:headers];
    answer.length = length;
    answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
        return [file seekToOffset:first + offset error:NULL] ? [file readDataUpToLength:(NSUInteger)count error:NULL]
                                                             : nil;
    };
    os_unfair_lock_lock(&sLock);
    entry[@"status"] = @(status);
    entry[@"size"] = @(size);
    os_unfair_lock_unlock(&sLock);
    BOOL paced = status == 200 || (status == 206 && open);
    if (!paced) {
        answer.piece = MAX(length, (uint64_t)1);
        answer.progress = ^(NSString *outcome, uint64_t delivered) {
            os_unfair_lock_lock(&sLock);
            VibeFakeGoogleDriveNote(entry, [outcome isEqualToString:@"complete"] ? @"answered" : outcome, delivered);
            os_unfair_lock_unlock(&sLock);
        };
        return answer;
    }
    answer.interval = transferSeconds > 0 && size > 0 ? transferSeconds * kVibeFakeHTTPPieceBytes / size : 0;
    NSTimeInterval paceInterval = answer.interval;
    // The fault that cuts this body, should the next piece reach it.
    __block NSMutableDictionary *cut = nil;
    answer.beforePiece = ^(VibeFakeHTTPAnswer *body, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        NSMutableDictionary *stall = VibeFakeGoogleDriveFault(@"stall", name);
        uint64_t stallAt = [stall[@"after"] unsignedLongLongValue];
        body.holdAt = stall ? (stallAt > first ? stallAt - first : 0) : UINT64_MAX;
        BOOL stalled = stall && delivered >= body.holdAt;
        cut = stalled ? nil : (VibeFakeGoogleDriveFault(@"drop", name) ?: VibeFakeGoogleDriveFault(@"version-change", name));
        uint64_t cutAt = [cut[@"after"] unsignedLongLongValue];
        body.cutAt = cut ? (cutAt > first ? cutAt - first : 0) : UINT64_MAX;
        NSMutableDictionary *rate = VibeFakeGoogleDriveFault(@"rate", name);
        body.interval = rate ? (double)kVibeFakeHTTPPieceBytes / [rate[@"rate"] unsignedLongLongValue] : paceInterval;
        os_unfair_lock_unlock(&sLock);
    };
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        os_unfair_lock_lock(&sLock);
        if ([outcome isEqualToString:@"dropped"] && cut) {
            if ([cut[@"kind"] isEqualToString:@"version-change"]) {
                item.changes++;
            }
            [sFaults removeObjectIdenticalTo:cut];
        }
        VibeFakeGoogleDriveNote(entry, outcome, delivered);
        os_unfair_lock_unlock(&sLock);
    };
    return answer;
}

@end

@implementation VibeFakeGoogleDrive

+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(GoogleDriveClient *)client {
    NSDictionary<NSString *, VibeFakeGoogleDriveItem *> *items = VibeFakeGoogleDriveIndex(directory.URLByStandardizingPath);
    os_unfair_lock_lock(&sLock);
    // TRAP: never rebuild the sessions under transfers in flight. The client
    // keys a download by its task's identifier, which counts from 1 in every
    // session, so a new session's download takes an old one's entry and the
    // old one's callbacks land on it.
    BOOL installed = sItems != nil;
    sItems = items;
    sTransferSeconds = transferSeconds;
    sInstallTime = CFAbsoluteTimeGetCurrent();
    sRequests = [NSMutableDictionary dictionary];
    sFaults = [NSMutableArray array];
    sLog = [NSMutableArray array];
    os_unfair_lock_unlock(&sLock);
    if (installed && client.isLinked) {
        return;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.protocolClasses = @[VibeFakeGoogleDriveProtocol.class];
    [client useSessionConfiguration:configuration];
    [client adoptRefreshToken:@"fake-refresh" accountID:kFakePermissionID];
}

+ (void)uninstallFromClient:(GoogleDriveClient *)client {
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
    if (![VibeFakeGoogleDriveFaultKinds() containsObject:kind]) {
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

+ (NSDictionary *)statistics {
    os_unfair_lock_lock(&sLock);
    NSMutableArray *log = [NSMutableArray arrayWithCapacity:sLog.count];
    for (NSDictionary *entry in sLog) {
        [log addObject:[entry copy]];
    }
    NSMutableArray *faults = [NSMutableArray arrayWithCapacity:sFaults.count];
    for (NSDictionary *fault in sFaults) {
        [faults addObject:[fault copy]];
    }
    NSDictionary *statistics = @{@"requests": [sRequests copy] ?: @{}, @"faults": faults, @"log": log};
    os_unfair_lock_unlock(&sLock);
    return statistics;
}

@end

#endif
