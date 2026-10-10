//
//  HTTPStub.m
//

#import "HTTPStub.h"

#include <os/lock.h>

#import "VibeFakeHTTP.h"

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

@interface HTTPStub ()
- (nullable VibeFakeHTTPAnswer *)answerRequest:(NSURLRequest *)request;
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

// The fake's engine, answering by this stub's script.
@interface HTTPStubProtocol : VibeFakeHTTPProtocol
@end

@implementation HTTPStubProtocol

- (VibeFakeHTTPAnswer *)answerForRequest:(NSURLRequest *)request {
    return [HTTPStubForHost(request.URL.host) answerRequest:request];
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
        NSURLSessionConfiguration *configuration = VibeFakeHTTP.sessionConfiguration;
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

- (VibeFakeHTTPAnswer *)answerRequest:(NSURLRequest *)request {
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

    VibeFakeHTTPAnswer *answer = [[VibeFakeHTTPAnswer alloc] init];
    answer.piece = file.chunk ?: 64 * 1024;
    __weak HTTPStub *weakSelf = self;
    answer.progress = ^(NSString *outcome, uint64_t delivered) {
        if ([outcome isEqualToString:@"cancelled"]) {
            [weakSelf noteStoppedAnswer];
        }
    };
    if (step.kind == HTTPStubStepKindFail) {
        answer.error = step.error;
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
    NSData *body = step.body;
    if (step.kind == HTTPStubStepKindStatus) {
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:step.status
                                                     HTTPVersion:@"HTTP/1.1" headerFields:step.headers];
    }
    else if (!file) {
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:404 HTTPVersion:@"HTTP/1.1"
                                                    headerFields:@{}];
    }
    else {
        NSData *data = file.data;
        NSMutableDictionary<NSString *, NSString *> *headers = [file.headers mutableCopy];
        uint64_t first = 0, length = 0;
        NSInteger status = VibeFakeHTTPRangeStatus(file.ignoresRanges ? nil : [request valueForHTTPHeaderField:@"Range"],
                                                   data.length, headers, &first, &length);
        if (file.omitsLength || status == 416) {
            [headers removeObjectForKey:@"Content-Length"];
        }
        answer.response = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:status HTTPVersion:@"HTTP/1.1"
                                                    headerFields:headers];
        body = [data subdataWithRange:NSMakeRange((NSUInteger)first, (NSUInteger)length)];
        if (status != 416 && step.kind == HTTPStubStepKindDrop) {
            answer.cutAt = MIN((uint64_t)step.bytes, length);
            answer.ready = step.ready;
        }
        if (status != 416 && step.kind == HTTPStubStepKindStall) {
            // Held at its offset until the gate is signalled, once.
            uint64_t holdAt = step.bytes;
            dispatch_semaphore_t gate = step.gate;
            __block BOOL released = NO;
            answer.holdAt = holdAt;
            answer.beforePiece = ^(VibeFakeHTTPAnswer *held, uint64_t delivered) {
                if (!released && delivered >= holdAt && dispatch_semaphore_wait(gate, DISPATCH_TIME_NOW) == 0) {
                    released = YES;
                    held.holdAt = UINT64_MAX;
                }
            };
        }
    }
    answer.length = body.length;
    answer.bytes = ^NSData *(uint64_t offset, uint64_t count) {
        return [body subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)count)];
    };
    return answer;
}
@end
