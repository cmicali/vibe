//
//  HTTPStub.h
//
//  A scripted HTTP server for host-less tests, at the NSURLProtocol boundary.
//  Each HTTPStub owns a host of its own (a UUID under .stub.test), so test
//  classes running in parallel in one process never share state. It reaches a
//  session only through `configuration`'s protocolClasses, never through
//  +[NSURLProtocol registerClass:].
//
//  The serving is the debug channel's fake web server's (VibeFakeHTTP.h).
//  This class scripts its answers. A path serves its bytes by the fake's
//  Range rule: 206 with Content-Range for a range inside the file, 416 for
//  one starting at or past its end, and 200 whole when the file ignores
//  ranges. Steps queued on a path script the next requests to it, one step
//  each, in order.
//

#import <Foundation/Foundation.h>
#include <sys/stat.h>

NS_ASSUME_NONNULL_BEGIN

@interface HTTPStubFile : NSObject
@property (atomic, copy) NSData *data;
// Sent with every answer: ETag, Last-Modified, Content-Type, Content-Encoding.
@property (atomic, copy) NSDictionary<NSString *, NSString *> *headers;
// Answers 200 with the whole file whatever the Range asks.
@property (atomic) BOOL ignoresRanges;
// Sends no Content-Length.
@property (atomic) BOOL omitsLength;
// The body goes out in pieces of this many bytes. 64 KB unless set.
@property (atomic) NSUInteger chunk;
@end

@interface HTTPStubStep : NSObject
// This answer instead of the file.
+ (instancetype)status:(NSInteger)status
               headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                  body:(nullable NSData *)body;
// A 302 to url, which the session follows unless a delegate refuses it.
+ (instancetype)redirectTo:(NSURL *)url;
// The file's answer, ended by NSURLErrorNetworkConnectionLost after `bytes`
// of its body. The failure waits until the task holds those bytes, and until
// `ready` answers YES, if set.
+ (instancetype)dropAfter:(NSUInteger)bytes ready:(nullable BOOL (^)(void))ready;
// The file's answer, held after `bytes` of its body until `gate` is
// signalled, without holding the loader's thread.
+ (instancetype)stallAfter:(NSUInteger)bytes gate:(dispatch_semaphore_t)gate;
// Merges `headers` into the file's for this and every later answer, then
// answers as the file: a new ETag or Last-Modified.
+ (instancetype)changeHeaders:(NSDictionary<NSString *, NSString *> *)headers;
// No answer: the load fails with `error`, as a refused or unreachable
// connection does.
+ (instancetype)failWithError:(NSError *)error;
@end

@interface HTTPStub : NSObject

@property (nonatomic, readonly) NSString *host;
// Ephemeral, with this stub's protocol as its only protocol class.
@property (nonatomic, readonly) NSURLSessionConfiguration *configuration;

- (NSURL *)URLForPath:(NSString *)path;
- (NSURL *)URLForPath:(NSString *)path scheme:(NSString *)scheme;
// This stub also answers `host`, by the same paths, so a test can see that
// nothing was sent to a public address. Per process, until the stub goes.
- (void)answerHost:(NSString *)host;

- (HTTPStubFile *)serveData:(NSData *)data
                     atPath:(NSString *)path
                    headers:(nullable NSDictionary<NSString *, NSString *> *)headers;
- (void)queueStep:(HTTPStubStep *)step forPath:(NSString *)path;

// Every request this host was sent, in arrival order.
@property (nonatomic, readonly) NSArray<NSURLRequest *> *requests;
- (NSArray<NSURLRequest *> *)requestsToPath:(NSString *)path;
// When each request arrived, by CFAbsoluteTimeGetCurrent, in the same order.
@property (nonatomic, readonly) NSArray<NSNumber *> *requestTimes;
// Answers the client stopped before they ended: a cancel mid-body.
@property (nonatomic, readonly) NSUInteger stoppedAnswers;

@end

// Distinct bytes at every offset, so a range answered from the wrong place
// shows.
static inline NSData *PatternBytes(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < count; i++) {
        bytes[i] = (uint8_t)((i * 7 + i / 251) & 0xff);
    }
    return data;
}

// An iCloud Drive lookup's answer for one shared file, in the shape iCloud
// sends, with fake values. The owner's name and address are fake too:
// nothing may read them.
static const long long kICloudModified = 1700000000;

static inline NSMutableDictionary *ICloudLookup(NSString *checksum, long long size, NSString *basename,
                                                NSString *extension, NSString *address) {
    NSDictionary *owner = @{@"nameComponents": @{@"givenName": @"Owner", @"familyName": @"Name"},
                            @"lookupInfo": @{@"emailAddress": @"owner@example.com"}};
    NSDictionary *content = @{@"fileChecksum": checksum, @"size": @(size), @"wrappingKey": @"AAAAAAAAAAAAAAAAAAAAAA==",
                              @"referenceChecksum": @"AQAAAAAAAAAAAAAAAAAAAAAAAAAA", @"downloadURL": address};
    NSMutableDictionary *fields = [@{
        @"lastEditorName": @{@"value": @"{\"name\":{\"last\":\"Name\",\"first\":\"Owner\"}}", @"type": @"STRING"},
        @"extension": @{@"value": extension, @"type": @"STRING"},
        @"size": @{@"value": @(size), @"type": @"NUMBER_INT64"},
        @"encryptedBasename": @{@"value": [[basename dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0],
                                @"type": @"ENCRYPTED_BYTES"},
        @"mtime": @{@"value": @(kICloudModified), @"type": @"NUMBER_INT64"},
        @"fileContent": @{@"value": content, @"type": @"ASSETID"},
    } mutableCopy];
    NSMutableDictionary *record = [@{@"recordName": @"documentContent/00000000-0000-0000-0000-000000000000",
                                     @"recordType": @"content", @"fields": fields} mutableCopy];
    NSMutableDictionary *result = [@{
        @"shortGUID": @{@"value": @"0FakeShareID0000000000000", @"shouldFetchRootRecord": @YES},
        @"containerIdentifier": @"com.apple.clouddocs",
        @"databaseScope": @"SHARED",
        @"share": @{@"recordType": @"cloudkit.share", @"publicPermission": @"READ_ONLY",
                    @"participants": @[@{@"type": @"OWNER", @"userIdentity": owner}]},
        @"rootRecord": record,
        @"ancestorRecords": @[],
        @"ownerIdentity": owner,
        @"anonymousPublicAccess": @{@"token": @"fake", @"tokenTTL": @1200000},
        @"minimallyResolved": @NO,
        @"requireAppleLogin": @NO,
    } mutableCopy];
    return [@{@"results": @[result]} mutableCopy];
}

// The answer's one result, to change a field.
static inline NSMutableDictionary *ICloudResult(NSMutableDictionary *lookup) {
    return lookup[@"results"][0];
}

// A signed address as iCloud's lookup gives it: ${f} for the name, an
// expiry, and a signature, which tells one lookup's address from another's.
static inline NSString *ICloudAddress(NSString *host, NSString *checksum, long long expiry, NSString *signature) {
    return [NSString stringWithFormat:@"https://%@/B/%@/${f}?o=AAAA&v=1&e=%lld&k=key&s=%@", host, checksum,
                                      expiry, signature];
}

static inline struct stat StatOf(NSURL *url) {
    struct stat st = {0};
    lstat(url.fileSystemRepresentation, &st);
    return st;
}

NS_ASSUME_NONNULL_END
