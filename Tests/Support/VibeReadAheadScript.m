#import "VibeReadAheadScript.h"
#import "AudioFileHandle+Debug.h"

#include <unistd.h>

@implementation VibeReadAheadScript {
    NSCondition *_condition;
    // Each read as "<name>@<offset>".
    NSCountedSet<NSString *> *_reads;
    uint64_t _stallFrom, _failFrom, _cutAt;
    NSUInteger _stallPasses;
    int _failCode;
    BOOL _failAlways;
    BOOL _holdFailures;
}

- (instancetype)initForPathsContaining:(NSString *)marker {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _reads = [NSCountedSet set];
        _stalled = dispatch_semaphore_create(0);
        _failed = dispatch_semaphore_create(0);
        _stallFrom = _failFrom = _cutAt = UINT64_MAX;
        [AudioFileHandle debugSetMountRule:^NSNumber *(NSURL *url) {
            return [url.path containsString:marker] ? @YES : nil;
        }];
        // Held by the hook until removeHook.
        VibeReadAheadScript *script = self;
        [AudioFileHandle debugSetBeforeRead:^int(NSURL *url, uint64_t offset, uint64_t length) {
            return [url.path containsString:marker] ? [script beforeReadOf:url.lastPathComponent at:offset] : 0;
        }];
    }
    return self;
}

- (void)releaseEverything {
    [AudioFileHandle debugSetMountRule:nil];
    [self stopFailing];
    [self releaseStalls];
}

+ (void)removeHook {
    [AudioFileHandle debugSetBeforeRead:nil];
}

+ (BOOL)threadsGone {
    return AudioFileHandle.debugOrphanedReadAheads == 0 && AudioFileHandle.debugLiveReadAheads == 0;
}

- (void)stallFrom:(uint64_t)offset {
    [_condition lock];
    _stallFrom = offset;
    [_condition broadcast];
    [_condition unlock];
}

- (void)releaseOneStall {
    [_condition lock];
    _stallPasses++;
    [_condition broadcast];
    [_condition unlock];
}

- (void)releaseStalls {
    [_condition lock];
    _stallFrom = UINT64_MAX;
    _holdFailures = NO;
    [_condition broadcast];
    [_condition unlock];
}

- (void)holdFailures {
    [_condition lock];
    _holdFailures = YES;
    [_condition unlock];
}

- (void)fail:(int)code from:(uint64_t)offset always:(BOOL)always {
    [_condition lock];
    _failCode = code;
    _failFrom = offset;
    _failAlways = always;
    [_condition unlock];
}

- (void)stopFailing {
    [self fail:0 from:UINT64_MAX always:NO];
}

- (void)cutOnceAt:(uint64_t)offset {
    [_condition lock];
    _cutAt = offset;
    [_condition unlock];
}

- (NSUInteger)readsAt:(uint64_t)offset {
    NSString *suffix = [NSString stringWithFormat:@"@%llu", offset];
    [_condition lock];
    NSUInteger reads = 0;
    for (NSString *read in _reads) {
        if ([read hasSuffix:suffix]) {
            reads += [_reads countForObject:read];
        }
    }
    [_condition unlock];
    return reads;
}

- (NSUInteger)readsOf:(NSString *)name at:(uint64_t)offset {
    [_condition lock];
    NSUInteger reads = [_reads countForObject:[NSString stringWithFormat:@"%@@%llu", name, offset]];
    [_condition unlock];
    return reads;
}

- (NSUInteger)reads {
    [_condition lock];
    NSUInteger reads = 0;
    for (NSString *read in _reads) {
        reads += [_reads countForObject:read];
    }
    [_condition unlock];
    return reads;
}

- (int)beforeReadOf:(NSString *)name at:(uint64_t)offset {
    useconds_t throttle = self.throttle;
    if (throttle) {
        usleep(throttle);
    }
    [_condition lock];
    [_reads addObject:[NSString stringWithFormat:@"%@@%llu", name, offset]];
    if (offset >= _stallFrom) {
        dispatch_semaphore_signal(_stalled);
        while (offset >= _stallFrom && _stallPasses == 0) {
            [_condition wait];
        }
        if (offset >= _stallFrom) {
            _stallPasses--;
        }
    }
    int code = 0;
    if (offset >= _failFrom) {
        code = _failCode;
        if (!_failAlways) {
            _failFrom = UINT64_MAX;
        }
    }
    BOOL cut = offset >= _cutAt;
    if (cut) {
        _cutAt = UINT64_MAX;
    }
    if (code) {
        dispatch_semaphore_signal(_failed);
        while (_holdFailures) {
            [_condition wait];
        }
    }
    [_condition unlock];
    return code ?: cut ? -1 : 0;
}

@end
