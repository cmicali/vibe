//
//  DropboxStubProtocol.h
//
//  The Dropbox tests' HTTP boundary, an NSURLProtocol in the session's
//  configuration. Every request goes to one handler the test installs, and
//  the handler's answer can hang, wait on a gate, go out in held chunks or
//  end in a dropped connection. The handler and the request log are
//  process-wide, so one test at a time installs a handler.
//

#import <Foundation/Foundation.h>

#include <os/lock.h>

NS_ASSUME_NONNULL_BEGIN

// A response: status, headers, body; or hang until the task is cancelled; or
// answer only once `gate` is signalled, without holding the loader thread,
// so other requests are answered meanwhile. A failure ends the load after
// the body, a dropped connection, once failWhen answers YES; with status 0 it
// comes before any response. With a chunk length the body goes out in
// chunks, beforeChunk asked off the loading thread ahead of each, so a test
// can hold the next one back; beforeResponse, asked the same way, holds
// the response itself.
typedef struct {
    NSInteger status;
    NSDictionary<NSString *, NSString *> *_Nullable headers;
    NSData *_Nullable body;
    BOOL hang;
    dispatch_semaphore_t _Nullable gate;
    NSError *_Nullable failure;
    BOOL (^_Nullable failWhen)(void);
    NSUInteger chunk;
    void (^_Nullable beforeChunk)(NSUInteger index);
    dispatch_block_t _Nullable beforeResponse;
} DropboxStubResponse;

typedef DropboxStubResponse (^DropboxStubHandler)(NSURLRequest *request, NSDictionary *_Nullable json);

// Guards the handler and the request log.
extern os_unfair_lock sStubLock;
// Nil between tests: a request then is left unanswered.
extern DropboxStubHandler _Nullable sStubHandler;
// Every request that found a handler, in arrival order.
extern NSMutableArray<NSURLRequest *> *sStubRequests;

DropboxStubResponse DropboxStubJSON(NSInteger status, id object);

@interface DropboxStubProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

NS_ASSUME_NONNULL_END
