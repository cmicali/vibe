//
//  CloudFileMaterializer.m
//  Vibe
//

#import "CloudFileMaterializer.h"
#import "NSURLUtil.h"
#if DEBUG
#import "CloudFileMaterializer+Debug.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <unistd.h>

// The remote backend, installed together (setRemoteRoot:fetch:read:availability:).
static os_unfair_lock sRemoteLock = OS_UNFAIR_LOCK_INIT;
static CloudFileRemoteFetch sRemoteFetch;
static CloudFileRemoteRead sRemoteRead;
static CloudFileRemoteAvailability sRemoteAvailability;

static CloudFileRemoteFetch VibeRemoteFetch(void) {
    os_unfair_lock_lock(&sRemoteLock);
    CloudFileRemoteFetch fetch = sRemoteFetch;
    os_unfair_lock_unlock(&sRemoteLock);
    return fetch;
}

#if DEBUG
// TRAP: written by the debug channel on main, read on download workers. An
// unlocked read of a block global is a retain racing a release.
static os_unfair_lock sFakeLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval (^sFakeTransferSeconds)(NSURL *, NSString *);   // nil or 0: the real read
static BOOL (^sFakeAcquireSlot)(NSURL *, NSString *, BOOL (^)(void));
static void (^sFakeReleaseSlot)(NSURL *, NSString *);
static void (^sFakeTransferDidFinish)(NSURL *, NSString *, BOOL);

static void VibeFakeTransferHooks(NSTimeInterval (^*seconds)(NSURL *, NSString *),
                                  BOOL (^*acquireSlot)(NSURL *, NSString *, BOOL (^)(void)),
                                  void (^*releaseSlot)(NSURL *, NSString *),
                                  void (^*didFinish)(NSURL *, NSString *, BOOL)) {
    os_unfair_lock_lock(&sFakeLock);
    *seconds = sFakeTransferSeconds;
    *acquireSlot = sFakeAcquireSlot;
    *releaseSlot = sFakeReleaseSlot;
    *didFinish = sFakeTransferDidFinish;
    os_unfair_lock_unlock(&sFakeLock);
}
#endif

// A wait with no part file sleeps this long at most before it asks its
// `interrupted` again.
static const NSTimeInterval kInterruptPollSeconds = 0.25;

// A contiguous copy of its own: a response's bytes can be dispatch data in
// pieces, which reading them through .bytes would flatten into a second
// buffer held beside the first.
static NSData *VibeContiguousCopy(NSData *bytes) {
    NSMutableData *copy = [NSMutableData dataWithLength:bytes.length];
    [bytes getBytes:copy.mutableBytes length:bytes.length];
    return copy;
}

@implementation CloudFileAvailability {
    NSCondition *_condition;
    uint64_t _size;
    uint64_t _written;
    BOOL _complete;
    NSError *_failure;
    NSUInteger _readers;
    dispatch_block_t _onLastReaderGone;
    // Offset-ordered and disjoint, each offset beside its block. A
    // transfer's one block lies wholly past _written, so a read never mixes
    // the disk and memory.
    NSMutableArray<NSData *> *_blocks;
    NSMutableArray<NSNumber *> *_blockOffsets;
    uint64_t _installedBytes;
    // What the writer's wait for work reports. Only a writer with no part
    // file reads them.
    uint64_t _readerPosition;
    uint64_t _wantedOffset;
    uint64_t _wantedLength;
    uint64_t _signalledBlockOffset;
    BOOL _writerSignalled;
    BOOL _readAheadPaused;
}

- (instancetype)initWithoutPartFile {
    self = [super init];
    if (self) {
        _size = UINT64_MAX;
        _condition = [[NSCondition alloc] init];
        _blocks = [NSMutableArray array];
        _blockOffsets = [NSMutableArray array];
        _signalledBlockOffset = UINT64_MAX;
    }
    return self;
}

- (instancetype)initWithPartURL:(NSURL *)partURL size:(uint64_t)size {
    self = [self initWithoutPartFile];
    if (self) {
        _partURL = partURL;
        _size = size;
    }
    return self;
}

- (uint64_t)size {
    [_condition lock];
    uint64_t size = _size;
    [_condition unlock];
    return size;
}

- (void)noteSize:(uint64_t)size {
    [_condition lock];
    if (_size == UINT64_MAX) {
        _size = size;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)noteShortenedEnd:(uint64_t)end {
    [_condition lock];
    if (_size != UINT64_MAX && end < _size) {
        _size = end;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)noteWrittenBytes:(uint64_t)bytes {
    [_condition lock];
    if (bytes > _written) {
        _written = MIN(bytes, _size);
        // TRAP: dropped under the lock a reader copies under, so a wait a
        // block answered has copied before the block can go. A range in it
        // past the download's edge waits for the disk from here.
        while (_blocks.count > 0 && _blockOffsets[0].unsignedLongLongValue <= _written) {
            [_blocks removeObjectAtIndex:0];
            [_blockOffsets removeObjectAtIndex:0];
        }
        [_condition broadcast];
    }
    [_condition unlock];
}

- (uint64_t)writtenBytes {
    [_condition lock];
    uint64_t written = _written;
    [_condition unlock];
    return written;
}

- (uint64_t)progressBytes {
    [_condition lock];
    uint64_t progress = _written + _installedBytes;
    [_condition unlock];
    return progress;
}

- (void)finishWithError:(NSError *)error {
    // TRAP: complete sends every reader to the disk. A writer with no part
    // file has written nothing there.
    NSAssert(error || _partURL, @"An availability with no part file finishes only with an error");
    [_condition lock];
    if (!_complete && !_failure) {
        _complete = error == nil;
        _failure = error;
        [_blocks removeAllObjects];
        [_blockOffsets removeAllObjects];
        [_condition broadcast];
    }
    [_condition unlock];
}

// Under the lock: where the blocks held contiguously from offset end, and in
// *index the block holding offset. Offset itself, and NSNotFound, when no
// block holds it.
- (uint64_t)heldEndAt:(uint64_t)offset block:(NSUInteger *)index {
    *index = NSNotFound;
    uint64_t end = offset;
    for (NSUInteger i = 0; i < _blocks.count; i++) {
        uint64_t start = _blockOffsets[i].unsignedLongLongValue;
        if (start > end) {
            break;
        }
        uint64_t blockEnd = start + _blocks[i].length;
        if (blockEnd > end) {
            if (*index == NSNotFound) {
                *index = i;
            }
            end = blockEnd;
        }
    }
    return end;
}

// Under the lock: length bytes from offset, held from block index on.
- (void)copyHeldBytesAt:(uint64_t)offset length:(uint64_t)length fromBlock:(NSUInteger)index into:(uint8_t *)buffer {
    for (uint64_t copied = 0; copied < length; index++) {
        NSData *block = _blocks[index];
        uint64_t inBlock = offset + copied - _blockOffsets[index].unsignedLongLongValue;
        uint64_t count = MIN(length - copied, block.length - inBlock);
        memcpy(buffer + copied, (const uint8_t *)block.bytes + inBlock, (size_t)count);
        copied += count;
    }
}

// Under the lock: the bytes at offset take the place of every block they
// overlap.
- (void)insertBlock:(NSData *)block atOffset:(uint64_t)offset {
    NSUInteger at = 0;
    NSMutableIndexSet *overlapped = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < _blocks.count; i++) {
        uint64_t start = _blockOffsets[i].unsignedLongLongValue;
        if (start + _blocks[i].length <= offset) {
            at = i + 1;
        }
        else if (start < offset + block.length) {
            [overlapped addIndex:i];
        }
    }
    [_blocks removeObjectsAtIndexes:overlapped];
    [_blockOffsets removeObjectsAtIndexes:overlapped];
    [_blocks insertObject:block atIndex:at];
    [_blockOffsets insertObject:@(offset) atIndex:at];
    _installedBytes += block.length;
    [_condition broadcast];
}

- (void)installWindow:(NSData *)bytes atOffset:(uint64_t)offset {
    NSData *window = VibeContiguousCopy(bytes);
    [_condition lock];
    if (!_complete && !_failure && _blocks.count == 0 && window.length > 0 && offset > _written && offset < _size
            && window.length <= _size - offset) {
        [self insertBlock:window atOffset:offset];
    }
    [_condition unlock];
}

- (void)installBlock:(NSData *)bytes atOffset:(uint64_t)offset {
    NSData *block = VibeContiguousCopy(bytes);
    NSUInteger index;
    [_condition lock];
    if (!_complete && !_failure && block.length > 0 && offset < _size && block.length <= _size - offset
            && [self heldEndAt:offset block:&index] < offset + block.length) {
        [self insertBlock:block atOffset:offset];
    }
    [_condition unlock];
}

- (void)dropBlocksOutsideRangeAt:(uint64_t)offset length:(uint64_t)length {
    uint64_t end = offset + MIN(length, UINT64_MAX - offset);
    NSMutableIndexSet *dropped = [NSMutableIndexSet indexSet];
    [_condition lock];
    uint64_t wantedEnd = _wantedOffset + _wantedLength;
    for (NSUInteger i = 0; i < _blocks.count; i++) {
        uint64_t start = _blockOffsets[i].unsignedLongLongValue;
        uint64_t blockEnd = start + _blocks[i].length;
        BOOL wanted = _wantedLength > 0 && blockEnd > _wantedOffset && start < wantedEnd;
        if ((blockEnd <= offset || start >= end) && start != 0 && blockEnd != _size && !wanted) {
            [dropped addIndex:i];
        }
    }
    // TRAP: dropped under the lock a reader copies under, so a wait a block
    // answered has copied before the block can go.
    [_blocks removeObjectsAtIndexes:dropped];
    [_blockOffsets removeObjectsAtIndexes:dropped];
    [_condition unlock];
}

- (uint64_t)windowLength {
    [_condition lock];
    uint64_t length = 0;
    for (NSData *block in _blocks) {
        length += block.length;
    }
    [_condition unlock];
    return length;
}

// Under the lock.
- (void)signalWriter {
    _writerSignalled = YES;
    [_condition broadcast];
}

- (CloudFileAvailabilityWait)waitForBytesAt:(uint64_t)offset
                                     length:(uint64_t)length
                                 windowInto:(void *)buffer
                                   capacity:(uint64_t)capacity
                                     copied:(uint64_t *)copied
                                interrupted:(BOOL (NS_NOESCAPE ^)(void))interrupted
                                   deadline:(NSDate *)deadline
                                      error:(NSError *__autoreleasing *)error {
    BOOL noPartFile = _partURL == nil;
    BOOL wantedRecorded = NO;
    uint64_t fromBlocks = 0;
    CloudFileAvailabilityWait result;
    NSError *failure = nil;
    [_condition lock];
    _readerPosition = offset;
    for (;;) {
        // Each pass, since a writer with no part file sets and lowers the size.
        BOOL end = offset >= _size || length == 0;
        uint64_t last = end ? 0 : offset + MIN(length, _size - offset);
        if (_failure) {
            failure = _failure;
            result = CloudFileAvailabilityFailed;
            break;
        }
        if (end || _complete || last <= _written) {
            result = CloudFileAvailabilityReady;
            break;
        }
        NSUInteger block;
        uint64_t held = [self heldEndAt:offset block:&block];
        if (last <= held) {
            if (buffer) {
                fromBlocks = MIN(capacity, MIN(held, _size) - offset);
                [self copyHeldBytesAt:offset length:fromBlocks fromBlock:block into:buffer];
            }
            // The writer refills ahead once the reader enters another block,
            // well before the reader reaches the edge of what is held.
            uint64_t blockOffset = _blockOffsets[block].unsignedLongLongValue;
            if (noPartFile && blockOffset != _signalledBlockOffset) {
                _signalledBlockOffset = blockOffset;
                [self signalWriter];
            }
            result = CloudFileAvailabilityReady;
            break;
        }
        if (interrupted && interrupted()) {
            result = CloudFileAvailabilityInterrupted;
            break;
        }
        if (!noPartFile) {
            if (!deadline) {
                [_condition wait];
            }
            else if (![_condition waitUntilDate:deadline]) {
                result = CloudFileAvailabilityInterrupted;
                break;
            }
            continue;
        }
        if (_wantedOffset != offset || _wantedLength != last - offset) {
            _wantedOffset = offset;
            _wantedLength = last - offset;
            wantedRecorded = YES;
            [self signalWriter];
        }
        NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:kInterruptPollSeconds];
        if (![_condition waitUntilDate:deadline ? [deadline earlierDate:slice] : slice]
                && deadline && deadline.timeIntervalSinceNow <= 0) {
            result = CloudFileAvailabilityInterrupted;
            break;
        }
    }
    if (wantedRecorded && _wantedOffset == offset) {
        _wantedLength = 0;
    }
    [_condition unlock];
    if (copied) {
        *copied = fromBlocks;
    }
    if (failure && error) {
        *error = failure;
    }
    return result;
}

- (NSData *)readyBytesAt:(uint64_t)offset length:(uint64_t)length {
    uint64_t onDisk = 0;
    [_condition lock];
    if (_complete || _failure || offset >= _size || length == 0) {
        [_condition unlock];
        return nil;
    }
    length = MIN(length, _size - offset);
    NSUInteger block;
    uint64_t held = [self heldEndAt:offset block:&block];
    if (block != NSNotFound) {
        NSMutableData *copy = [NSMutableData dataWithLength:(NSUInteger)MIN(length, MIN(held, _size) - offset)];
        [self copyHeldBytesAt:offset length:copy.length fromBlock:block into:copy.mutableBytes];
        [_condition unlock];
        return copy;
    }
    if (offset < _written) {
        onDisk = MIN(length, _written - offset);
    }
    [_condition unlock];
    int fd = onDisk > 0 ? open(_partURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC) : -1;
    if (fd < 0) {
        return nil;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)onDisk];
    uint64_t got = 0;
    while (got < onDisk) {
        ssize_t count = pread(fd, (uint8_t *)bytes.mutableBytes + got, (size_t)(onDisk - got), (off_t)(offset + got));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            break;
        }
        got += (uint64_t)count;
    }
    close(fd);
    bytes.length = (NSUInteger)got;
    return got > 0 ? bytes : nil;
}

- (void)wakeWaiters {
    [_condition lock];
    [_condition broadcast];
    [_condition unlock];
}

- (BOOL)waitForWorkUntil:(NSDate *)deadline
                  wanted:(uint64_t *)offset
                  length:(uint64_t *)length
          readerPosition:(uint64_t *)position {
    [_condition lock];
    while (!_writerSignalled && !_complete && !_failure) {
        if (![_condition waitUntilDate:deadline]) {
            break;
        }
    }
    _writerSignalled = NO;
    BOOL running = !_complete && !_failure;
    *offset = _wantedOffset;
    *length = _wantedLength;
    *position = _readerPosition;
    [_condition unlock];
    return running;
}

- (BOOL)readAheadPaused {
    [_condition lock];
    BOOL paused = _readAheadPaused;
    [_condition unlock];
    return paused;
}

- (void)setReadAheadPaused:(BOOL)readAheadPaused {
    [_condition lock];
    if (_readAheadPaused && !readAheadPaused) {
        [self signalWriter];
    }
    _readAheadPaused = readAheadPaused;
    [_condition unlock];
}

- (void)addReader {
    [_condition lock];
    _readers++;
    [_condition unlock];
}

- (void)removeReader {
    [_condition lock];
    dispatch_block_t gone = nil;
    if (_readers > 0 && --_readers == 0) {
        gone = _onLastReaderGone;
    }
    [_condition unlock];
    if (gone) {
        gone();
    }
}

- (NSUInteger)readerCount {
    [_condition lock];
    NSUInteger readers = _readers;
    [_condition unlock];
    return readers;
}

- (dispatch_block_t)onLastReaderGone {
    [_condition lock];
    dispatch_block_t gone = _onLastReaderGone;
    [_condition unlock];
    return gone;
}

- (void)setOnLastReaderGone:(dispatch_block_t)onLastReaderGone {
    dispatch_block_t copied = [onLastReaderGone copy];
    [_condition lock];
    _onLastReaderGone = copied;
    [_condition unlock];
}

@end

@interface CloudFileMaterializationToken ()
@property (nonatomic, getter=isCancelled) BOOL cancelled;
- (instancetype)initForMaterializer;
@end

@implementation CloudFileMaterializationToken

- (instancetype)initForMaterializer {
    return [super init];
}

@end

@implementation CloudFileMaterializer {
    // Set before dispatch, so a cancel before entry lands.
    CloudFileMaterializationToken *_token;
    // What -cancel, callable from any thread, runs: the coordinator's cancel,
    // the remote backend's, or the fake transfer's signal.
    dispatch_block_t  _cancelTransfer;
    os_unfair_lock    _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (CloudFileMaterializationToken *)prepareMaterialization {
    CloudFileMaterializationToken *token = [[CloudFileMaterializationToken alloc] initForMaterializer];

    os_unfair_lock_lock(&_lock);
    CloudFileMaterializationToken *oldToken = _token;
    oldToken.cancelled = YES;
    dispatch_block_t cancelTransfer = _cancelTransfer;
    _cancelTransfer = nil;
    _token = token;
    os_unfair_lock_unlock(&_lock);

    if (cancelTransfer) {
        cancelTransfer();
    }
    return token;
}

// The transfer's cancel, installed while token is current; NO when a cancel
// already came, and the caller then cancels the transfer itself.
- (BOOL)installCancelTransfer:(dispatch_block_t)cancel token:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _cancelTransfer = [cancel copy];
    }
    os_unfair_lock_unlock(&_lock);
    return current;
}

- (void)finishTransferForToken:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    if (_token == token) {
        _token = nil;
        _cancelTransfer = nil;
    }
    os_unfair_lock_unlock(&_lock);
}

static NSError *VibeMaterializationCancelledError(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

+ (void)setRemoteRoot:(NSURL *)root fetch:(CloudFileRemoteFetch)fetch read:(CloudFileRemoteRead)read
         availability:(CloudFileRemoteAvailability)availability {
    NSParameterAssert((root == nil) == (fetch == nil) && (fetch == nil) == (read == nil) && (root || !availability));
    os_unfair_lock_lock(&sRemoteLock);
    sRemoteFetch = [fetch copy];
    sRemoteRead = [read copy];
    sRemoteAvailability = [availability copy];
    os_unfair_lock_unlock(&sRemoteLock);
    [NSURLUtil setRemotePlaceholderRoot:root];
}

+ (CloudFileAvailability *)availabilityForURL:(NSURL *)url {
    os_unfair_lock_lock(&sRemoteLock);
    CloudFileRemoteAvailability availability = sRemoteAvailability;
    os_unfair_lock_unlock(&sRemoteLock);
    return availability ? availability(url) : nil;
}

+ (CloudFileRemoteRead)remoteRead {
    os_unfair_lock_lock(&sRemoteLock);
    CloudFileRemoteRead read = sRemoteRead;
    os_unfair_lock_unlock(&sRemoteLock);
    return read;
}

// A cancel that wins this lock fails the call; a later one finds no work.
- (BOOL)consumeLocalToken:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    if (current) {
        _token = nil;
    }
    os_unfair_lock_unlock(&_lock);
    return current;
}

#if DEBUG

+ (void)setFakeTransferProvider:(NSTimeInterval (^)(NSURL *url, NSString *role))secondsForURL
                    acquireSlot:(BOOL (^)(NSURL *url, NSString *role, BOOL (^cancelled)(void)))acquireSlot
                    releaseSlot:(void (^)(NSURL *url, NSString *role))releaseSlot
                      didFinish:(void (^)(NSURL *url, NSString *role, BOOL completed))didFinish {
    os_unfair_lock_lock(&sFakeLock);
    sFakeTransferSeconds = [secondsForURL copy];
    sFakeAcquireSlot = [acquireSlot copy];
    sFakeReleaseSlot = [releaseSlot copy];
    sFakeTransferDidFinish = [didFinish copy];
    os_unfair_lock_unlock(&sFakeLock);
}

- (BOOL)tokenIsCancelled:(CloudFileMaterializationToken *)token {
    os_unfair_lock_lock(&_lock);
    BOOL cancelled = (_token != token || token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    return cancelled;
}

// NO the moment -cancel signals. The token is checked as the semaphore is
// installed, covering a cancel before entry as well as during the wait.
- (BOOL)waitOutFakeTransfer:(NSTimeInterval)seconds
                       token:(CloudFileMaterializationToken *)token
                       error:(NSError *__autoreleasing *)error {
    dispatch_semaphore_t wait = dispatch_semaphore_create(0);
    BOOL current = [self installCancelTransfer:^{
        dispatch_semaphore_signal(wait);
    } token:token];

    if (!current) {
        if (error) {
            *error = VibeMaterializationCancelledError();
        }
        return NO;
    }

    BOOL cancelled = dispatch_semaphore_wait(wait,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) == 0;
    [self finishTransferForToken:token];

    if (cancelled && error) {
        *error = VibeMaterializationCancelledError();
    }
    return !cancelled;
}

#endif

- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
            onReadable:(dispatch_block_t)onReadable
                 error:(NSError *__autoreleasing *)error {
#if DEBUG
    // Asked ahead of the placeholder probe; the provider answers 0 for a path
    // already transferred, which then takes the real path.
    NSTimeInterval (^fakeSeconds)(NSURL *, NSString *) = nil;
    BOOL (^acquireSlot)(NSURL *, NSString *, BOOL (^)(void)) = nil;
    void (^releaseSlot)(NSURL *, NSString *) = nil;
    void (^didFinish)(NSURL *, NSString *, BOOL) = nil;
    VibeFakeTransferHooks(&fakeSeconds, &acquireSlot, &releaseSlot, &didFinish);
    NSString *role = self.label ?: @"unlabeled";
    NSTimeInterval fake = fakeSeconds ? fakeSeconds(url, role) : 0;
    // Negative: run for the magnitude, then fail, as a provider error does.
    BOOL fakeFails = fake < 0;
    fake = fabs(fake);
    if (fake > 0) {
        // The provider slot first, cancellable while queued, then the
        // transfer. A cancel leaves the file a placeholder, as a real one does.
        BOOL admitted = YES;
        if (acquireSlot) {
            __weak CloudFileMaterializer *weakSelf = self;
            admitted = acquireSlot(url, role, ^BOOL{
                CloudFileMaterializer *strongSelf = weakSelf;
                return !strongSelf || [strongSelf tokenIsCancelled:token];
            });
        }
        BOOL completed = admitted && [self waitOutFakeTransfer:fake token:token error:error];
        if (admitted && releaseSlot) {
            releaseSlot(url, role);
        }
        if (!admitted && error) {
            *error = VibeMaterializationCancelledError();
        }
        if (completed && fakeFails && error) {
            *error = [NSError errorWithDomain:@"com.vibe.fake-cloud"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                             @"Fake provider transfer failed"}];
        }
        if (didFinish) {
            didFinish(url, role, completed && !fakeFails);
        }
        return completed && !fakeFails;
    }
#endif

    // Inside the prepared call, so no caller bypasses it and strands its token.
    if (![NSURLUtil isDatalessFile:url]) {
        BOOL current = [self consumeLocalToken:token];
        if (!current && error) {
            *error = VibeMaterializationCancelledError();
        }
        return current;
    }

    if ([NSURLUtil isRemotePlaceholderFile:url]) {
        return [self fetchRemoteURL:url token:token onReadable:onReadable error:error];
    }

    // Fresh per download: cancelling poisons a coordinator for good.
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    if (![self installCancelTransfer:^{ [coordinator cancel]; } token:token]) {
        [coordinator cancel];
        if (error) {
            *error = VibeMaterializationCancelledError();
        }
        return NO;
    }

    __block BOOL materialized = NO;
    NSError *coordinationError = nil;
    // Options 0: a plain coordinated read is what asks for the contents;
    // ImmediatelyAvailableMetadataOnly would ask for the opposite.
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordinationError
                                byAccessor:^(NSURL *readURL) {
        // TRAP: a cancel can land while the accessor runs, and cannot stop it,
        // so it only records that the bytes are here; the caller opens the
        // file after coordination ends.
        materialized = YES;
    }];
    [self finishTransferForToken:token];

    if (!materialized && error) {
        *error = coordinationError ?: VibeMaterializationCancelledError();
    }
    return materialized;
}

- (BOOL)fetchRemoteURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
            onReadable:(dispatch_block_t)onReadable
                 error:(NSError *__autoreleasing *)error {
    CloudFileRemoteFetch fetch = VibeRemoteFetch();
    os_unfair_lock_lock(&_lock);
    BOOL current = (_token == token && !token.isCancelled);
    os_unfair_lock_unlock(&_lock);
    if (!current || !fetch) {
        if (error) {
            *error = current ? [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]
                             : VibeMaterializationCancelledError();
        }
        return NO;
    }

    __weak CloudFileMaterializer *weakSelf = self;
    NSError *fetchError = nil;
    BOOL fetched = fetch(url, onReadable, ^(dispatch_block_t cancel) {
        if (![weakSelf installCancelTransfer:cancel token:token]) {
            cancel();
        }
    }, &fetchError);

    os_unfair_lock_lock(&_lock);
    BOOL cancelled = token.isCancelled;
    os_unfair_lock_unlock(&_lock);
    [self finishTransferForToken:token];

    if (!fetched && error) {
        *error = cancelled ? VibeMaterializationCancelledError() : fetchError;
    }
    return fetched && !cancelled;
}

- (void)cancel {
    os_unfair_lock_lock(&_lock);
    _token.cancelled = YES;
    _token = nil;
    dispatch_block_t cancelTransfer = _cancelTransfer;
    _cancelTransfer = nil;
    os_unfair_lock_unlock(&_lock);
    if (cancelTransfer) {
        cancelTransfer();
    }
}

@end
