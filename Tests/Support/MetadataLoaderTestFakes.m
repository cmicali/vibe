//
//  MetadataLoaderTestFakes.m
//

#import "MetadataLoaderTestFakes.h"

// The real AudioTrackMetadata is ObjC++/TagLib and stays out of the host-less
// target. The tests replace the loader's parse boundary; this definition only
// satisfies the dormant path's class reference and raises if it is crossed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation AudioTrackMetadata
+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)metadataWithURL:(NSURL *)url displayArtData:(NSData **)displayArtData {
    [NSException raise:NSInternalInconsistencyException
                format:@"Metadata parser escaped its test seam for %@", url];
    return nil;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    return [super init];
}

- (void)encodeWithCoder:(NSCoder *)coder {
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}
@end
#pragma clang diagnostic pop

// PlaylistController observes it. The real definition is in the ObjC++ file.
NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification =
        @"AudioTrackMetadataThumbnailDidLoadNotification";

@implementation VibeLoaderTestMetadata
// None: a parse of a file that exists has a cache key, and its cache write
// asks after the art.
- (id)artwork {
    return nil;
}

- (id)copyWithZone:(NSZone *)zone {
    VibeLoaderTestMetadata *copy = [[[self class] allocWithZone:zone] init];
    copy.parsedOK = self.parsedOK;
    copy.marker = self.marker;
    copy.cacheKey = self.cacheKey;
    return copy;
}
@end

AudioTrackMetadata *VibeLoaderTestMetadataResult(BOOL parsedOK,
                                                 NSString *marker) {
    VibeLoaderTestMetadata *metadata = [[VibeLoaderTestMetadata alloc] init];
    metadata.parsedOK = parsedOK;
    metadata.marker = marker;
    return (AudioTrackMetadata *)metadata;
}

NSMutableArray<AudioTrack *> *VibeLoaderTestCueRows(NSURL *image, NSUInteger count) {
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger row = 0; row < count; row++) {
        [rows addObject:[[AudioTrack alloc] initWithURL:image cueStart:row * 750
                                                 cueEnd:(row + 1) * 750
                                                  title:nil performer:nil sheet:nil
                                            trackNumber:(NSInteger)row + 1]];
    }
    return rows;
}

@implementation VibeMetadataLoaderOwner
@end

@implementation VibeMetadataLoaderDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _deliveredTracks = [NSMutableArray array];
        _deliveredMetadata = [NSMutableArray array];
        _allDeliveriesOnMain = YES;
    }
    return self;
}

- (void)didLoadMetadata:(AudioTrack *)track {
    self.allDeliveriesOnMain &= NSThread.isMainThread;
    [self.deliveredTracks addObject:track];
    [self.deliveredMetadata addObject:track.metadata];
    [self.deliveryExpectation fulfill];
}
@end

@implementation VibeMetadataLoaderOperation {
    NSURL *_url;
    VibeAudioFileMaterializationRole _role;
    __weak VibeMetadataLoaderOperationController *_controller;
    NSCondition *_condition;
    BOOL _finished;
    BOOL _ready;
    BOOL _cancelled;
}

- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeMetadataLoaderOperationController *)controller {
    self = [super init];
    if (self) {
        _url = [url copy];
        _role = role;
        _controller = controller;
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (BOOL)runOnReadable:(dispatch_block_t)onReadable error:(NSError *__autoreleasing *)error {
    VibeMetadataLoaderOperationController *controller = _controller;
    // TRAP: recordStart fulfills the test's synchronization edge, after which
    // the test may clear the hold. Read the hold first, or a clear landing in
    // between turns this parked run into a success.
    BOOL parks = controller.blocksUntilCancelled;
    [controller recordStartForURL:_url role:_role];
    if ([controller consumeFailureForURL:_url]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError userInfo:nil];
        }
        return NO;
    }
    dispatch_block_t afterFailureCheck = [controller takeAfterFailureCheck];
    if (afterFailureCheck) {
        afterFailureCheck();
    }
    if (!parks) {
        return YES;
    }
    [_condition lock];
    while (!_finished) {
        [_condition wait];
    }
    BOOL ready = _ready;
    BOOL cancelled = _cancelled;
    [_condition unlock];
    if (!ready && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:cancelled ? NSUserCancelledError
                                                    : NSFileReadUnknownError
                                 userInfo:nil];
    }
    return ready;
}

- (void)cancel {
    [_condition lock];
    BOOL first = !_finished;
    _finished = YES;
    _ready = NO;
    _cancelled = YES;
    [_condition broadcast];
    [_condition unlock];
    if (first) {
        [_controller recordCancellation];
    }
}

- (void)completeFailed {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = NO;
        _cancelled = NO;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)completeReady {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = YES;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)forceCancel {
    [self cancel];
}

@end

@implementation VibeMetadataLoaderOperationController {
    NSLock *_lock;
    NSMutableArray<VibeMetadataLoaderOperation *> *_operations;
    NSMutableArray<NSURL *> *_startedURLs;
    NSMutableArray<NSNumber *> *_startedRoles;
    NSMutableDictionary<NSString *, NSNumber *> *_failuresRemainingByPath;
    dispatch_block_t _afterFailureCheck;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _operations = [NSMutableArray array];
        _startedURLs = [NSMutableArray array];
        _startedRoles = [NSMutableArray array];
        _failuresRemainingByPath = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role {
    VibeMetadataLoaderOperation *operation = [[VibeMetadataLoaderOperation alloc]
            initWithURL:url role:role controller:self];
    [_lock lock];
    [_operations addObject:operation];
    [_lock unlock];
    return operation;
}

- (void)recordStartForURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role {
    [_lock lock];
    [_startedURLs addObject:url];
    [_startedRoles addObject:@(role)];
    NSUInteger count = _startedURLs.count;
    void (^observer)(NSURL *, VibeAudioFileMaterializationRole) = self.startObserver;
    XCTestExpectation *first = self.firstStartExpectation;
    XCTestExpectation *all = self.allStartsExpectation;
    [_lock unlock];
    if (observer) {
        observer(url, role);
    }
    if (count == 1) {
        [first fulfill];
    }
    [all fulfill];
}

- (void)recordCancellation {
    [self.cancellationExpectation fulfill];
}

- (BOOL)consumeFailureForURL:(NSURL *)url {
    [_lock lock];
    NSUInteger remaining = _failuresRemainingByPath[url.path].unsignedIntegerValue;
    if (remaining > 0) {
        _failuresRemainingByPath[url.path] = @(remaining - 1);
    }
    [_lock unlock];
    return remaining > 0;
}

- (void)setAfterFailureCheck:(dispatch_block_t)afterFailureCheck {
    [_lock lock];
    _afterFailureCheck = [afterFailureCheck copy];
    [_lock unlock];
}

- (dispatch_block_t)takeAfterFailureCheck {
    [_lock lock];
    dispatch_block_t afterFailureCheck = _afterFailureCheck;
    _afterFailureCheck = nil;
    [_lock unlock];
    return afterFailureCheck;
}

- (NSArray<NSURL *> *)startedURLs {
    [_lock lock];
    NSArray *result = [_startedURLs copy];
    [_lock unlock];
    return result;
}

- (NSArray<NSNumber *> *)startedRoles {
    [_lock lock];
    NSArray *result = [_startedRoles copy];
    [_lock unlock];
    return result;
}

- (void)failNextStarts:(NSUInteger)count forURL:(NSURL *)url {
    [_lock lock];
    _failuresRemainingByPath[url.path] = @(count);
    [_lock unlock];
}

- (void)completeFirstReady {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.firstObject;
    [_lock unlock];
    [operation completeReady];
}

- (void)completeFirstFailed {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.firstObject;
    [_lock unlock];
    [operation completeFailed];
}

- (void)completeLastReady {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.lastObject;
    [_lock unlock];
    [operation completeReady];
}

- (void)cancelAll {
    [_lock lock];
    NSArray *operations = [_operations copy];
    [_lock unlock];
    for (VibeMetadataLoaderOperation *operation in operations) {
        [operation forceCancel];
    }
}

@end
