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

// Gates and failWhen wait off the loader thread, up to VIBE_TEST_GATE_TIMEOUT.
// A failure follows the body unless status is zero. beforeResponse and
// beforeChunk run off the loader thread and can hold their delivery.
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
