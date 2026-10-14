//
//  DropboxStubProtocol.m
//

#import "DropboxStubProtocol.h"

os_unfair_lock sStubLock = OS_UNFAIR_LOCK_INIT;
DropboxStubHandler sStubHandler;
NSMutableArray<NSURLRequest *> *sStubRequests;

DropboxStubResponse DropboxStubJSON(NSInteger status, id object) {
    return (DropboxStubResponse){status, @{@"Content-Type": @"application/json"},
            [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL], NO};
}

void DropboxStubInstall(DropboxStubHandler handler) {
    os_unfair_lock_lock(&sStubLock);
    sStubHandler = [handler copy];
    os_unfair_lock_unlock(&sStubLock);
}

void DropboxStubClearRequests(void) {
    os_unfair_lock_lock(&sStubLock);
    sStubRequests = [NSMutableArray array];
    os_unfair_lock_unlock(&sStubLock);
}

NSArray<NSURLRequest *> *DropboxStubRequestsToPath(NSString *path) {
    os_unfair_lock_lock(&sStubLock);
    NSArray<NSURLRequest *> *requests = [sStubRequests copy];
    os_unfair_lock_unlock(&sStubLock);
    return [requests filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSURLRequest *request, NSDictionary *bindings) {
        return [request.URL.path isEqualToString:path];
    }]];
}

// The loading thread's run loop may next turn in either mode.
static NSArray<NSString *> *DropboxStubModes(void) {
    NSMutableArray<NSString *> *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    NSString *mode = NSRunLoop.currentRunLoop.currentMode;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode]) {
        [modes addObject:mode];
    }
    return modes;
}

@implementation DropboxStubProtocol {
    DropboxStubResponse _gated;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

static NSData *DropboxStubBody(NSURLRequest *request) {
    if (request.HTTPBody) {
        return request.HTTPBody;
    }
    NSInputStream *stream = request.HTTPBodyStream;
    if (!stream) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    [stream open];
    uint8_t buffer[4096];
    NSInteger count;
    while ((count = [stream read:buffer maxLength:sizeof buffer]) > 0) {
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    [stream close];
    return data;
}

- (void)startLoading {
    NSData *body = DropboxStubBody(self.request);
    id json = body ? [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
    os_unfair_lock_lock(&sStubLock);
    DropboxStubHandler handler = sStubHandler;
    if (handler) {
        [sStubRequests addObject:self.request];
    }
    os_unfair_lock_unlock(&sStubLock);
    if (!handler) {
        // Between tests: a request an ended test's client sent late is left unanswered.
        return;
    }
    DropboxStubResponse response = handler(self.request, [json isKindOfClass:NSDictionary.class] ? json : nil);
    if (response.hang) {
        return;
    }
    if (response.gate) {
        _gated = response;
        NSThread *loader = NSThread.currentThread;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_semaphore_wait(response.gate, dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            [self performSelector:@selector(deliverGated) onThread:loader withObject:nil waitUntilDone:NO];
        });
        return;
    }
    [self deliver:response];
}

- (void)deliverGated {
    [self deliver:_gated];
}

- (void)deliver:(DropboxStubResponse)response {
    if (response.beforeResponse) {
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            response.beforeResponse();
            dispatch_block_t respond = ^{
                [self respond:response];
            };
            [self performSelector:@selector(runUnlessStopped:) onThread:thread withObject:respond
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    [self respond:response];
}

- (void)runUnlessStopped:(dispatch_block_t)block {
    if (!self.stopped) {
        block();
    }
}

- (void)respond:(DropboxStubResponse)response {
    if (response.status == 0 && response.failure) {
        [self.client URLProtocol:self didFailWithError:response.failure];
        return;
    }
    NSHTTPURLResponse *http = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:response.status
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:response.headers];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (response.body && response.chunk > 0) {
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        NSData *body = response.body;
        NSUInteger chunk = response.chunk;
        void (^beforeChunk)(NSUInteger) = response.beforeChunk;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (NSUInteger start = 0, index = 0; start < body.length && !self.stopped; start += chunk, index++) {
                if (beforeChunk) {
                    beforeChunk(index);
                }
                NSData *slice = [body subdataWithRange:NSMakeRange(start, MIN(chunk, body.length - start))];
                [self performSelector:@selector(deliverData:) onThread:thread withObject:slice
                        waitUntilDone:NO modes:modes];
            }
            [self performSelector:@selector(finishLoading) onThread:thread withObject:nil
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    if (response.body) {
        [self.client URLProtocol:self didLoadData:response.body];
    }
    if (response.failure) {
        // TRAP: a failure reported straight after the body overtakes it, and
        // the delegate never sees those bytes, so it waits until the client
        // has written them, then goes on the thread that started the load.
        NSThread *thread = NSThread.currentThread;
        NSArray<NSString *> *modes = DropboxStubModes();
        BOOL (^ready)(void) = response.failWhen;
        NSError *failure = response.failure;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_GATE_TIMEOUT];
            while (ready && !ready() && deadline.timeIntervalSinceNow > 0) {
                usleep(1000);
            }
            [self performSelector:@selector(failLoading:) onThread:thread withObject:failure
                    waitUntilDone:NO modes:modes];
        });
        return;
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)failLoading:(NSError *)failure {
    [self.client URLProtocol:self didFailWithError:failure];
}

- (void)deliverData:(NSData *)data {
    if (!self.stopped) {
        [self.client URLProtocol:self didLoadData:data];
    }
}

- (void)finishLoading {
    if (!self.stopped) {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

- (void)stopLoading {
    self.stopped = YES;
}

@end
