//
//  CloudFileAvailability.m
//  Vibe
//

#import "CloudFileAvailability.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

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
    // transfer's one block lies wholly past _written. A read then never mixes
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
        // TRAP: dropped under the lock a reader copies under. A wait a block
        // answered has then copied before the block can go. A range in it
        // past the download's edge waits for the disk from here.
        NSUInteger passed = 0;
        while (passed < _blocks.count && _blockOffsets[passed].unsignedLongLongValue <= _written) {
            passed++;
        }
        [self removeBlocksAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, passed)]];
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
        [self removeBlocksAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _blocks.count)]];
        [_condition broadcast];
    }
    [_condition unlock];
}

// Under the lock: where the blocks held contiguously from offset end, clipped
// to the size, and in *index, when given, the block holding offset. Offset
// itself, and NSNotFound, when no block holds it.
- (uint64_t)heldEndAt:(uint64_t)offset block:(NSUInteger *)index {
    NSUInteger first = NSNotFound;
    uint64_t end = offset;
    for (NSUInteger i = 0; i < _blocks.count; i++) {
        uint64_t start = _blockOffsets[i].unsignedLongLongValue;
        if (start > end) {
            break;
        }
        uint64_t blockEnd = start + _blocks[i].length;
        if (blockEnd > end) {
            if (first == NSNotFound) {
                first = i;
            }
            end = blockEnd;
        }
    }
    if (index) {
        *index = first;
    }
    return first == NSNotFound ? offset : MIN(end, _size);
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

// Under the lock: each block with its offset.
- (void)removeBlocksAtIndexes:(NSIndexSet *)indexes {
    [_blocks removeObjectsAtIndexes:indexes];
    [_blockOffsets removeObjectsAtIndexes:indexes];
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
    [self removeBlocksAtIndexes:overlapped];
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
    [_condition lock];
    if (!_complete && !_failure && bytes.length > 0 && offset < _size && bytes.length <= _size - offset
            && [self heldEndAt:offset block:NULL] < offset + bytes.length) {
        [self insertBlock:bytes atOffset:offset];
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
    // TRAP: dropped under the lock a reader copies under. A wait a block
    // answered has then copied before the block can go.
    [self removeBlocksAtIndexes:dropped];
    [_condition unlock];
}

- (uint64_t)heldEndAt:(uint64_t)offset {
    [_condition lock];
    uint64_t end = [self heldEndAt:MAX(offset, _written) block:NULL];
    [_condition unlock];
    return end;
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
                fromBlocks = MIN(capacity, held - offset);
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
        if (noPartFile && (_wantedOffset != offset || _wantedLength != last - offset)) {
            _wantedOffset = offset;
            _wantedLength = last - offset;
            wantedRecorded = YES;
            [self signalWriter];
        }
        if (!deadline) {
            [_condition wait];
        }
        else if (![_condition waitUntilDate:deadline]) {
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
        NSMutableData *copy = [NSMutableData dataWithLength:(NSUInteger)MIN(length, held - offset)];
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

- (void)noteReaderPosition:(uint64_t)offset {
    if (_partURL) {
        return;
    }
    [_condition lock];
    _readerPosition = offset;
    [self signalWriter];
    [_condition unlock];
}

- (BOOL)readAheadPaused {
    [_condition lock];
    BOOL paused = _readAheadPaused;
    [_condition unlock];
    return paused;
}

- (void)setReadAheadPaused:(BOOL)readAheadPaused {
    if (_partURL) {
        return;
    }
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
