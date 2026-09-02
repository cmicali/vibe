//
//  ArtworkLoadRegistry.m
//  Vibe
//
//  See the header. Requests are registered on main; the blocking read runs on
//  the shared scheduler and the completion hops back to main.
//

#import "ArtworkLoadRegistry.h"
#import "AudioTrackArtworkInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"

static const NSUInteger kArtworkMaterializationMaximumFailures = 3;
static const NSTimeInterval kArtworkAdmissionInitialRetryDelay = 0.1;
static const NSTimeInterval kArtworkAdmissionMaximumRetryDelay = 1.0;

@interface ArtworkLoadRequest : NSObject
@property (nonatomic, strong) AudioTrackArtwork *artwork;
// A snapshot of the artwork's _artGeneration, per the vocabulary rule:
// a mismatch at completion means superseded, drop it.
@property (nonatomic) NSUInteger artGeneration;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) BOOL (^stillWanted)(void);
@property (nonatomic, copy) void (^completion)(VibeImage * _Nullable image);
@property (nonatomic, strong, nullable) NSURL *sourceURL;
@property (atomic) BOOL stale;
@property (nonatomic) BOOL workSubmitted;
@property (nonatomic) NSUInteger materializationFailureCount;
@property (nonatomic) NSUInteger admissionRetryStep;
@property (nonatomic, strong, nullable) AudioFileMaterializationRequestToken *materializationToken;
@property (nonatomic, strong, nullable) AudioWorkToken *workToken;
@end

@implementation ArtworkLoadRequest
@end

@interface ArtworkLoadRegistry ()
@property (nonatomic, strong) AudioFileMaterializationCoordinator *materializationCoordinator;
@property (nonatomic, strong) AudioWorkScheduler *workScheduler;
@property (nonatomic, strong) NSMutableArray<ArtworkLoadRequest *> *requests;
- (void)beginRequest:(ArtworkLoadRequest *)request;
- (void)materializeSourceForRequest:(ArtworkLoadRequest *)request;
- (void)scheduleAdmissionRetryForRequest:(ArtworkLoadRequest *)request;
- (BOOL)requestIsMoot:(ArtworkLoadRequest *)request;
@end

@implementation ArtworkLoadRegistry

- (instancetype)initWithMaterializationCoordinator:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                                      workScheduler:(AudioWorkScheduler *)workScheduler {
    NSParameterAssert(materializationCoordinator);
    NSParameterAssert(workScheduler);
    self = [super init];
    if (self) {
        _materializationCoordinator = materializationCoordinator;
        _workScheduler = workScheduler;
        _requests = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)registeredRequestCount {
    NSParameterAssert(NSThread.isMainThread);
    return _requests.count;
}

- (BOOL)containsRequest:(ArtworkLoadRequest *)request {
    return [_requests indexOfObjectIdenticalTo:request] != NSNotFound;
}

- (void)detachRequest:(ArtworkLoadRequest *)request {
    NSUInteger index = [_requests indexOfObjectIdenticalTo:request];
    if (index != NSNotFound) {
        [_requests removeObjectAtIndex:index];
    }
    request.materializationToken = nil;
    request.workToken = nil;
}

- (void)cancelRequest:(ArtworkLoadRequest *)request {
    if (![self containsRequest:request]) {
        return;
    }
    request.stale = YES;
    if (request.materializationToken) {
        [request.materializationToken cancel];
        [self detachRequest:request];
        return;
    }
    if (!request.workSubmitted || [request.workToken cancelIfPending]) {
        [self detachRequest:request];
    }
    // A running read remains registered until it returns. It keeps one of the
    // seven global entries and one scheduler slot, so repeated demotions cannot
    // grow an orphaned tail behind an uncancellable provider read.
}

// Cancelled, demoted, or no longer wanted: this request's answer must not
// reach its artwork or its completion.
- (BOOL)requestIsMoot:(ArtworkLoadRequest *)request {
    return request.stale ||
            ![request.artwork isGenerationCurrent:request.artGeneration] ||
            !request.stillWanted();
}

// Deliberately narrower than requestIsMoot:: a stale request is already being
// torn down, and a demoted-but-wanted one must reach finishRequest:'s retry
// tail rather than be cancelled here.
- (void)pruneUnwantedRequests {
    for (ArtworkLoadRequest *request in [_requests copy]) {
        if (request.stale || request.stillWanted()) {
            continue;
        }
        [request.artwork invalidateDecodedArtForGeneration:request.artGeneration];
        [self cancelRequest:request];
    }
}

- (void)loadArtwork:(AudioTrackArtwork *)artwork
               label:(NSString *)label
         stillWanted:(BOOL (^)(void))stillWanted
           completion:(void (^)(VibeImage *))completion {
    NSParameterAssert(NSThread.isMainThread);
    [self pruneUnwantedRequests];
    if (!stillWanted()) {
        return;
    }
    // At capacity the request is simply dropped — BEFORE prepare, so the row
    // never carries a pending mark for work that was never registered and the
    // next redraw or thumbnail notification re-requests it cleanly. The
    // scheduler's own pending queue is the only park (spec J6): the third
    // parking layer that used to wait here defended a seven-surface pileup
    // the app cannot produce.
    if (_requests.count >= kArtworkLoadMaximumActiveCount) {
        return;
    }

    NSUInteger generation = 0;
    NSURL *sourceURL = nil;
    if (![artwork prepareAsyncLoadReturningGeneration:&generation sourceURL:&sourceURL]) {
        return;
    }

    ArtworkLoadRequest *request = [ArtworkLoadRequest new];
    request.artwork = artwork;
    request.artGeneration = generation;
    request.label = label ?: @"?";
    request.stillWanted = stillWanted;
    request.completion = completion;
    request.sourceURL = sourceURL;
    [_requests addObject:request];

    [self beginRequest:request];
}

- (void)beginRequest:(ArtworkLoadRequest *)request {
    if (!request.sourceURL) {
        [self submitWorkForRequest:request];
        return;
    }

    [self materializeSourceForRequest:request];
}

- (void)materializeSourceForRequest:(ArtworkLoadRequest *)request {
    NSURL *sourceURL = request.sourceURL;
    if (!sourceURL || ![self containsRequest:request]) {
        return;
    }

    __weak ArtworkLoadRegistry *weakSelf = self;
    request.materializationToken = [_materializationCoordinator
            materializeURL:sourceURL
            role:VibeAudioFileMaterializationRoleMetadataPriority
            completionQueue:dispatch_get_main_queue()
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        ArtworkLoadRegistry *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf containsRequest:request]) {
            return;
        }
        request.materializationToken = nil;
        if ([strongSelf requestIsMoot:request]) {
            [strongSelf finishRequest:request image:nil];
            return;
        }
        switch (result) {
            case VibeAudioFileMaterializationResultReady:
                request.materializationFailureCount = 0;
                [strongSelf submitWorkForRequest:request];
                return;
            case VibeAudioFileMaterializationResultYielded:
                // A foreground hold is not a file failure. Keep this request
                // admitted and retry at a capped rate until the hold releases.
                [strongSelf scheduleAdmissionRetryForRequest:request];
                return;
            case VibeAudioFileMaterializationResultAdmissionExhausted:
                // Capacity pressure says nothing about this file. Keep the one
                // wanted request admitted and retry it at the same bounded rate
                // as a foreground yield.
                [strongSelf scheduleAdmissionRetryForRequest:request];
                return;
            case VibeAudioFileMaterializationResultFailed:
                request.materializationFailureCount++;
                if (request.materializationFailureCount <
                        kArtworkMaterializationMaximumFailures) {
                    [strongSelf scheduleAdmissionRetryForRequest:request];
                }
                else {
                    [strongSelf finishRequest:request image:nil];
                }
                return;
        }
    }];
}

- (void)scheduleAdmissionRetryForRequest:(ArtworkLoadRequest *)request {
    if (![self containsRequest:request]) {
        return;
    }
    NSUInteger step = MIN(request.admissionRetryStep, 4u);
    request.admissionRetryStep++;
    NSTimeInterval delay = MIN(kArtworkAdmissionInitialRetryDelay * (1u << step),
                               kArtworkAdmissionMaximumRetryDelay);
    __weak ArtworkLoadRegistry *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ArtworkLoadRegistry *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf containsRequest:request]) {
            return;
        }
        if ([strongSelf requestIsMoot:request]) {
            [strongSelf finishRequest:request image:nil];
            return;
        }
        [strongSelf beginRequest:request];
    });
}

- (void)submitWorkForRequest:(ArtworkLoadRequest *)request {
    if (![self containsRequest:request]) {
        return;
    }
    request.workSubmitted = YES;
    BOOL sourceFileReadAllowed = request.sourceURL != nil;
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    __weak ArtworkLoadRegistry *weakSelf = self;
    request.workToken = [_workScheduler submitWork:^{
        VibeImage *image = nil;
        if (!request.stale) {
            image = [request.artwork
                    loadArtBlockingForExpectedGeneration:request.artGeneration
                    sourceFileReadAllowed:sourceFileReadAllowed];
        }
        run_on_main_thread({
            ArtworkLoadRegistry *strongSelf = weakSelf;
            if (strongSelf) {
                LogInfo(@"Art load: %@ for '%@' in %.1fs", image ? @"image" : @"nothing",
                        request.label, CFAbsoluteTimeGetCurrent() - startedAt);
                [strongSelf finishRequest:request image:image];
            }
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        (void)failure;
        ArtworkLoadRegistry *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf containsRequest:request]) {
            return;
        }
        request.workToken = nil;
        request.workSubmitted = NO;
        if ([strongSelf requestIsMoot:request]) {
            [strongSelf finishRequest:request image:nil];
            return;
        }
        // Like central AdmissionExhausted, scheduler rejection is capacity,
        // not an answer about whether the track has art.
        [strongSelf scheduleAdmissionRetryForRequest:request];
    }];
}

- (void)finishRequest:(ArtworkLoadRequest *)request image:(VibeImage *)image {
    NSParameterAssert(NSThread.isMainThread);
    if (![self containsRequest:request]) {
        return;
    }

    AudioTrackArtwork *artwork = request.artwork;
    NSUInteger generation = request.artGeneration;
    BOOL generationCurrent = [artwork isGenerationCurrent:generation];
    BOOL wanted = request.stillWanted();
    NSString *label = request.label;
    BOOL (^stillWanted)(void) = request.stillWanted;
    void (^completion)(VibeImage *) = request.completion;
    BOOL stale = request.stale;
    [self detachRequest:request];

    if (!generationCurrent) {
        // An extraction already in progress kept its single-flight claim across
        // demotion. Its return releases that claim before this retry, so a
        // redisplay can start one fresh read but never overlap the old one.
        if (wanted) {
            [self loadArtwork:artwork label:label stillWanted:stillWanted
                   completion:completion];
        }
        return;
    }

    [artwork clearLoadPendingForGeneration:generation];
    if (!wanted || stale) {
        [artwork invalidateDecodedArtForGeneration:generation];
        return;
    }
    completion(image);
}

- (void)cancelLoadsForArtwork:(AudioTrackArtwork *)artwork {
    NSParameterAssert(NSThread.isMainThread);
    for (ArtworkLoadRequest *request in [_requests copy]) {
        if (request.artwork == artwork) {
            [self cancelRequest:request];
        }
    }
}

@end
