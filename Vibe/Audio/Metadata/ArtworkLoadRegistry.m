//
//  ArtworkLoadRegistry.m
//  Vibe
//

#import "ArtworkLoadRegistry.h"
#import "AudioTrackArtworkInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"
#import "NSURLUtil.h"

static const NSUInteger kArtworkMaterializationMaximumFailures = 3;
static const NSTimeInterval kArtworkAdmissionInitialRetryDelay = 0.1;
static const NSTimeInterval kArtworkAdmissionMaximumRetryDelay = 1.0;

@interface ArtworkLoadRequest : NSObject
@property (nonatomic, strong) AudioTrackArtwork *artwork;
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
    // A running read stays registered until it returns, holding its entry and
    // slot, so repeated demotions cannot grow a tail behind a stuck read.
}

- (BOOL)requestIsMoot:(ArtworkLoadRequest *)request {
    return request.stale ||
            ![request.artwork isGenerationCurrent:request.artGeneration] ||
            !request.stillWanted();
}

// Narrower than requestIsMoot: a demoted-but-wanted request must reach
// finishRequest:'s retry rather than be cancelled here.
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
    // Dropped before prepare, so the row carries no pending mark and the next
    // redraw re-requests it (J6).
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

// A remote placeholder's art is read by range, as its tags are
// (AudioTrackMetadataLoader's submission): materializing it would download
// the whole song to show its picture. It is still a network read, so it
// waits out the user's open as the tag scan does.
- (void)beginRequest:(ArtworkLoadRequest *)request {
    if (!request.sourceURL) {
        [self submitWorkForRequest:request];
        return;
    }
    if ([NSURLUtil isRemotePlaceholderFile:request.sourceURL]) {
        if ([_materializationCoordinator isForegroundTransferActive]) {
            [self scheduleAdmissionRetryForRequest:request];
        }
        else {
            [self submitWorkForRequest:request];
        }
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
                // Neither says anything about the file: retry, unspent.
                [strongSelf scheduleAdmissionRetryForRequest:request];
                return;
            case VibeAudioFileMaterializationResultAdmissionExhausted:
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
        // Capacity, not an answer about the art.
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
        // A read still running keeps its extraction claim across the
        // demotion, so this retry never overlaps it.
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
