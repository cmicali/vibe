//
//  AudioFileMaterializationCoordinator+HandleOpen.m
//  Vibe
//

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioFileMaterializationTokens.h"
#import "AudioFileHandle.h"

#import "AudioFileOpenRules.h"
#import "CloudFileMaterializer.h"

#if DEBUG
#import "AudioFileMaterializationCoordinator+Debug.h"
#endif

// One production player with two open sources (playback, prefetch), plus four
// stranded whole-file calls; a streaming or read-ahead open never strands,
// since a cancel ends its waits. Purpose-blind, so saturation can refuse
// playback. A new player, source or multi-flight source means re-deriving it.
static const NSUInteger kMaximumHandleRunCount = 6;

@implementation AudioFileMaterializationCoordinator (HandleOpen)

#pragma mark - Stage 2: purpose-keyed AudioFileHandle opens

static NSString *VibeHandleRunKey(VibeAudioFileOpenPurpose purpose, NSString *path) {
    return [NSString stringWithFormat:@"%ld:%@", (long)purpose, path];
}

- (void)notifyDatalessForRun:(VibeAudioHandleRun *)run {
    AudioFileOpenToken *token = run.waiter;
    dispatch_block_t onDataless = token.onDataless;
    if (!onDataless || !_claims[run.path].dataless) {
        return;
    }
    token.onDataless = nil;
    dispatch_async(token.completionQueue, ^{
        if ([token deliveryStillWaiting]) {
            onDataless();
        }
    });
}

- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                      onDataless:(dispatch_block_t)onDataless
                      completion:(VibeAudioFileOpenCompletion)completion {
    NSParameterAssert(url);
    NSParameterAssert(completionQueue);
    NSParameterAssert(completion);
    NSString *path = VibeStandardizedAudioOpenPath(url);
    NSString *key = VibeHandleRunKey(purpose, path);
    AudioFileOpenToken *token = [[AudioFileOpenToken alloc] initWithCoordinator:self
            key:key completionQueue:completionQueue completion:completion];
    token.onDataless = onDataless;
    dispatch_async(_stateQueue, ^{
        if (![token deliveryStillWaiting]) {
            return;
        }
        VibeAudioHandleRun *run = self->_handleRuns[key];
        if (run) {
            // Rebind; the superseded token never takes delivery.
            [run.waiter cancel];
            run.waiter = token;
            [self notifyDatalessForRun:run];
            return;
        }
        if (self->_handleRuns.count >= kMaximumHandleRunCount) {
            [self countSettledRequest:VibeAudioFileMaterializationResultAdmissionExhausted];
            NSError *error = [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                    code:VibeAudioFileOpenErrorAdmissionExhausted
                    userInfo:@{NSLocalizedDescriptionKey:
                            @"Audio file open capacity was exhausted"}];
            LogWarn(@"Audio file open admission exhausted for %@ (%lu active runs)",
                    url.lastPathComponent, (unsigned long)self->_handleRuns.count);
            dispatch_async(token.completionQueue, ^{
                VibeAudioFileOpenCompletion delivery = [token takeCompletionForDelivery];
                if (delivery) {
                    delivery(nil, error, 0);
                }
            });
            return;
        }
        run = [[VibeAudioHandleRun alloc] init];
        run.key = key;
        run.path = path;
        run.url = url;
        run.purpose = purpose;
        run.waiter = token;
        run.submittedAt = self->_clock();
        self->_handleRuns[key] = run;
        [self startHandleRunStages:run];
        [self notifyDatalessForRun:run];
    });
    return token;
}

- (void)detachOpenToken:(AudioFileOpenToken *)token {
    if (!token) {
        return;
    }
    dispatch_async(_stateQueue, ^{
        VibeAudioHandleRun *run = self->_handleRuns[token.key];
        if (run.waiter != token) {
            return;
        }
        run.waiter = nil;
        // Set with the waiter's removal, never apart: finishHandleRun: tells
        // "nobody was waiting" from "the file would not open" by it.
        run.runWasCancelled = YES;
        if (run.materializationToken) {
            // Still stage 1: nothing uncancellable has begun.
            [run.materializationToken cancel];
            run.materializationToken = nil;
            [self->_handleRuns removeObjectForKey:run.key];
        }
        else {
            // The open keeps its membership until it returns. A streaming
            // open returns at once, since the wake below ends its waits. A
            // read-ahead open returns at its next poll. A whole-file open
            // makes no waits and cannot be stopped.
            run.openInterrupted = YES;
            [[CloudFileMaterializer availabilityForURL:run.url] wakeWaiters];
        }
    });
}

- (void)startHandleRunStages:(VibeAudioHandleRun *)run {
    run.runGeneration++;
    uint64_t runGeneration = run.runGeneration;
    VibeAudioFileMaterializationRole role = run.purpose
            == VibeAudioFileOpenPurposePlayback
            ? VibeAudioFileMaterializationRolePlayback
            : VibeAudioFileMaterializationRolePrefetch;
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    run.materializationToken = [self materializeURL:run.url
                                               role:role
                                    completionQueue:_stateQueue
                                         completion:^(VibeAudioFileMaterializationResult result,
                                                      NSError *error, NSTimeInterval elapsed) {
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf handleRunTransferSettled:run runGeneration:runGeneration
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

- (void)handleRunTransferSettled:(VibeAudioHandleRun *)run
                    runGeneration:(uint64_t)runGeneration
                           result:(VibeAudioFileMaterializationResult)result
                            error:(NSError *)error {
    VibeAudioHandleRun *current = _handleRuns[run.key];
    if (current != run || run.runGeneration != runGeneration) {
        return;
    }
    run.materializationToken = nil;
    if (result == VibeAudioFileMaterializationResultReady) {
        [self dispatchHandleOpenForRun:run runGeneration:runGeneration];
        return;
    }
    NSError *reported = [self openErrorForMaterializationResult:result underlying:error];
    [self finishHandleRun:run runGeneration:runGeneration file:nil error:reported];
}

- (void)dispatchHandleOpenForRun:(VibeAudioHandleRun *)run
                    runGeneration:(uint64_t)runGeneration {
    if (!run.waiter) {
        [self finishHandleRun:run runGeneration:runGeneration file:nil error:nil];
        return;
    }
    dispatch_queue_t workerQueue = run.purpose == VibeAudioFileOpenPurposePlayback
            ? _interactiveWorkerQueue : _backgroundWorkerQueue;
#if DEBUG
    // Paired with the completed increment below, not finishHandleRun:, which
    // also runs for runs that never opened.
    [self countHandleOpenStarted];
#endif
    // Snapshotted on the state queue: the debug channel swaps the opener.
    VibeAudioFileOpener opener = _fileOpener;
    // A holder until the open returns, so the stream is not abandoned before
    // the handle that will hold it exists.
    CloudFileAvailability *stream = _claims[run.path].availability;
    [stream addReader];
    run.openInterrupted = NO;
    BOOL (^interrupted)(void) = ^BOOL{
        return run.openInterrupted;
    };
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    dispatch_async(workerQueue, ^{
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSError *error = nil;
        AudioFileHandle *file = opener(run.url, interrupted, &error);
        // Before the open's hold lets the stream go below.
        [file holdStream];
        dispatch_async(strongSelf->_stateQueue, ^{
#if DEBUG
            [strongSelf countHandleOpenCompleted];
#endif
            // TRAP: first, so a rebound run's restart installs its waiter,
            // which holds the stream, before the open's hold lets it go: the
            // last holder's release reaches this queue behind this turn.
            [strongSelf finishHandleRun:run runGeneration:runGeneration
                                   file:file error:error];
            [stream removeReader];
        });
    });
}

- (void)finishHandleRun:(VibeAudioHandleRun *)run
           runGeneration:(uint64_t)runGeneration
                    file:(AudioFileHandle *)file
                   error:(NSError *)error {
    VibeAudioHandleRun *current = _handleRuns[run.key];
    if (current != run || run.runGeneration != runGeneration) {
        return;
    }
    AudioFileOpenToken *waiter = run.waiter;
    // A waiter rebound after a cancellation gets a fresh run, never the
    // abandoned run's empty result.
    if (!file && waiter && run.runWasCancelled) {
        run.runWasCancelled = NO;
        [self startHandleRunStages:run];
        return;
    }
    [_handleRuns removeObjectForKey:run.key];
    if (!waiter) {
        return;
    }
    // A completion always carries a file or a reason.
    NSError *reported = error;
    if (!file && !reported) {
        reported = [NSError errorWithDomain:VibeAudioFileOpenErrorDomain
                code:VibeAudioFileOpenErrorAbandoned
                userInfo:@{NSLocalizedDescriptionKey:
                        @"The audio file open was abandoned before it produced a result"}];
    }
    NSTimeInterval elapsed = MAX(0, _clock() - run.submittedAt);
    dispatch_async(waiter.completionQueue, ^{
        VibeAudioFileOpenCompletion completion = [waiter takeCompletionForDelivery];
        if (completion) {
            completion(file, reported, elapsed);
        }
    });
}

@end
