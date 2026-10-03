//
//  VibeFakeDropbox.m
//  Vibe (iOS)
//

#if DEBUG

#import "VibeFakeDropbox.h"

#import <os/lock.h>

#import "DropboxClientInternal.h"
#import "DropboxRules.h"

static NSString *const kFakeAccountID = @"dbid:fake";
static NSString *const kFakeAccountName = @"Fake Dropbox";
static const NSUInteger kSearchLimit = 50;
static const NSUInteger kTransferPieces = 8;

// One record per fixture entry: where it is, and its Dropbox path with the
// disk's case. Keyed by lowercase Dropbox path, which is also the id.
@interface VibeFakeDropboxItem : NSObject
@property (nonatomic) NSURL *url;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL folder;
@end

@implementation VibeFakeDropboxItem
@end

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, VibeFakeDropboxItem *> *sItems;
static NSTimeInterval sTransferSeconds;
static NSMutableDictionary<NSString *, NSNumber *> *sStatistics;
// Pieces of a download are delivered here, never on CFNetwork's protocol
// thread: a sleep there would queue every other request behind it and hold
// a cancel until the whole file had gone out.
static dispatch_queue_t sDeliveryQueue;

// The whole fixture, once: a walk of the tree keyed by lowercase path.
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
        items[item.path.lowercaseString] = item;
    }
    return items;
}

// An item as a list_folder entry: the shape the mirror reads.
static NSDictionary *VibeFakeDropboxEntry(VibeFakeDropboxItem *item) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @".tag": item.folder ? @"folder" : @"file",
        @"name": item.url.lastPathComponent,
        @"path_display": item.path,
        @"path_lower": item.path.lowercaseString,
        @"id": [@"id:" stringByAppendingString:item.path.lowercaseString],
    }];
    if (!item.folder) {
        NSNumber *size = nil;
        NSDate *modified = nil;
        [item.url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        [item.url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
        entry[@"size"] = size ?: @0;
        // Dropbox's form, UTC to the second: what VibeDropboxParseTimestamp reads.
        entry[@"server_modified"] = [NSISO8601DateFormatter stringFromDate:modified ?: NSDate.date
                                                                  timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0]
                                                             formatOptions:NSISO8601DateFormatWithInternetDateTime];
        entry[@"client_modified"] = entry[@"server_modified"];
        entry[@"rev"] = @"r1";
    }
    return entry;
}

static VibeFakeDropboxItem *VibeFakeDropboxLookup(NSDictionary<NSString *, VibeFakeDropboxItem *> *items,
                                                  NSString *pathOrID) {
    NSString *path = [pathOrID hasPrefix:@"id:"] ? [pathOrID substringFromIndex:3] : pathOrID;
    return items[path.lowercaseString];
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

@interface VibeFakeDropboxProtocol : NSURLProtocol
@property (atomic) BOOL cancelled;
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
    NSTimeInterval transferSeconds = sTransferSeconds;
    sStatistics[endpoint] = @(sStatistics[endpoint].unsignedIntegerValue + 1);
    os_unfair_lock_unlock(&sLock);

    NSData *body = VibeFakeDropboxBody(request);
    NSDictionary *json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        json = nil;
    }
    if ([endpoint isEqualToString:@"/2/files/download"]) {
        [self serveDownloadFrom:items transferSeconds:transferSeconds];
        return;
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
                [entries addObject:VibeFakeDropboxEntry(items[key])];
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
                                 @"metadata": @{@".tag": @"metadata", @"metadata": VibeFakeDropboxEntry(item)}}];
        }
        return VibeFakeDropboxJSON(200, @{@"matches": matches, @"has_more": @NO});
    }
    return VibeFakeDropboxJSON(400, @{@"error_summary": [@"unexpected endpoint " stringByAppendingString:endpoint]});
}

// files/download: the path or id from the Dropbox-API-Arg header. A Range is
// read from the file and answered at once; a whole file goes out in pieces
// over transferSeconds, off this thread, each piece read as it is sent.
- (void)serveDownloadFrom:(NSDictionary<NSString *, VibeFakeDropboxItem *> *)items
          transferSeconds:(NSTimeInterval)transferSeconds {
    NSString *argument = [self.request valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    NSDictionary *arg = argument
            ? [NSJSONSerialization JSONObjectWithData:[argument dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL]
            : nil;
    VibeFakeDropboxItem *item = VibeFakeDropboxLookup(items, [arg[@"path"] isKindOfClass:NSString.class] ? arg[@"path"] : @"");
    NSFileHandle *file = item && !item.folder ? [NSFileHandle fileHandleForReadingFromURL:item.url error:NULL] : nil;
    if (!file) {
        [self finishWith:VibeFakeDropboxNotFound()];
        return;
    }
    NSDictionary *metadata = VibeFakeDropboxEntry(item);
    unsigned long long length = [metadata[@"size"] unsignedLongLongValue];
    NSString *range = [self.request valueForHTTPHeaderField:@"Range"];
    if (range) {
        unsigned long long first = 0, last = 0;
        sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
        last = MIN(last, length - 1);
        NSData *slice = [NSData data];
        if (first <= last && [file seekToOffset:first error:NULL]) {
            slice = [file readDataUpToLength:(NSUInteger)(last - first + 1) error:NULL] ?: slice;
        }
        [self finishWith:(VibeFakeDropboxResponse){206, @{}, slice}];
        return;
    }
    NSString *result = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata
                                                                                      options:0 error:NULL]
                                             encoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Dropbox-API-Result": result,
                                                                           @"Content-Length": @(length).stringValue}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSUInteger piece = (NSUInteger)MAX(1ULL, length / kTransferPieces);
    [self deliverPieceOf:file size:piece every:transferSeconds / kTransferPieces];
}

// One piece per step, so the size on disk — the progress the loading bar
// reads — grows as a real transfer's does, and a cancel lands between pieces.
- (void)deliverPieceOf:(NSFileHandle *)file size:(NSUInteger)piece every:(NSTimeInterval)interval {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), sDeliveryQueue, ^{
        if (self.cancelled) {
            return;
        }
        NSData *bytes = [file readDataUpToLength:piece error:NULL];
        if (bytes.length == 0) {
            [self.client URLProtocolDidFinishLoading:self];
            return;
        }
        [self.client URLProtocol:self didLoadData:bytes];
        [self deliverPieceOf:file size:piece every:interval];
    });
}

- (void)finishWith:(VibeFakeDropboxResponse)answer {
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

- (void)stopLoading {
    self.cancelled = YES;
}

@end

@implementation VibeFakeDropbox

+ (void)installWithDirectory:(NSURL *)directory
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client {
    NSDictionary *items = VibeFakeDropboxIndex(directory.URLByStandardizingPath);
    os_unfair_lock_lock(&sLock);
    sItems = items;
    sTransferSeconds = transferSeconds;
    sStatistics = [NSMutableDictionary dictionary];
    if (!sDeliveryQueue) {
        sDeliveryQueue = dispatch_queue_create("com.commonwealthrecordings.Vibe.fake-dropbox", DISPATCH_QUEUE_SERIAL);
    }
    os_unfair_lock_unlock(&sLock);
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
    os_unfair_lock_unlock(&sLock);
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sItems != nil;
    os_unfair_lock_unlock(&sLock);
    return installed;
}

+ (NSDictionary<NSString *, NSNumber *> *)statistics {
    os_unfair_lock_lock(&sLock);
    NSDictionary *statistics = [sStatistics copy] ?: @{};
    os_unfair_lock_unlock(&sLock);
    return statistics;
}

@end

#endif
