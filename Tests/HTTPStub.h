//
//  HTTPStub.h
//
//  A scripted HTTP server for host-less tests, at the NSURLProtocol boundary.
//  Each HTTPStub owns a host of its own (a UUID under .stub.test), so test
//  classes running in parallel in one process never share state. It reaches a
//  session only through `configuration`'s protocolClasses, never through
//  +[NSURLProtocol registerClass:].
//
//  A path serves its bytes with Range support: 206 with Content-Range for a
//  range inside the file, 416 for one starting at or past its end, and 200
//  whole when the file ignores ranges. Steps queued on a path script the next
//  requests to it, one step each, in order.
//

#import <Foundation/Foundation.h>

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
// of its body. The failure waits until `ready` answers YES, if set: a failure
// sent straight after the bytes overtakes them on the client's side.
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

@end

NS_ASSUME_NONNULL_END
