//
//  AudioFileOpenCoordinator.m
//  Vibe
//

#import "AudioFileOpenCoordinator.h"
#import "AudioFileOpenRules.h"
#import "AudioWorkScheduler.h"
#import "CloudFileMaterializer.h"
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
- (void)markDeliveryDetached;
- (nullable VibeAudioFileOpenCompletion)takeCompletionForDelivery;
@end

@interface VibeAudioFileOpenClaim : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) VibeAudioFileOpenPurpose purpose;
@property (nonatomic, strong, nullable) AudioFileOpenToken *waiter;
@property (nonatomic, strong, nullable) CloudFileMaterializer *materializer;
@property (nonatomic, strong, nullable) CloudFileMaterializationToken *materializationToken;
@property (nonatomic, strong, nullable) AudioWorkToken *workToken;
@property (nonatomic) uint64_t sequence;
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
    [self markDeliveryDetached];
    [self.coordinator detachToken:self];
}

- (void)markDeliveryDetached {
    VibeAudioFileOpenCompletion completionToRelease = nil;
    os_unfair_lock_lock(&_deliveryLock);
    if (VibeAudioFileOpenDetachDelivery(&_deliveryState)) {
        completionToRelease = _completion;
        _completion = nil;
    }
    os_unfair_lock_unlock(&_deliveryLock);
    (void)completionToRelease;
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
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.vibe.audiofileopen.state", DISPATCH_QUEUE_SERIAL);
        _claims = [NSMutableDictionary dictionary];

        // Separate fixed-slot schedulers are the starvation boundary.
        // Background readahead can occupy every one of its workers without
        // delaying a user-requested play. Pending blocks remain app-owned and
        // capped; they are never pre-dispatched behind a worker which may not
        // return.
        _playbackScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.audiofileopen.playback"
                qualityOfService:QOS_CLASS_USER_INITIATED
                maximumRunningCount:2
                maximumPendingCount:1
                pendingGrace:kInteractiveAdmissionGraceSeconds];
        _backgroundScheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.audiofileopen.background"
                qualityOfService:QOS_CLASS_UTILITY
                maximumRunningCount:2
                maximumPendingCount:2
                pendingGrace:kBackgroundAdmissionGraceSeconds];
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
    return [self openURL:url purpose:purpose completionQueue:completionQueue
                 claimed:nil completion:completion];
}

- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                         claimed:(dispatch_block_t)claimed
                      completion:(VibeAudioFileOpenCompletion)completion {
    NSString *key = [self keyForURL:url purpose:purpose];
    AudioFileOpenToken *token = [[AudioFileOpenToken alloc] initWithCoordinator:self
            key:key completionQueue:completionQueue completion:completion];
    dispatch_async(_stateQueue, ^{
        VibeAudioFileOpenClaim *claim = self->_claims[key];
        if (!claim) {
            claim = [[VibeAudioFileOpenClaim alloc] init];
            claim.key = key;
            claim.url = url;
            claim.purpose = purpose;
            claim.waiter = token;
            self->_claims[key] = claim;
            [self startClaim:claim];
        }
        else {
            // Rebinding is the single-flight handoff: the old logical request
            // no longer owns delivery, while the same blocked OS call remains.
            claim.waiter = token;
        }
        // Acknowledged after the register-or-rebind either way: the state
        // queue is serial, so any query issued after this block observes the
        // claim.
        if (claimed) {
            dispatch_async(completionQueue, claimed);
        }
    });
    return token;
}

- (BOOL)isMaterializingURL:(NSURL *)url {
    NSString *path = VibeStandardizedAudioOpenPath(url);
    __block BOOL materializing = NO;
    dispatch_sync(_stateQueue, ^{
        for (VibeAudioFileOpenClaim *claim in self->_claims.objectEnumerator) {
            // Only claims that own a transfer count: a gapless claim opens a
            // second handle on a file the prefetch already made local, so it
            // carries no materializer and moves no bytes.
            if (claim.materializer
                    && [VibeStandardizedAudioOpenPath(claim.url) isEqualToString:path]) {
                materializing = YES;
                return;
            }
        }
    });
    return materializing;
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
        [claim.materializer cancel];
        if ([claim.workToken cancelIfPending]) {
            // This block was still app-owned and has been released without
            // ever reaching libdispatch. There is no underlying OS call whose
            // standardized-path ownership needs to survive.
            [self->_claims removeObjectForKey:claim.key];
            claim.workToken = nil;
            claim.materializer = nil;
            claim.materializationToken = nil;
        }
    });
}

- (void)startClaim:(VibeAudioFileOpenClaim *)claim {
    claim.sequence++;
    uint64_t sequence = claim.sequence;
    claim.runWasCancelled = NO;
    claim.submittedAt = CFAbsoluteTimeGetCurrent();
    BOOL shouldMaterialize = claim.purpose != VibeAudioFileOpenPurposeGapless;
    if (shouldMaterialize) {
        claim.materializer = [[CloudFileMaterializer alloc] init];
        claim.materializer.label = claim.purpose == VibeAudioFileOpenPurposePlayback
                ? @"playback" : @"prefetch";
        claim.materializationToken = [claim.materializer prepareMaterialization];
    }
    else {
        claim.materializer = nil;
        claim.materializationToken = nil;
    }

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
            hasWaiter = current == claim && current.sequence == sequence && current.waiter != nil;
        });
        if (!hasWaiter) {
            [strongSelf finishClaim:claim sequence:sequence file:nil error:nil elapsed:0];
            return;
        }

        NSError *error = nil;
        BOOL materialized = YES;
        if (claim.materializer) {
            materialized = [claim.materializer materializeURL:claim.url
                    token:claim.materializationToken error:&error];
        }
        AVAudioFile *file = (!materialized || claim.url.isEmptyOrDirectory)
                ? nil : [[AVAudioFile alloc] initForReading:claim.url error:&error];
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - claim.submittedAt;
        [strongSelf finishClaim:claim sequence:sequence file:file error:error elapsed:elapsed];
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
        [strongSelf finishClaim:claim sequence:sequence file:nil error:error elapsed:elapsed];
    }];
}

- (void)finishClaim:(VibeAudioFileOpenClaim *)claim
            sequence:(uint64_t)sequence
                file:(AVAudioFile *)file
               error:(NSError *)error
             elapsed:(NSTimeInterval)elapsed {
    dispatch_async(_stateQueue, ^{
        VibeAudioFileOpenClaim *current = self->_claims[claim.key];
        if (current != claim || current.sequence != sequence) {
            return;
        }
        AudioFileOpenToken *waiter = current.waiter;
        // A waiter may have rebound after cancellation but before the aborted
        // materialization returned. Give it a fresh run; never turn the old
        // waiter's cancellation into the new waiter's open failure.
        if (!file && waiter && current.runWasCancelled) {
            [self startClaim:current];
            return;
        }
        [self->_claims removeObjectForKey:claim.key];
        current.workToken = nil;
        current.materializer = nil;
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
