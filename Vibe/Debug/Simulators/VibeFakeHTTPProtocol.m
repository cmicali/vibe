//
//  VibeFakeHTTPProtocol.m
//  vibe-libs
//

#if DEBUG

#import "VibeFakeHTTPProtocol.h"

static const NSTimeInterval kStallPollSeconds = 0.02;
static const NSTimeInterval kLostConnectionPollSeconds = 0.005;
static const NSTimeInterval kLostConnectionWaitSeconds = 2;

NSData *VibeFakeHTTPBodyOfRequest(NSURLRequest *request) {
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

NSInteger VibeFakeHTTPRangeStatus(NSString *range, uint64_t size, NSMutableDictionary<NSString *, NSString *> *headers,
                                  uint64_t *first, uint64_t *length) {
    unsigned long long from = 0, last = ULLONG_MAX;
    if (!range || sscanf(range.UTF8String, "bytes=%llu-%llu", &from, &last) < 1) {
        *first = 0;
        *length = size;
        headers[@"Content-Length"] = @(size).stringValue;
        return 200;
    }
    if (from >= size) {
        *first = 0;
        *length = 0;
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%llu", size];
        headers[@"Content-Length"] = @"0";
        return 416;
    }
    last = MIN(last, size - 1);
    *first = from;
    *length = last >= from ? last - from + 1 : 0;
    headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu", from, last, size];
    headers[@"Content-Length"] = @(*length).stringValue;
    return 206;
}

@implementation VibeFakeHTTPAnswer

- (instancetype)init {
    self = [super init];
    if (self) {
        _piece = kVibeFakeHTTPPieceBytes;
        _holdAt = UINT64_MAX;
        _cutAt = UINT64_MAX;
    }
    return self;
}

@end

// Pieces of a body are delivered here, never on CFNetwork's protocol thread:
// a wait there would queue every other request behind it and hold a cancel
// until the whole file had gone out. HTTPStub's bodies too.
static dispatch_queue_t VibeFakeHTTPDeliveryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("vibe-libs.sharelinks.fake-http", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface VibeFakeHTTPProtocol ()
@property (atomic) BOOL cancelled;
// The last step is on its way. A stop after it is no cancel.
@property (atomic) BOOL ended;
@property (nonatomic, nullable) VibeFakeHTTPAnswer *answer;
@end

@implementation VibeFakeHTTPProtocol {
    NSThread *_loader;
    NSArray<NSRunLoopMode> *_modes;
}

// Installed on sessions their owner alone uses. Every request is the fake's.
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

// The client is told on the thread that started the load, as NSURLProtocol
// asks, never on the delivery queue.
- (void)tellClient:(dispatch_block_t)block {
    [self performSelector:@selector(runOnLoader:) onThread:_loader withObject:[block copy] waitUntilDone:NO
                    modes:_modes];
}

- (void)runOnLoader:(dispatch_block_t)block {
    if (!self.cancelled) {
        block();
    }
}

- (void)startLoading {
    _loader = NSThread.currentThread;
    NSMutableArray<NSRunLoopMode> *modes = [NSMutableArray arrayWithObject:NSDefaultRunLoopMode];
    NSRunLoopMode mode = NSRunLoop.currentRunLoop.currentMode;
    if (mode && ![mode isEqualToString:NSDefaultRunLoopMode]) {
        [modes addObject:mode];
    }
    _modes = modes;
    VibeFakeHTTPAnswer *answer = [self answerForRequest:self.request];
    self.answer = answer;
    if (!answer || answer.error) {
        self.ended = YES;
        [self.client URLProtocol:self didFailWithError:answer.error ?: [NSError errorWithDomain:NSURLErrorDomain
                                                                                           code:NSURLErrorCannotFindHost
                                                                                       userInfo:nil]];
        return;
    }
    if (answer.redirect) {
        // Followed, the session loads the new request through a new instance.
        // Refused, it answers the task with this response. Either way this
        // load is over.
        self.ended = YES;
        [self.client URLProtocol:self wasRedirectedToRequest:answer.redirect redirectResponse:answer.response];
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorCancelled userInfo:nil]];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(answer.latency * NSEC_PER_SEC)),
                   VibeFakeHTTPDeliveryQueue(), ^{
        if (self.cancelled) {
            return;
        }
        if (answer.progress) {
            answer.progress(@"running", 0);
        }
        [self tellClient:^{
            [self.client URLProtocol:self didReceiveResponse:answer.response
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }];
        [self deliverFrom:0 after:answer.interval];
    });
}

// One piece per step. The bytes written grow as a real transfer's do, and
// the loading bar reads them. A cancel lands between pieces. beforePiece is
// asked at every step, so a fault set mid-transfer applies to it.
- (void)deliverFrom:(uint64_t)delivered after:(NSTimeInterval)wait {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), VibeFakeHTTPDeliveryQueue(), ^{
        if (self.cancelled) {
            return;
        }
        VibeFakeHTTPAnswer *answer = self.answer;
        if (answer.beforePiece) {
            answer.beforePiece(answer, delivered);
        }
        uint64_t length = answer.length;
        if (delivered < length && delivered >= answer.holdAt) {
            if (answer.progress) {
                answer.progress(@"stalled", delivered);
            }
            [self deliverFrom:delivered after:kStallPollSeconds];
            return;
        }
        uint64_t piece = MIN(answer.piece, length - MIN(delivered, length));
        BOOL cut = answer.cutAt != UINT64_MAX && delivered + piece >= answer.cutAt;
        if (cut) {
            piece = answer.cutAt > delivered ? answer.cutAt - delivered : 0;
        }
        else if (answer.holdAt > delivered && answer.holdAt != UINT64_MAX) {
            // A hold not reached yet stops this piece at its offset.
            piece = MIN(piece, answer.holdAt - delivered);
        }
        NSData *bytes = piece > 0 ? answer.bytes(delivered, piece) ?: [NSData data] : [NSData data];
        if (bytes.length > 0) {
            [self tellClient:^{
                [self.client URLProtocol:self didLoadData:bytes];
            }];
        }
        uint64_t reached = delivered + bytes.length;
        BOOL complete = !cut && (reached >= length || (piece > 0 && bytes.length == 0));
        if (cut || complete) {
            self.ended = YES;
        }
        if (answer.progress) {
            answer.progress(cut ? @"dropped" : complete ? @"complete" : @"running", reached);
        }
        if (cut) {
            [self loseConnectionOnceTaskHolds:reached waited:0];
            return;
        }
        if (complete) {
            [self tellClient:^{
                [self.client URLProtocolDidFinishLoading:self];
            }];
            return;
        }
        [self deliverFrom:reached after:answer.interval];
    });
}

// TRAP: a failure sent straight after the bytes overtakes them on the
// client's side. The session then takes the connection as lost before any
// byte, and sends the request again itself, whole, never the client's
// Range resend. So the failure waits until the task holds the bytes.
- (void)loseConnectionOnceTaskHolds:(uint64_t)delivered waited:(NSTimeInterval)waited {
    if (self.cancelled) {
        return;
    }
    BOOL (^ready)(void) = self.answer.ready;
    BOOL held = self.task.countOfBytesReceived >= (int64_t)delivered || waited >= kLostConnectionWaitSeconds;
    if (!held || (ready && !ready())) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLostConnectionPollSeconds * NSEC_PER_SEC)),
                       VibeFakeHTTPDeliveryQueue(), ^{
            [self loseConnectionOnceTaskHolds:delivered waited:waited + kLostConnectionPollSeconds];
        });
        return;
    }
    [self tellClient:^{
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                           code:NSURLErrorNetworkConnectionLost
                                                                       userInfo:nil]];
    }];
}

// Also sent after a load that finished. Only one still running was cancelled.
- (void)stopLoading {
    self.cancelled = YES;
    VibeFakeHTTPAnswer *answer = self.answer;
    if (!self.ended && answer.progress) {
        answer.progress(@"cancelled", 0);
    }
}

@end

#endif
