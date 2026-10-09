//
//  HTTPStub.m
//

#import "HTTPStub.h"

#include <os/lock.h>

// From 1, so a nil step's kind is none of them.
typedef NS_ENUM(NSInteger, HTTPStubStepKind) {
    HTTPStubStepKindStatus = 1,
    HTTPStubStepKindRedirect,
    HTTPStubStepKindDrop,
    HTTPStubStepKindStall,
    HTTPStubStepKindChangeHeaders,
    HTTPStubStepKindFail,
};

@implementation HTTPStubFile
@end

@interface HTTPStubStep ()
@property (nonatomic) HTTPStubStepKind kind;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, nullable) NSData *body;
@property (nonatomic, copy, nullable) NSURL *redirect;
@property (nonatomic) NSUInteger bytes;
@property (nonatomic, copy, nullable) BOOL (^ready)(void);
@property (nonatomic, nullable) dispatch_semaphore_t gate;
@property (nonatomic, nullable) NSError *error;
@end

@implementation HTTPStubStep

+ (instancetype)status:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindStatus;
    step.status = status;
    step.headers = headers;
    step.body = body;
    return step;
}

+ (instancetype)redirectTo:(NSURL *)url {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindRedirect;
    step.redirect = url;
    return step;
}

+ (instancetype)dropAfter:(NSUInteger)bytes ready:(BOOL (^)(void))ready {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindDrop;
    step.bytes = bytes;
    step.ready = ready;
    return step;
}

+ (instancetype)stallAfter:(NSUInteger)bytes gate:(dispatch_semaphore_t)gate {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindStall;
    step.bytes = bytes;
    step.gate = gate;
    return step;
}

+ (instancetype)changeHeaders:(NSDictionary *)headers {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindChangeHeaders;
    step.headers = headers;
    return step;
}

+ (instancetype)failWithError:(NSError *)error {
    HTTPStubStep *step = [[self alloc] init];
    step.kind = HTTPStubStepKindFail;
    step.error = error;
    return step;
}

@end

// One answer, decided on the loader's thread and delivered from it.
@interface HTTPStubAnswer : NSObject
@property (nonatomic) NSHTTPURLResponse *response;
@property (nonatomic, nullable) NSData *body;
@property (nonatomic) NSUInteger chunk;
@property (nonatomic, nullable) NSURLRequest *redirect;
@property (nonatomic, nullable) NSError *error;
// Body bytes after which the delivery drops or stalls; NSNotFound for neither.
@property (nonatomic) NSUInteger dropAt;
@property (nonatomic, copy, nullable) BOOL (^ready)(void);
@property (nonatomic) NSUInteger stallAt;
@property (nonatomic, nullable) dispatch_semaphore_t gate;
@end

@implementation HTTPStubAnswer
@end

@interface HTTPStub ()
- (nullable HTTPStubAnswer *)answerRequest:(NSURLRequest *)request;
- (void)noteStoppedAnswer;
@end

#pragma mark - Instances by host

static os_unfair_lock sHostsLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<NSString *, HTTPStub *> *sHosts;

static HTTPStub *_Nullable HTTPStubForHost(NSString *host) {
    os_unfair_lock_lock(&sHostsLock);
    HTTPStub *stub = [sHosts objectForKey:host.lowercaseString];
    os_unfair_lock_unlock(&sHostsLock);
    return stub;
}

#pragma mark - Protocol

@interface HTTPStubProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
// The answer reached the client whole, or failed. The loader's thread.
@property (nonatomic) BOOL ended;
@end

@implementation HTTPStubProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

// The loader thread's run loop may next turn in either mode.
static NSArray<NSString *> *HTTPStubModes(void) {
    NSMutableArray<NSString *> *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode]) {
        [modes addObject:mode];
    }
    return modes;
}

- (void)startLoading {
    HTTPStubAnswer *answer = [HTTPStubForHost(self.request.URL.host) answerRequest:self.request];
    // Only a body in flight can be stopped before it ends.
    self.ended = !answer || answer.error || answer.redirect;
    if (!answer) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorCannotFindHost userInfo:nil]];
        return;
    }
    if (answer.error) {
        [self.client URLProtocol:self didFailWithError:answer.error];
        return;
    }
    if (answer.redirect) {
        // Followed, the session loads the new request through a new instance;
        // refused, it answers the task with this response. Either way this
        // load is over.
        [self.client URLProtocol:self wasRedirectedToRequest:answer.redirect redirectResponse:answer.response];
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorCancelled userInfo:nil]];
        return;
    }
    [self.client URLProtocol:self didReceiveResponse:answer.response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    NSThread *thread = NSThread.currentThread;
    NSArray<NSString *> *modes = HTTPStubModes();
    NSData *body = answer.body ?: [NSData data];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger end = MIN(body.length, answer.dropAt);
        BOOL held = NO;
        for (NSUInteger start = 0; !self.stopped;) {
            if (start == answer.stallAt && answer.gate && !held) {
                held = YES;
                dispatch_semaphore_wait(answer.gate, dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            }
            if (start >= end) {
                break;
            }
            NSUInteger length = MIN(answer.chunk, end - start);
            if (answer.stallAt > start && answer.stallAt < start + length) {
                length = answer.stallAt - start;
            }
            [self performSelector:@selector(deliverData:) onThread:thread
                       withObject:[body subdataWithRange:NSMakeRange(start, length)]
                    waitUntilDone:NO modes:modes];
            start += length;
        }
        if (answer.dropAt != NSNotFound) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_GATE_TIMEOUT];
            while (answer.ready && !answer.ready() && !self.stopped && deadline.timeIntervalSinceNow > 0) {
                usleep(1000);
            }
            NSError *lost = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
            [self performSelector:@selector(failLoading:) onThread:thread withObject:lost
                    waitUntilDone:NO modes:modes];
            return;
        }
        [self performSelector:@selector(finishLoading) onThread:thread withObject:nil
                waitUntilDone:NO modes:modes];
    });
}

- (void)deliverData:(NSData *)data {
    if (!self.stopped) {
        [self.client URLProtocol:self didLoadData:data];
    }
}

- (void)failLoading:(NSError *)error {
    if (!self.stopped) {
        self.ended = YES;
        [self.client URLProtocol:self didFailWithError:error];
    }
}

- (void)finishLoading {
    if (!self.stopped) {
        self.ended = YES;
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)stopLoading {
    self.stopped = YES;
    if (!self.ended) {
        [HTTPStubForHost(self.request.URL.host) noteStoppedAnswer];
    }
}

@end

#pragma mark - Stub

@implementation HTTPStub {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, HTTPStubFile *> *_files;
    NSMutableDictionary<NSString *, NSMutableArray<HTTPStubStep *> *> *_steps;
    NSMutableArray<NSURLRequest *> *_requests;
    NSMutableArray<NSNumber *> *_requestTimes;
    NSMutableArray<NSString *> *_hosts;
    NSUInteger _stoppedAnswers;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _host = [NSString stringWithFormat:@"%@.stub.test", NSUUID.UUID.UUIDString.lowercaseString];
        _files = [NSMutableDictionary dictionary];
        _steps = [NSMutableDictionary dictionary];
        _requests = [NSMutableArray array];
        _requestTimes = [NSMutableArray array];
        _hosts = [NSMutableArray arrayWithObject:_host];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses = @[HTTPStubProtocol.class];
        _configuration = configuration;
        os_unfair_lock_lock(&sHostsLock);
        if (!sHosts) {
            sHosts = [NSMapTable strongToWeakObjectsMapTable];
        }
        [sHosts setObject:self forKey:_host];
        os_unfair_lock_unlock(&sHostsLock);
    }
    return self;
}

- (void)dealloc {
    os_unfair_lock_lock(&sHostsLock);
    // Weak entries read nil once dealloc begins. An alias another stub took
    // since is that stub's.
    for (NSString *host in _hosts) {
        HTTPStub *current = [sHosts objectForKey:host];
        if (!current || current == self) {
            [sHosts removeObjectForKey:host];
        }
    }
    os_unfair_lock_unlock(&sHostsLock);
}

- (void)answerHost:(NSString *)host {
    os_unfair_lock_lock(&sHostsLock);
    [sHosts setObject:self forKey:host.lowercaseString];
    [_hosts addObject:host.lowercaseString];
    os_unfair_lock_unlock(&sHostsLock);
}

- (NSURL *)URLForPath:(NSString *)path {
    return [self URLForPath:path scheme:@"https"];
}

- (NSURL *)URLForPath:(NSString *)path scheme:(NSString *)scheme {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = scheme;
    components.host = _host;
    components.path = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    return components.URL;
}

- (HTTPStubFile *)serveData:(NSData *)data atPath:(NSString *)path headers:(NSDictionary *)headers {
    HTTPStubFile *file = [[HTTPStubFile alloc] init];
    file.data = data;
    file.headers = headers ?: @{};
    file.chunk = 64 * 1024;
    os_unfair_lock_lock(&_lock);
    _files[path] = file;
    os_unfair_lock_unlock(&_lock);
    return file;
}

- (void)queueStep:(HTTPStubStep *)step forPath:(NSString *)path {
    os_unfair_lock_lock(&_lock);
    NSMutableArray<HTTPStubStep *> *steps = _steps[path] ?: (_steps[path] = [NSMutableArray array]);
    [steps addObject:step];
    os_unfair_lock_unlock(&_lock);
}

- (NSArray<NSURLRequest *> *)requests {
    os_unfair_lock_lock(&_lock);
    NSArray<NSURLRequest *> *requests = [_requests copy];
    os_unfair_lock_unlock(&_lock);
    return requests;
}

- (NSArray<NSNumber *> *)requestTimes {
    os_unfair_lock_lock(&_lock);
    NSArray<NSNumber *> *times = [_requestTimes copy];
    os_unfair_lock_unlock(&_lock);
    return times;
}

- (NSUInteger)stoppedAnswers {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = _stoppedAnswers;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)noteStoppedAnswer {
    os_unfair_lock_lock(&_lock);
    _stoppedAnswers++;
    os_unfair_lock_unlock(&_lock);
}

- (NSArray<NSURLRequest *> *)requestsToPath:(NSString *)path {
    return [self.requests filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return [request.URL.path isEqualToString:path];
    }]];
}

// "bytes=a-b" or "bytes=a-": the first and last byte asked, -1 for an open end.
static BOOL HTTPStubParseRange(NSString *header, long long *first, long long *last) {
    if (![header hasPrefix:@"bytes="]) {
        return NO;
    }
    NSArray<NSString *> *parts = [[header substringFromIndex:6] componentsSeparatedByString:@"-"];
    if (parts.count != 2 || parts[0].length == 0) {
        return NO;
    }
    *first = parts[0].longLongValue;
    *last = parts[1].length > 0 ? parts[1].longLongValue : -1;
    return YES;
}

- (HTTPStubAnswer *)answerRequest:(NSURLRequest *)request {
    NSString *path = request.URL.path;
    os_unfair_lock_lock(&_lock);
    [_requests addObject:request];
    [_requestTimes addObject:@(CFAbsoluteTimeGetCurrent())];
    HTTPStubFile *file = _files[path];
    HTTPStubStep *step = _steps[path].firstObject;
    if (step) {
        [_steps[path] removeObjectAtIndex:0];
    }
    if (step.kind == HTTPStubStepKindChangeHeaders && file) {
        NSMutableDictionary *headers = [file.headers mutableCopy];
        [headers addEntriesFromDictionary:step.headers];
        file.headers = headers;
    }
    os_unfair_lock_unlock(&_lock);

    HTTPStubAnswer *answer = [[HTTPStubAnswer alloc] init];
    answer.chunk = file.chunk ?: 64 * 1024;
    answer.dropAt = NSNotFound;
    answer.stallAt = NSNotFound;
    if (step.kind == HTTPStubStepKindFail) {
        answer.error = step.error;
        return answer;
    }
    if (step.kind == HTTPStubStepKindStatus) {
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:step.status
                                                     HTTPVersion:@"HTTP/1.1" headerFields:step.headers];
        answer.body = step.body;
        return answer;
    }
    if (step.kind == HTTPStubStepKindRedirect) {
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:302 HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{@"Location": step.redirect.absoluteString}];
        NSMutableURLRequest *next = [request mutableCopy];
        next.URL = step.redirect;
        answer.redirect = next;
        return answer;
    }
    if (!file) {
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:404 HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{}];
        return answer;
    }
    if (step.kind == HTTPStubStepKindDrop) {
        answer.dropAt = step.bytes;
        answer.ready = step.ready;
    }
    if (step.kind == HTTPStubStepKindStall) {
        answer.stallAt = step.bytes;
        answer.gate = step.gate;
    }
    NSData *data = file.data;
    NSMutableDictionary<NSString *, NSString *> *headers = [file.headers mutableCopy];
    long long first = 0, last = -1;
    NSInteger status = 200;
    NSData *body = data;
    if (!file.ignoresRanges && HTTPStubParseRange([request valueForHTTPHeaderField:@"Range"], &first, &last)) {
        if (first >= (long long)data.length) {
            headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%lu", (unsigned long)data.length];
            answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:416 HTTPVersion:@"HTTP/1.1"
                                                        headerFields:headers];
            answer.dropAt = NSNotFound;
            answer.stallAt = NSNotFound;
            return answer;
        }
        if (last < 0 || last >= (long long)data.length) {
            last = (long long)data.length - 1;
        }
        status = 206;
        body = [data subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1))];
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lu", first, last,
                                     (unsigned long)data.length];
    }
    if (!file.omitsLength) {
        headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    }
    answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1"
                                                headerFields:headers];
    answer.body = body;
    return answer;
}

@end
