//
//  VibeFakeDropbox.m
//  Vibe (iOS)
//

#import <TargetConditionals.h>

#if DEBUG && !TARGET_OS_OSX

#import "VibeFakeDropbox.h"

#import <os/lock.h>

#import "DropboxClientInternal.h"

static NSString *const kFakeAccountID = @"dbid:fake";
static const NSUInteger kSearchLimit = 50;
static const NSUInteger kTransferPieces = 8;

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static NSURL *sDirectory;
static NSString *sAccountName;
static NSTimeInterval sTransferSeconds;
static NSMutableDictionary<NSString *, NSNumber *> *sStatistics;

// The Dropbox form of a timestamp: UTC to the second.
static NSString *VibeFakeDropboxTimestamp(NSDate *date) {
    time_t seconds = (time_t)date.timeIntervalSince1970;
    struct tm parts;
    gmtime_r(&seconds, &parts);
    char buffer[32];
    strftime(buffer, sizeof buffer, "%Y-%m-%dT%H:%M:%SZ", &parts);
    return @(buffer);
}

// A fixture file or folder as a list_folder entry. The id is the path, so a
// download by id needs no table.
static NSDictionary *VibeFakeDropboxEntry(NSURL *url, NSString *dropboxPath) {
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @".tag": isDirectory.boolValue ? @"folder" : @"file",
        @"name": url.lastPathComponent,
        @"path_display": dropboxPath,
        @"path_lower": dropboxPath.lowercaseString,
        @"id": [@"id:" stringByAppendingString:dropboxPath.lowercaseString],
    }];
    if (!isDirectory.boolValue) {
        NSNumber *size = nil;
        NSDate *modified = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
        entry[@"size"] = size ?: @0;
        entry[@"server_modified"] = VibeFakeDropboxTimestamp(modified ?: NSDate.date);
        entry[@"client_modified"] = entry[@"server_modified"];
        entry[@"rev"] = @"r1";
    }
    return entry;
}

// The fixture file or folder at a Dropbox path, matched per component
// without regard to case, as Dropbox matches.
static NSURL *VibeFakeDropboxURLForPath(NSURL *root, NSString *dropboxPath, NSString **displayPath) {
    NSURL *url = root;
    NSMutableString *display = [NSMutableString string];
    for (NSString *component in [dropboxPath componentsSeparatedByString:@"/"]) {
        if (component.length == 0) {
            continue;
        }
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url
                                                                includingPropertiesForKeys:nil
                                                                                   options:0
                                                                                     error:NULL];
        NSURL *match = nil;
        for (NSURL *candidate in contents) {
            if ([candidate.lastPathComponent caseInsensitiveCompare:component] == NSOrderedSame) {
                match = candidate;
                break;
            }
        }
        if (!match) {
            return nil;
        }
        url = match;
        [display appendFormat:@"/%@", match.lastPathComponent];
    }
    if (displayPath) {
        *displayPath = display;
    }
    return url;
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
@end

@implementation VibeFakeDropboxProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.host hasSuffix:@"dropboxapi.com"] || [request.URL.host hasSuffix:@"dropbox.com"];
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
    NSURL *root = sDirectory;
    NSString *accountName = sAccountName;
    NSTimeInterval transferSeconds = sTransferSeconds;
    sStatistics[endpoint] = @(sStatistics[endpoint].unsignedIntegerValue + 1);
    os_unfair_lock_unlock(&sLock);

    NSData *body = VibeFakeDropboxBody(request);
    NSDictionary *json = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        json = nil;
    }

    if ([endpoint isEqualToString:@"/2/files/download"]) {
        [self serveDownloadFrom:root transferSeconds:transferSeconds];
        return;
    }
    [self finishWith:[self respondTo:endpoint json:json root:root accountName:accountName]];
}

- (VibeFakeDropboxResponse)respondTo:(NSString *)endpoint
                                json:(NSDictionary *)json
                                root:(NSURL *)root
                         accountName:(NSString *)accountName {
    if ([endpoint isEqualToString:@"/oauth2/token"]) {
        return VibeFakeDropboxJSON(200, @{@"access_token": @"fake-access", @"expires_in": @14400,
                                          @"token_type": @"bearer"});
    }
    if ([endpoint isEqualToString:@"/2/auth/token/revoke"]) {
        return VibeFakeDropboxJSON(200, @{});
    }
    if ([endpoint isEqualToString:@"/2/users/get_current_account"]) {
        return VibeFakeDropboxJSON(200, @{@"account_id": kFakeAccountID,
                                          @"name": @{@"display_name": accountName ?: @"Fake"}});
    }
    if ([endpoint isEqualToString:@"/2/files/list_folder"]) {
        NSString *path = [json[@"path"] isKindOfClass:NSString.class] ? json[@"path"] : @"";
        NSString *display = @"";
        NSURL *folder = VibeFakeDropboxURLForPath(root, path, &display);
        if (!folder) {
            return VibeFakeDropboxNotFound();
        }
        NSMutableArray *entries = [NSMutableArray array];
        NSArray<NSURL *> *contents = [NSFileManager.defaultManager
                contentsOfDirectoryAtURL:folder
              includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                   error:NULL];
        for (NSURL *url in contents) {
            [entries addObject:VibeFakeDropboxEntry(url, [display stringByAppendingPathComponent:url.lastPathComponent])];
        }
        return VibeFakeDropboxJSON(200, @{@"entries": entries, @"cursor": @"fake", @"has_more": @NO});
    }
    if ([endpoint isEqualToString:@"/2/files/list_folder/continue"]) {
        return VibeFakeDropboxJSON(200, @{@"entries": @[], @"cursor": @"fake", @"has_more": @NO});
    }
    if ([endpoint isEqualToString:@"/2/files/search_v2"]) {
        NSString *query = [json[@"query"] isKindOfClass:NSString.class] ? json[@"query"] : @"";
        NSMutableArray *matches = [NSMutableArray array];
        NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager
                enumeratorAtURL:root
     includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
                        options:NSDirectoryEnumerationSkipsHiddenFiles
                   errorHandler:nil];
        NSUInteger depth = root.URLByStandardizingPath.pathComponents.count;
        for (NSURL *url in walk) {
            if (matches.count >= kSearchLimit) {
                break;
            }
            if (query.length > 0 && [url.lastPathComponent rangeOfString:query
                                                                 options:NSCaseInsensitiveSearch].location == NSNotFound) {
                continue;
            }
            NSArray<NSString *> *components = url.URLByStandardizingPath.pathComponents;
            NSString *path = [@"/" stringByAppendingString:
                    [[components subarrayWithRange:NSMakeRange(depth, components.count - depth)]
                            componentsJoinedByString:@"/"]];
            [matches addObject:@{@"match_type": @{@".tag": @"filename"},
                                 @"metadata": @{@".tag": @"metadata", @"metadata": VibeFakeDropboxEntry(url, path)}}];
        }
        return VibeFakeDropboxJSON(200, @{@"matches": matches, @"has_more": @NO});
    }
    return VibeFakeDropboxJSON(400, @{@"error_summary": [@"unexpected endpoint " stringByAppendingString:endpoint]});
}

// files/download: the path or id from the Dropbox-API-Arg header, a Range
// answered at once, a whole file in pieces over transferSeconds.
- (void)serveDownloadFrom:(NSURL *)root transferSeconds:(NSTimeInterval)transferSeconds {
    NSString *argument = [self.request valueForHTTPHeaderField:@"Dropbox-API-Arg"];
    NSDictionary *arg = argument
            ? [NSJSONSerialization JSONObjectWithData:[argument dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:NULL]
            : nil;
    NSString *requested = [arg[@"path"] isKindOfClass:NSString.class] ? arg[@"path"] : @"";
    if ([requested hasPrefix:@"id:"]) {
        requested = [requested substringFromIndex:3];
    }
    NSString *display = nil;
    NSURL *file = VibeFakeDropboxURLForPath(root, requested, &display);
    NSData *bytes = file ? [NSData dataWithContentsOfURL:file] : nil;
    if (!bytes) {
        [self finishWith:VibeFakeDropboxNotFound()];
        return;
    }
    NSString *range = [self.request valueForHTTPHeaderField:@"Range"];
    if (range) {
        unsigned long long first = 0, last = 0;
        sscanf(range.UTF8String, "bytes=%llu-%llu", &first, &last);
        last = MIN(last, (unsigned long long)bytes.length - 1);
        NSData *slice = first <= last
                ? [bytes subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))]
                : [NSData data];
        [self finishWith:(VibeFakeDropboxResponse){206, @{}, slice}];
        return;
    }
    NSDictionary *metadata = VibeFakeDropboxEntry(file, display);
    NSString *result = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata
                                                                                      options:0 error:NULL]
                                             encoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Dropbox-API-Result": result,
                                                                           @"Content-Length": @(bytes.length).stringValue}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    // In pieces, so the size on disk — the progress the loading bar reads —
    // grows as a real transfer's does.
    NSUInteger piece = MAX(1u, bytes.length / kTransferPieces);
    for (NSUInteger offset = 0; offset < bytes.length; offset += piece) {
        if (transferSeconds > 0) {
            [NSThread sleepForTimeInterval:transferSeconds / kTransferPieces];
        }
        NSUInteger length = MIN(piece, bytes.length - offset);
        [self.client URLProtocol:self didLoadData:[bytes subdataWithRange:NSMakeRange(offset, length)]];
    }
    [self.client URLProtocolDidFinishLoading:self];
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
}

@end

@implementation VibeFakeDropbox

+ (void)installWithDirectory:(NSURL *)directory
                 accountName:(NSString *)accountName
             transferSeconds:(NSTimeInterval)transferSeconds
                      client:(DropboxClient *)client {
    os_unfair_lock_lock(&sLock);
    sDirectory = directory.URLByStandardizingPath;
    sAccountName = [accountName copy];
    sTransferSeconds = transferSeconds;
    sStatistics = [NSMutableDictionary dictionary];
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
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.waitsForConnectivity = NO;
    [client useSessionConfiguration:configuration];
    os_unfair_lock_lock(&sLock);
    sDirectory = nil;
    sAccountName = nil;
    os_unfair_lock_unlock(&sLock);
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sDirectory != nil;
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
