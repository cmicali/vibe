//
//  LinkStoreTestCase.m
//

#import "LinkStoreTestCase.h"

#include <stdlib.h>

#import "CloudFileMaterializer.h"

@implementation LinkStoreTestCase {
    NSMutableArray<dispatch_semaphore_t> *_gates;
}

- (void)setUp {
    [super setUp];
    _stub = [[HTTPStub alloc] init];
    _client = [[HTTPTransferClient alloc] initWithConfiguration:_stub.configuration];
    _client.retryDelayScale = 0.01;
    _gates = [NSMutableArray array];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"LinkStoreTests-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    char resolved[PATH_MAX];
    _base = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    _root = [_base URLByAppendingPathComponent:@"Links" isDirectory:YES];
    _store = [[LinkStore alloc] initWithClient:_client rootURL:_root];
}

- (void)tearDown {
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    // A held stub delivery goes on to find its load stopped.
    for (dispatch_semaphore_t gate in _gates) {
        dispatch_semaphore_signal(gate);
        dispatch_semaphore_signal(gate);
    }
    [NSFileManager.defaultManager removeItemAtURL:_base error:NULL];
    [super tearDown];
}

- (dispatch_semaphore_t)gate {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [_gates addObject:gate];
    return gate;
}

- (HTTPStubFile *)serve:(NSData *)bytes at:(NSString *)path headers:(NSDictionary<NSString *, NSString *> *)headers {
    return [_stub serveData:bytes atPath:path headers:headers];
}

- (NSURL *)resolve:(NSString *)link error:(NSError **)error {
    __block NSURL *file = nil;
    __block NSError *failure = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"resolved"];
    [_store resolveURLString:link completion:^(NSURL *answer, NSError *answerError) {
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertTrue((answer == nil) != (answerError == nil), @"exactly one of file and error");
        file = answer;
        failure = answerError;
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    if (error) *error = failure;
    return file;
}

- (NSURL *)resolvePath:(NSString *)path {
    NSError *error = nil;
    NSURL *file = [self resolve:[_stub URLForPath:path].absoluteString error:&error];
    XCTAssertNotNil(file, @"%@", error);
    return file;
}

- (VibeLinkError)failureOf:(NSString *)link {
    NSError *error = nil;
    XCTAssertNil([self resolve:link error:&error]);
    XCTAssertEqualObjects(error.domain, VibeLinkErrorDomain);
    return (VibeLinkError)error.code;
}

- (NSDictionary *)recordOf:(NSURL *)file {
    return [_store indexOfDirectory:file.URLByDeletingLastPathComponent];
}

- (NSArray<NSString *> *)linkDirectories {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:_root.path error:NULL]
            sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

@end
