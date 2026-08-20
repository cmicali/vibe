//
//  AudioFileOpenCoordinator.m
//  Vibe
//

#import "AudioFileOpenCoordinator.h"
#import "AudioFileOpenCoordinatorInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileOpenRules.h"
#import "AudioWorkScheduler.h"
#import "NSURL+AudioOpen.h"
#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

@class VibeAudioFileOpenClaim;

NSString * const VibeAudioFileOpenErrorDomain = @"com.vibe.audio-file-open";

static const NSTimeInterval kInteractiveAdmissionGraceSeconds = 5.0;
static const NSTimeInterval kBackgroundAdmissionGraceSeconds = 10.0;

@interface AudioFileOpenToken ()
- (instancetype)initWithCoordinator:(AudioFileOpenCoordinator *)coordinator
                                  key:(NSString *)key
                      completionQueue:(dispatch_queue_t)completionQueue
                           completion:(VibeAudioFileOpenCompletion)completion;
@property (nonatomic, weak) AudioFileOpenCoordinator *coordinator;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
- (nullable VibeAudioFileOpenCompletion)takeCompletionForDelivery;
- (BOOL)deliveryStillWaiting;
@end

@interface VibeAudioFileOpenClaim : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) VibeAudioFileOpenPurpose purpose;
@property (nonatomic, strong, nullable) AudioFileOpenToken *waiter;
@property (nonatomic, strong, nullable) AudioFileMaterializationRequestToken *materializationToken;
@property (nonatomic, strong, nullable) AudioWorkToken *workToken;
@property (nonatomic) uint64_t runGeneration;
@property (nonatomic) BOOL runWasCancelled;
@property (nonatomic) CFAbsoluteTime submittedAt;
@end

@implementation VibeAudioFileOpenClaim
@end

@interface AudioFileOpenCoordinator ()
- (void)detachToken:(AudioFileOpenToken *)token;
@end

@implementation AudioFileOpenToken {
    os_unfair_lock _deliveryLock;
    VibeAudioFileOpenDeliveryState _deliveryState;
    VibeAudioFileOpenCompletion _completion;
}

- (instancetype)initWithCoordinator:(AudioFileOpenCoordinator *)coordinator
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
    [self.coordinator detachToken:self];
}

// Whether a cancel has not yet detached this token. openURL's state-queue
// block reads it so a token cancelled between creation and installation never
// installs a claim.
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

@implementation AudioFileOpenCoordinator {
    dispatch_queue_t _stateQueue;
    NSMutableDictionary<NSString *, VibeAudioFileOpenClaim *> *_claims;
    AudioWorkScheduler *_playbackScheduler;
    AudioWorkScheduler *_backgroundScheduler;
    AudioFileMaterializationCoordinator *_materializationCoordinator;
    VibeAudioFileOpener _fileOpener;
}

+ (instancetype)sharedCoordinator {
    static AudioFileOpenCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [[self alloc] init];
    });
    return coordinator;
}

- (instancetype)init {
    AudioWorkScheduler *playbackScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.audiofileopen.playback"
                qualityOfService:QOS_CLASS_USER_INITIATED
                maximumRunningCount:2
                maximumPendingCount:1
                pendingGrace:kInteractiveAdmissionGraceSeconds];
    AudioWorkScheduler *backgroundScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.audiofileopen.background"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:2
                maximumPendingCount:2
                pendingGrace:kBackgroundAdmissionGraceSeconds];
    return [self initWithStateQueue:dispatch_queue_create(
            "com.vibe.audiofileopen.state", DISPATCH_QUEUE_SERIAL)
                    playbackScheduler:playbackScheduler
                  backgroundScheduler:backgroundScheduler
           materializationCoordinator:
                   [AudioFileMaterializationCoordinator sharedCoordinator]];
}

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler {
    return [self initWithStateQueue:stateQueue
                 playbackScheduler:playbackScheduler
               backgroundScheduler:backgroundScheduler
        materializationCoordinator:
                [AudioFileMaterializationCoordinator sharedCoordinator]];
}

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler
         materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator {
    return [self initWithStateQueue:stateQueue
                 playbackScheduler:playbackScheduler
               backgroundScheduler:backgroundScheduler
        materializationCoordinator:materializationCoordinator
                        fileOpener:^AVAudioFile *(NSURL *url, NSError **error) {
        return url.isEmptyOrDirectory
                ? nil : [[AVAudioFile alloc] initForReading:url error:error];
    }];
}

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler
         materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator
                         fileOpener:(VibeAudioFileOpener)fileOpener {
    NSParameterAssert(stateQueue);
    NSParameterAssert(playbackScheduler);
    NSParameterAssert(backgroundScheduler);
    NSParameterAssert(materializationCoordinator);
    NSParameterAssert(fileOpener);
    self = [super init];
    if (self) {
        _stateQueue = stateQueue;
        _claims = [NSMutableDictionary dictionary];
        // Separate fixed-slot schedulers are the starvation boundary.
        // Background readahead can occupy every one of its workers without
        // delaying a user-requested play. Pending blocks remain app-owned and
        // capped; they are never pre-dispatched behind a worker which may not
        // return.
        _playbackScheduler = playbackScheduler;
        _backgroundScheduler = backgroundScheduler;
        _materializationCoordinator = materializationCoordinator;
        _fileOpener = [fileOpener copy];
    }
    return self;
}

- (NSString *)keyForURL:(NSURL *)url purpose:(VibeAudioFileOpenPurpose)purpose {
    return [NSString stringWithFormat:@"%ld:%@", (long)purpose,
            VibeStandardizedAudioOpenPath(url)];
}

- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                      completion:(VibeAudioFileOpenCompletion)completion {
    NSString *key = [self keyForURL:url purpose:purpose];
    AudioFileOpenToken *token = [[AudioFileOpenToken alloc] initWithCoordinator:self
            key:key completionQueue:completionQueue completion:completion];
    dispatch_async(_stateQueue, ^{
        if (![token deliveryStillWaiting]) {
            return;
        }
        VibeAudioFileOpenClaim *claim = self->_claims[key];
        BOOL created = NO;
        if (!claim) {
            claim = [[VibeAudioFileOpenClaim alloc] init];
            claim.key = key;
            claim.url = url;
            claim.purpose = purpose;
            self->_claims[key] = claim;
            created = YES;
        }
        claim.waiter = token;
        if (created) {
            [self startClaim:claim];
        }
    });
    return token;
}

- (void)detachToken:(AudioFileOpenToken *)token {
    if (!token) {
        return;
    }
    dispatch_async(_stateQueue, ^{
        VibeAudioFileOpenClaim *claim = self->_claims[token.key];
        if (claim.waiter != token) {
            return; // already rebound, completed, or detached
        }
        claim.waiter = nil;
        // Marked abandoned in the same step that clears the waiter, and never
        // separately: finishClaim: reads this to tell "the run produced nothing
        // because nobody was waiting for it" from "the file genuinely would not
        // open", and a waiter cleared without it would let the former be
        // delivered to a later same-path waiter as a nil file with no error.
        claim.runWasCancelled = YES;
        if (claim.materializationToken) {
            [claim.materializationToken cancel];
            claim.materializationToken = nil;
            [self->_claims removeObjectForKey:claim.key];
            return;
        }
        if ([claim.workToken cancelIfPending]) {
            // This block was still app-owned and has been released without
            // ever reaching libdispatch. There is no underlying OS call whose
            // standardized-path ownership needs to survive.
            [self->_claims removeObjectForKey:claim.key];
            claim.workToken = nil;
        }
    });
}

- (void)startClaim:(VibeAudioFileOpenClaim *)claim {
    claim.runGeneration++;
    uint64_t runGeneration = claim.runGeneration;
    claim.runWasCancelled = NO;
    claim.submittedAt = CFAbsoluteTimeGetCurrent();
    if (claim.purpose == VibeAudioFileOpenPurposeGapless) {
        [self scheduleAudioFileOpenForClaim:claim runGeneration:runGeneration];
        return;
    }

    VibeAudioFileMaterializationRole role = claim.purpose
            == VibeAudioFileOpenPurposePlayback
            ? VibeAudioFileMaterializationRolePlayback
            : VibeAudioFileMaterializationRolePrefetch;
    __weak AudioFileOpenCoordinator *weakSelf = self;
    claim.materializationToken = [_materializationCoordinator
            materializeURL:claim.url
                     role:role
          completionQueue:_stateQueue
               completion:^(VibeAudioFileMaterializationResult result,
                            NSError *error, NSTimeInterval elapsed) {
        AudioFileOpenCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf materializationSettledForClaim:claim runGeneration:runGeneration
                                                result:result error:error];
        }
    }];
}

- (NSError *)openErrorForMaterializationResult:(VibeAudioFileMaterializationResult)result
                                     underlying:(NSError *)underlying {
    VibeAudioFileOpenErrorCode code;
    NSString *description;
    switch (result) {
        case VibeAudioFileMaterializationResultAdmissionExhausted:
            code = VibeAudioFileOpenErrorAdmissionExhausted;
            description = @"Audio materialization capacity was exhausted";
            break;
        case VibeAudioFileMaterializationResultYielded:
            code = VibeAudioFileOpenErrorMaterializationYielded;
            description = @"Audio materialization yielded before opening the file";
            break;
        case VibeAudioFileMaterializationResultFailed:
            code = VibeAudioFileOpenErrorMaterializationFailed;
            description = @"Audio materialization failed before opening the file";
            break;
        case VibeAudioFileMaterializationResultReady:
            return nil;
    }
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: description} mutableCopy];
    if (underlying) {
        userInfo[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                               code:code userInfo:userInfo];
}

- (void)materializationSettledForClaim:(VibeAudioFileOpenClaim *)claim
                          runGeneration:(uint64_t)runGeneration
                                 result:(VibeAudioFileMaterializationResult)result
                                  error:(NSError *)error {
    VibeAudioFileOpenClaim *current = _claims[claim.key];
    if (current != claim || current.runGeneration != runGeneration) {
        return;
    }
    current.materializationToken = nil;
    if (result == VibeAudioFileMaterializationResultReady) {
        [self scheduleAudioFileOpenForClaim:current runGeneration:runGeneration];
        return;
    }
    NSError *reported = [self openErrorForMaterializationResult:result underlying:error];
    NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - current.submittedAt;
    [self finishClaim:current runGeneration:runGeneration file:nil error:reported elapsed:elapsed];
}

- (void)scheduleAudioFileOpenForClaim:(VibeAudioFileOpenClaim *)claim
                         runGeneration:(uint64_t)runGeneration {

    AudioWorkScheduler *scheduler = claim.purpose == VibeAudioFileOpenPurposePlayback
            ? _playbackScheduler : _backgroundScheduler;
    __weak AudioFileOpenCoordinator *weakSelf = self;
    claim.workToken = [scheduler submitWork:^{
        AudioFileOpenCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        __block BOOL hasWaiter = NO;
        dispatch_sync(strongSelf->_stateQueue, ^{
            VibeAudioFileOpenClaim *current = strongSelf->_claims[claim.key];
            hasWaiter = current == claim && current.runGeneration == runGeneration
                    && current.waiter != nil;
        });
        if (!hasWaiter) {
            [strongSelf finishClaim:claim runGeneration:runGeneration file:nil error:nil elapsed:0];
            return;
        }

        NSError *error = nil;
        AVAudioFile *file = strongSelf->_fileOpener(claim.url, &error);
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - claim.submittedAt;
        [strongSelf finishClaim:claim runGeneration:runGeneration file:file error:error elapsed:elapsed];
    } failureQueue:_stateQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        AudioFileOpenCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSString *description = failure == VibeAudioWorkAdmissionFailurePendingLimit
                ? @"Audio open capacity has no pending slot"
                : @"Audio open capacity stayed blocked past its admission grace";
        NSError *error = [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                code:VibeAudioFileOpenErrorAdmissionExhausted
                userInfo:@{NSLocalizedDescriptionKey: description}];
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - claim.submittedAt;
        [strongSelf finishClaim:claim runGeneration:runGeneration file:nil error:error elapsed:elapsed];
    }];
}

- (void)finishClaim:(VibeAudioFileOpenClaim *)claim
       runGeneration:(uint64_t)runGeneration
                file:(AVAudioFile *)file
               error:(NSError *)error
             elapsed:(NSTimeInterval)elapsed {
    dispatch_async(_stateQueue, ^{
        VibeAudioFileOpenClaim *current = self->_claims[claim.key];
        if (current != claim || current.runGeneration != runGeneration) {
            return;
        }
        AudioFileOpenToken *waiter = current.waiter;
        // A waiter may have rebound after cancellation but before the aborted
        // materialization returned. Give it a fresh run; never turn the old
        // waiter's cancellation into the new waiter's open failure.
        if (!file && waiter && current.runWasCancelled) {
            current.workToken = nil;
            [self startClaim:current];
            return;
        }
        [self->_claims removeObjectForKey:claim.key];
        current.workToken = nil;
        current.materializationToken = nil;
        if (!waiter) {
            return;
        }
        // A completion is a result, so it always carries one: either a file or
        // a reason there is none. The only way here with neither is the
        // abandoned-run path above being reached with runWasCancelled somehow
        // clear, which detachToken: makes impossible — but a caller reading
        // error.code off nil is a bug the completion contract should not be
        // able to hand out, so the contract is enforced here rather than
        // assumed at every call site.
        NSError *reported = error;
        if (!file && !reported) {
            reported = [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                    code:VibeAudioFileOpenErrorAbandoned
                    userInfo:@{NSLocalizedDescriptionKey:
                            @"The audio file open was abandoned before it produced a result"}];
        }
        dispatch_async(waiter.completionQueue, ^{
            VibeAudioFileOpenCompletion completion = [waiter takeCompletionForDelivery];
            if (completion) {
                completion(file, reported, elapsed);
            }
        });
    });
}

@end
