//
//  AudioFileMaterializationTokens.m
//  Vibe
//

#import "AudioFileMaterializationTokens.h"
#import "AudioFileMaterializationCoordinatorInternal.h"

#import "AudioFileOpenDeliveryRules.h"

#import <os/lock.h>

typedef NS_ENUM(NSUInteger, VibeMaterializationDeliveryState) {
    VibeMaterializationDeliveryWaiting = 0,
    VibeMaterializationDeliveryBegan,
    VibeMaterializationDeliveryDetached,
};

@implementation AudioFileMaterializationRequestToken {
    os_unfair_lock _deliveryLock;
    VibeMaterializationDeliveryState _deliveryState;
    dispatch_queue_t _completionQueue;
    VibeAudioFileMaterializationCompletion _completion;
    BOOL _deliveryRunnerScheduled;
    BOOL _settled;
    VibeAudioFileMaterializationResult _settledResult;
    NSError *_settledError;
    NSTimeInterval _settledElapsed;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                path:(NSString *)path
                          identifier:(uint64_t)identifier
                     completionQueue:(dispatch_queue_t)completionQueue
                          completion:(VibeAudioFileMaterializationCompletion)completion {
    self = [super init];
    if (self) {
        _deliveryLock = OS_UNFAIR_LOCK_INIT;
        _deliveryState = VibeMaterializationDeliveryWaiting;
        _coordinator = coordinator;
        _path = [path copy];
        _identifier = identifier;
        _completionQueue = completionQueue;
        _completion = [completion copy];
    }
    return self;
}

- (void)cancel {
    VibeAudioFileMaterializationCompletion completionToRelease = nil;
    NSError *errorToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting) {
        _deliveryState = VibeMaterializationDeliveryDetached;
        completionToRelease = _completion;
        _completion = nil;
        errorToRelease = _settledError;
        _settledError = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    (void)completionToRelease;
    (void)errorToRelease;
    [self.coordinator detachRequestToken:self];
}

- (BOOL)isDetached {
    os_unfair_lock_lock(&_deliveryLock);
    BOOL detached = _deliveryState == VibeMaterializationDeliveryDetached;
    os_unfair_lock_unlock(&_deliveryLock);
    return detached;
}

- (void)settleWithResult:(VibeAudioFileMaterializationResult)result
                   error:(NSError *)error
                 elapsed:(NSTimeInterval)elapsed {
    BOOL shouldSchedule = NO;
    os_unfair_lock_lock(&_deliveryLock);
    if (_deliveryState == VibeMaterializationDeliveryWaiting && !_settled) {
        _settled = YES;
        _settledResult = result;
        _settledError = error;
        _settledElapsed = elapsed;
        if (!_deliveryRunnerScheduled) {
            _deliveryRunnerScheduled = YES;
            shouldSchedule = YES;
        }
    }
    os_unfair_lock_unlock(&_deliveryLock);
    if (shouldSchedule) {
        dispatch_async(_completionQueue, ^{
            [self runDelivery];
        });
    }
}

// A settle schedules exactly one delivery; a cancel before it runs suppresses it.
- (void)runDelivery {
    VibeAudioFileMaterializationCompletion completion = nil;
    NSError *error = nil;
    VibeAudioFileMaterializationResult result = VibeAudioFileMaterializationResultFailed;
    NSTimeInterval elapsed = 0;
    os_unfair_lock_lock(&_deliveryLock);
    _deliveryRunnerScheduled = NO;
    if (_deliveryState == VibeMaterializationDeliveryWaiting && _settled) {
        _deliveryState = VibeMaterializationDeliveryBegan;
        completion = _completion;
        _completion = nil;
        result = _settledResult;
        error = _settledError;
        _settledError = nil;
        elapsed = _settledElapsed;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    if (completion) {
        completion(result, error, elapsed);
    }
}

@end

@implementation AudioFileOpenToken {
    os_unfair_lock _deliveryLock;
    VibeAudioFileOpenDeliveryState _deliveryState;
    VibeAudioFileOpenCompletion _completion;
}

- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                  key:(NSString *)key
                      completionQueue:(dispatch_queue_t)completionQueue
                           completion:(VibeAudioFileOpenCompletion)completion {
    self = [super init];
    if (self) {
        _deliveryLock = OS_UNFAIR_LOCK_INIT;
        _deliveryState = VibeAudioFileOpenDeliveryWaiting;
        _coordinator = coordinator;
        _key = [key copy];
        _completionQueue = completionQueue;
        _completion = [completion copy];
    }
    return self;
}

- (void)cancel {
    VibeAudioFileOpenCompletion completionToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (VibeAudioFileOpenDetachDelivery(&_deliveryState)) {
        completionToRelease = _completion;
        _completion = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    (void)completionToRelease;
    [self.coordinator detachOpenToken:self];
}

// Read by openURL:'s state-queue block, so a token cancelled before it was
// installed never installs a run.
- (BOOL)deliveryStillWaiting {
    os_unfair_lock_lock(&_deliveryLock);
    BOOL waiting = _deliveryState == VibeAudioFileOpenDeliveryWaiting;
    os_unfair_lock_unlock(&_deliveryLock);
    return waiting;
}

- (VibeAudioFileOpenCompletion)takeCompletionForDelivery {
    VibeAudioFileOpenCompletion completion = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (VibeAudioFileOpenBeginDelivery(&_deliveryState)) {
        completion = _completion;
        _completion = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    return completion;
}

@end
