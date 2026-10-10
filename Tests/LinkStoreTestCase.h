//
//  LinkStoreTestCase.h
//
//  The harness LinkStoreTests and each host's link tests share: a real
//  LinkStore over the plain HTTPTransferClient, HTTPStub, and a per-test temp
//  root. It runs no tests itself.
//

#import <XCTest/XCTest.h>

#import "HTTPStub.h"
#import "HTTPTransferClientInternal.h"
#import "LinkStore.h"
#import "RemotePlaceholderStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const kModified = @"Wed, 21 Oct 2015 07:28:00 GMT";
static const time_t kModifiedTime = 1445412480;

// A FLAC's signature, then a pattern: audio to the probe, distinct bytes to
// every range.
static inline NSData *FlacBytes(NSUInteger count) {
    NSMutableData *data = [PatternBytes(count) mutableCopy];
    memcpy(data.mutableBytes, "fLaC", MIN(count, (NSUInteger)4));
    return data;
}

@interface LinkStoreTestCase : XCTestCase {
@protected
    HTTPStub *_stub;
    HTTPTransferClient *_client;
    LinkStore *_store;
    NSURL *_base;
    NSURL *_root;
}

// Signalled twice at tearDown, so a held stub delivery goes on.
- (dispatch_semaphore_t)gate;
- (HTTPStubFile *)serve:(NSData *)bytes at:(NSString *)path headers:(nullable NSDictionary<NSString *, NSString *> *)headers;
// The link resolved on the store, on main, exactly one of file and error.
- (nullable NSURL *)resolve:(NSString *)link error:(NSError *_Nullable *_Nullable)error;
// The stub's path resolved, which must open.
- (NSURL *)resolvePath:(NSString *)path;
// The link's failure, which must be one of the store's own.
- (VibeLinkError)failureOf:(NSString *)link;
- (nullable NSDictionary *)recordOf:(NSURL *)file;
- (NSArray<NSString *> *)linkDirectories;

@end

NS_ASSUME_NONNULL_END
