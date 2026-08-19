//
// AudioTrackArtwork.m
// Vibe
//
// One row's embedded-art state plus the private bounded async registry. All
// per-row transitions use the artwork monitor; no monitor spans I/O or decode.
//

#import "AudioTrackArtworkInternal.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

// Three consecutive read failures end the current display attempt rather than
// letting updateUI dispatch forever. discardDecodedArt re-arms them when the
// track leaves the header, so a later visit can recover after the file or its
// provider becomes readable again.
static const NSUInteger kMaxEmbeddedArtExtractionFailures = 3;

// And how long after a failed read the next attempt may start. The count alone
// bounded how many reads a bad file cost but not how fast they were spent:
// updateUI runs several times in quick succession at a track start (begin
// loading, start playing, metadata, art), so all three attempts went back to
// back, each blocking a user-initiated worker for however long the failing read
// takes — and nothing about an unreachable provider changes between two calls
// milliseconds apart. The delay is what makes the second and third attempts
// worth making. It is not a poll: nothing schedules a retry, it only decides
// whether the next pass that asks is allowed to try.
static const NSTimeInterval kEmbeddedArtExtractionRetryBackoff = 2.0;

static const NSUInteger kArtworkLoadMaximumRunningCount = 2;
static const NSUInteger kArtworkLoadMaximumPendingCount = 5;
static const NSUInteger kArtworkLoadMaximumActiveCount =
        kArtworkLoadMaximumRunningCount + kArtworkLoadMaximumPendingCount;
static const NSUInteger kArtworkLoadMaximumWaitingCount = 7;
static const NSTimeInterval kArtworkLoadPendingGrace = 30;
static const NSUInteger kArtworkMaterializationMaximumFailures = 3;
static const NSTimeInterval kArtworkAdmissionInitialRetryDelay = 0.1;
static const NSTimeInterval kArtworkAdmissionMaximumRetryDelay = 1.0;

@interface ArtworkLoadRequest : NSObject
@property (nonatomic, strong) AudioTrackArtwork *artwork;
@property (nonatomic) NSUInteger generation;
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

@interface AudioTrackArtwork ()
@property (nonatomic, strong, nullable) FolderArtResolver *folderArt;
@property (nonatomic, copy, nullable) AudioTrackArtworkClock clock;
@property (nullable, readonly, copy) NSString *sourceFilePath;
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed;
- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL * _Nullable * _Nonnull)sourceURL;
- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)clearLoadPendingForGeneration:(NSUInteger)generation;
- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation;
- (void)discardDecodedArtStateLocked;
@end

@interface ArtworkLoadRegistry : NSObject
- (instancetype)initWithMaterializationCoordinator:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                                      workScheduler:(AudioWorkScheduler *)workScheduler;
- (void)loadArtwork:(AudioTrackArtwork *)artwork
               label:(nullable NSString *)label
         stillWanted:(BOOL (^)(void))stillWanted
           completion:(void (^)(VibeImage * _Nullable image))completion;
- (void)cancelLoadsForArtwork:(AudioTrackArtwork *)artwork;
@property (nonatomic, readonly) NSUInteger registeredRequestCount;
@end

@interface ArtworkLoadRegistry ()
@property (nonatomic, strong) AudioFileMaterializationCoordinator *materializationCoordinator;
@property (nonatomic, strong) AudioWorkScheduler *workScheduler;
@property (nonatomic, strong) NSMutableArray<ArtworkLoadRequest *> *requests;
@property (nonatomic, strong) NSMutableArray<ArtworkLoadRequest *> *waitingRequests;
- (void)beginRequest:(ArtworkLoadRequest *)request;
- (void)materializeSourceForRequest:(ArtworkLoadRequest *)request;
- (void)scheduleAdmissionRetryForRequest:(ArtworkLoadRequest *)request;
- (void)admitWaitingRequestIfPossible;
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
        _waitingRequests = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)registeredRequestCount {
    NSParameterAssert(NSThread.isMainThread);
    return _requests.count + _waitingRequests.count;
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
        [self admitWaitingRequestIfPossible];
        return;
    }
    if (!request.workSubmitted || [request.workToken cancelIfPending]) {
        [self detachRequest:request];
        [self admitWaitingRequestIfPossible];
    }
    // A running read remains registered until it returns. It keeps one of the
    // seven global entries and one scheduler slot, so repeated demotions cannot
    // grow an orphaned tail behind an uncancellable provider read.
}

- (void)pruneUnwantedRequests {
    for (ArtworkLoadRequest *waiting in [_waitingRequests copy]) {
        if (waiting.stale || waiting.stillWanted()) {
            continue;
        }
        [_waitingRequests removeObjectIdenticalTo:waiting];
        [waiting.artwork invalidateDecodedArtForGeneration:waiting.generation];
    }
    for (ArtworkLoadRequest *request in [_requests copy]) {
        if (request.stale || request.stillWanted()) {
            continue;
        }
        [request.artwork invalidateDecodedArtForGeneration:request.generation];
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
    for (ArtworkLoadRequest *waiting in _waitingRequests) {
        if (waiting.artwork == artwork) {
            return;
        }
    }
    if (_requests.count >= kArtworkLoadMaximumActiveCount &&
            _waitingRequests.count >= kArtworkLoadMaximumWaitingCount) {
        return;
    }

    NSUInteger generation = 0;
    NSURL *sourceURL = nil;
    if (![artwork prepareAsyncLoadReturningGeneration:&generation sourceURL:&sourceURL]) {
        return;
    }

    ArtworkLoadRequest *request = [ArtworkLoadRequest new];
    request.artwork = artwork;
    request.generation = generation;
    request.label = label ?: @"?";
    request.stillWanted = stillWanted;
    request.completion = completion;
    request.sourceURL = sourceURL;
    if (_requests.count >= kArtworkLoadMaximumActiveCount) {
        // Pager shifts can expose new edges while uncancellable stale reads
        // still occupy slots. Keep at most one desired request per artwork and
        // no more than a full seven-artwork window outside the active-work bound.
        [_waitingRequests addObject:request];
        return;
    }
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
            registered:nil
            completion:^(VibeAudioFileMaterializationResult result, NSError *error,
                         NSTimeInterval elapsed) {
        ArtworkLoadRegistry *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf containsRequest:request]) {
            return;
        }
        request.materializationToken = nil;
        if (request.stale ||
                ![request.artwork isGenerationCurrent:request.generation] ||
                !request.stillWanted()) {
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
        if (request.stale ||
                ![request.artwork isGenerationCurrent:request.generation] ||
                !request.stillWanted()) {
            [strongSelf finishRequest:request image:nil];
            return;
        }
        [strongSelf beginRequest:request];
    });
}

- (void)admitWaitingRequestIfPossible {
    while (_requests.count < kArtworkLoadMaximumActiveCount &&
            _waitingRequests.count > 0) {
        ArtworkLoadRequest *request = _waitingRequests.firstObject;
        [_waitingRequests removeObjectAtIndex:0];
        if (request.stale ||
                ![request.artwork isGenerationCurrent:request.generation] ||
                !request.stillWanted()) {
            [request.artwork invalidateDecodedArtForGeneration:request.generation];
            continue;
        }
        [_requests addObject:request];
        [self beginRequest:request];
    }
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
                    loadArtBlockingForExpectedGeneration:request.generation
                    sourceFileReadAllowed:sourceFileReadAllowed];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
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
        if (request.stale ||
                ![request.artwork isGenerationCurrent:request.generation] ||
                !request.stillWanted()) {
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
    NSUInteger generation = request.generation;
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
        [self admitWaitingRequestIfPossible];
        return;
    }

    [artwork clearLoadPendingForGeneration:generation];
    if (!wanted || stale) {
        [artwork invalidateDecodedArtForGeneration:generation];
        [self admitWaitingRequestIfPossible];
        return;
    }
    [self admitWaitingRequestIfPossible];
    completion(image);
}

- (void)cancelLoadsForArtwork:(AudioTrackArtwork *)artwork {
    NSParameterAssert(NSThread.isMainThread);
    for (ArtworkLoadRequest *waiting in [_waitingRequests copy]) {
        if (waiting.artwork == artwork) {
            [_waitingRequests removeObjectIdenticalTo:waiting];
        }
    }
    for (ArtworkLoadRequest *request in [_requests copy]) {
        if (request.artwork == artwork) {
            [self cancelRequest:request];
        }
    }
}

@end

static ArtworkLoadRegistry *sArtworkLoadRegistry;

static ArtworkLoadRegistry *VibeSharedArtworkLoadRegistry(void) {
    NSCAssert(NSThread.isMainThread, @"Artwork load admission is main-thread only");
    @synchronized ([AudioTrackArtwork class]) {
        if (!sArtworkLoadRegistry) {
            AudioWorkScheduler *scheduler = [[AudioWorkScheduler alloc]
                    initWithLabel:@"com.vibe.artwork"
                    qualityOfService:QOS_CLASS_USER_INITIATED
                    maximumRunningCount:kArtworkLoadMaximumRunningCount
                    maximumPendingCount:kArtworkLoadMaximumPendingCount
                    pendingGrace:kArtworkLoadPendingGrace];
            sArtworkLoadRegistry = [[ArtworkLoadRegistry alloc]
                    initWithMaterializationCoordinator:
                            AudioFileMaterializationCoordinator.sharedCoordinator
                    workScheduler:scheduler];
        }
        return sArtworkLoadRegistry;
    }
}

static ArtworkLoadRegistry *VibeExistingArtworkLoadRegistry(void) {
    @synchronized ([AudioTrackArtwork class]) {
        return sArtworkLoadRegistry;
    }
}

@implementation AudioTrackArtwork {
    VibeImage *_embeddedThumbnail;
    VibeImage *_embeddedArt;
    NSData *_embeddedArtData;
    AudioTrackArtworkExtractor _extractor;
    // The file carries art, in hand or not. Set by a parse that found bytes and
    // by an archive that recorded the fact, and never cleared by a discard —
    // the bytes go, the fact does not.
    BOOL _embeddedArtKnown;
    // YES only after extraction conclusively found art or found none. A read
    // failure leaves this NO, keeping the file unknown and the folder fallback
    // closed.
    BOOL _embeddedExtractionSettled;
    BOOL _embeddedExtractionInFlight;
    NSUInteger _embeddedExtractionFailures;
    // Monotonic seconds before which no further extraction may start, 0 for
    // none. Set by a failed read, cleared by anything that re-arms the budget.
    NSTimeInterval _embeddedExtractionRetryNotBefore;
    BOOL _embeddedUndecodable;
    NSUInteger _artGeneration;
    BOOL _artLoadPending;
}

+ (void)installArtLoadServicesForTesting:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                              workScheduler:(AudioWorkScheduler *)workScheduler {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(materializationCoordinator);
    NSParameterAssert(workScheduler);
    @synchronized (self) {
        NSAssert(!sArtworkLoadRegistry || sArtworkLoadRegistry.registeredRequestCount == 0,
                 @"Cannot replace artwork load services while requests are live");
        sArtworkLoadRegistry = [[ArtworkLoadRegistry alloc]
                initWithMaterializationCoordinator:materializationCoordinator
                workScheduler:workScheduler];
    }
}

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
#if TARGET_OS_OSX
        _folderArt = FolderArtResolver.sharedInstance;
#else
        // Folder art is a macOS feature. Left nil, every folder-art accessor
        // below is a message to nil: no cover image, and no background load
        // scheduled, so iOS shows a file's embedded art alone and the resolver
        // is never built.
        _folderArt = nil;
#endif
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    AudioTrackArtwork *copy = [[[self class] allocWithZone:zone]
            initWithSourceFilePath:self.sourceFilePath extractor:_extractor];
    copy.folderArt = self.folderArt;
    copy.clock = self.clock;
    @synchronized (self) {
        // Pixel objects may be shared, but every transition field belongs to
        // the new holder. A copied art-bearing row carries only its thumbnail,
        // matching a disk-cache hit, and re-reads full-size bytes on demand.
        copy->_embeddedThumbnail = _embeddedThumbnail;
        copy->_embeddedArtKnown = _embeddedArtKnown;
        copy->_embeddedUndecodable = _embeddedUndecodable;
        copy->_embeddedExtractionSettled = _embeddedArtKnown
                ? _embeddedUndecodable : _embeddedExtractionSettled;
    }
    return copy;
}

// Read before taking the monitor, never under it — it is cheap and never
// blocks, but the injected form is arbitrary caller code.
- (NSTimeInterval)nowSeconds {
    AudioTrackArtworkClock clock = self.clock;
    return clock ? clock() : NSProcessInfo.processInfo.systemUptime;
}

// _embeddedExtractionRetryNotBefore is 0 whenever no read has failed, so this
// is also the answer for a track that has never been read at all.
- (BOOL)retryBackoffHasElapsedLocked:(NSTimeInterval)now {
    return now >= _embeddedExtractionRetryNotBefore;
}

- (BOOL)canStartEmbeddedExtractionLockedAt:(NSTimeInterval)now {
    return !_embeddedExtractionSettled && !_embeddedExtractionInFlight &&
            !_embeddedUndecodable &&
            _embeddedExtractionFailures < kMaxEmbeddedArtExtractionFailures &&
            [self retryBackoffHasElapsedLocked:now] &&
            _sourceFilePath != nil && _extractor != nil;
}

- (void)adoptParsedArtData:(NSData *)artData {
    @synchronized (self) {
        _embeddedArtData = artData;
        _embeddedArtKnown = (artData != nil);
        _embeddedExtractionSettled = YES;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
}

- (void)adoptArchivedThumbnailData:(NSData *)encodedData
                    hasEmbeddedArt:(BOOL)hasEmbeddedArt {
    // Decode outside the monitor, per the file's discipline, though in
    // practice this runs during unarchiving, before the object is shared.
    VibeImage *thumbnail = VibeDecodedImageWithData(encodedData, kVibeThumbnailArtDimension);
    @synchronized (self) {
        _embeddedThumbnail = thumbnail;
        _embeddedArtKnown = hasEmbeddedArt;
        // An entry that knows of no art is artless: mark it settled rather
        // than re-reading the file for art that is not there. An art-bearing
        // entry stays NO, so the full-resolution image is re-read on demand.
        _embeddedExtractionSettled = !hasEmbeddedArt;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
}

- (BOOL)hasEmbeddedArt {
    @synchronized (self) {
        return _embeddedArtKnown;
    }
}

- (void)prewarmEmbeddedThumbnail {
    (void)[self embeddedThumbnail];
}

// The file's own art, or the folder's cover when it has none. Blocking on both
// paths; the folder side resolves its directory the first time any track in it
// asks — see FolderArtResolver, which owns the cost rules.
- (VibeImage *)loadArtBlocking {
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
    }
    return [self loadArtBlockingForExpectedGeneration:generation
                                sourceFileReadAllowed:YES];
}

- (VibeImage *)loadArtBlockingForExpectedGeneration:(NSUInteger)generation
                              sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    VibeImage *embedded = [self embeddedArtForExpectedGeneration:generation
                                           sourceFileReadAllowed:sourceFileReadAllowed];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        if (generation != _artGeneration) {
            return nil;
        }
        path = [self folderFallbackPathLocked];
    }
    return [self.folderArt displayImageForAudioFilePath:path];
}

// Full-resolution art decodes lazily, so only the tracks actually displayed
// pay the decode and memory cost. Cache-hit instances carry no art bytes,
// which are not archived, and re-extract from the audio file on demand. Only
// the current track ever takes that path.
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    VibeEmbeddedArtExtractionResult extractionResult = VibeEmbeddedArtExtractionReadFailed;
    NSUInteger generation;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        // This check and the source-extraction claim are one critical section.
        // A demotion therefore lands wholly before the read (which never starts)
        // or wholly after its claim (when it is legitimately uncancellable).
        if (expectedGeneration != _artGeneration) {
            return nil;
        }
        generation = expectedGeneration;
        if (_embeddedArt) {
            return _embeddedArt;
        }
        if (_embeddedArtData) {
            dataToDecode = _embeddedArtData;
            dataWasInMemory = YES;
        }
        else if ([self canStartEmbeddedExtractionLockedAt:now]) {
            if (!sourceFileReadAllowed) {
                return nil;
            }
            _embeddedExtractionInFlight = YES;
            pathToExtract = _sourceFilePath;
        }
        // A conclusive artless result is never re-read, while a failed read gets
        // a small bounded retry budget, no faster than the backoff. Claim the
        // call under the lock so concurrent callers do not double-extract.
        else {
            return nil;
        }
    }
    // File I/O and the decode run outside the lock; see the discipline above.
    if (!dataToDecode && pathToExtract) {
        extractionResult = _extractor(pathToExtract, &dataToDecode);
        if (extractionResult == VibeEmbeddedArtExtractionFoundArt && !dataToDecode) {
            LogWarn(@"Embedded art extractor reported art without bytes for %@",
                    pathToExtract.lastPathComponent);
            extractionResult = VibeEmbeddedArtExtractionReadFailed;
        }
    }
    VibeImage *decoded = dataToDecode
            ? VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension)
            : nil;
    // Read before the monitor, like the one at entry. Timed from when the read
    // RETURNED, not when it started: a read that blocked for a minute has
    // already given the condition every chance to change, and one that failed
    // instantly is the case the backoff exists for.
    NSTimeInterval completedAt = [self nowSeconds];
    @synchronized (self) {
        if (pathToExtract) {
            _embeddedExtractionInFlight = NO;
            if (extractionResult == VibeEmbeddedArtExtractionReadFailed) {
                // A demotion starts a fresh display pass. Its generation bump
                // re-armed the budget, so an older read must not spend one of
                // the new pass's attempts, or hold the new pass off behind a
                // backoff, when it finally settles.
                if (generation == _artGeneration) {
                    _embeddedExtractionFailures = MIN(kMaxEmbeddedArtExtractionFailures,
                                                       _embeddedExtractionFailures + 1);
                    _embeddedExtractionRetryNotBefore =
                            completedAt + kEmbeddedArtExtractionRetryBackoff;
                }
                return _embeddedArt; // a concurrent store, if one arrived
            }
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
            if (extractionResult == VibeEmbeddedArtExtractionNoArt) {
                _embeddedArtKnown = NO;
                _embeddedExtractionSettled = YES;
                return _embeddedArt;
            }
            _embeddedArtKnown = YES;
            _embeddedExtractionSettled = YES;
        }
        if (dataToDecode && !decoded) {
            // The bytes exist but cannot be decoded, which is permanent for
            // this file. Mark it and drop the bytes rather than pinning them.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
            return _embeddedArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard ran mid-load. Otherwise
        // return the result transiently, without re-pinning a demoted track's
        // art. A racing discardArtData is fine, since it only wants the
        // raw bytes gone.
        if (generation == _artGeneration) {
            // Cache the bytes only when they were freshly read from the file.
            // Bytes that have gone from _embeddedArtData by now were dropped by
            // discardArtData mid-decode, and restoring them would undo
            // its memory release.
            if (dataToDecode && !_embeddedArtData && !dataWasInMemory) {
                _embeddedArtData = dataToDecode;
            }
            if (!_embeddedArt && decoded) {
                _embeddedArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Nothing is stored, but the file demonstrably has art, so re-arm
            // the on-demand re-read. This load claimed the attempt flag on
            // entry, and the discard's early return left that claim in place.
            _embeddedExtractionSettled = NO;
        }
        return _embeddedArt ?: decoded;
    }
}

// The gate on every folder-art fallback below. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    // _embeddedArtKnown covers what the other three cannot: a cache hit whose
    // entry was written before the thumbnail was archived, and a parsed track
    // whose bytes have been discarded, both of which have art without holding
    // any of it.
    BOOL hasArtOfItsOwn = _embeddedArtKnown || _embeddedArt != nil ||
                          _embeddedArtData != nil || _embeddedThumbnail != nil;
    if (_embeddedUndecodable) {
        return YES;
    }
    if (hasArtOfItsOwn) {
        return NO;
    }
    return _embeddedExtractionSettled;
}

// The file to ask the folder about, or nil when the folder must not be asked.
// Every fallback below goes through this one line, so the guarantee that a
// cover can never stand in front of a track's own art has exactly one home.
// Call with the monitor held. nil is a contractual argument to every
// FolderArtResolver accessor, so callers pass the result straight on.
- (NSString *)folderFallbackPathLocked {
    return [self knownToCarryNoArtLocked] ? _sourceFilePath : nil;
}

- (VibeImage *)cachedArt {
    NSString *path;
    @synchronized (self) {
        if (_embeddedArt) {
            return _embeddedArt;
        }
        path = [self folderFallbackPathLocked];
    }
    // No decode and no file access: this is the main thread's updateUI
    // accessor, and both happen on the background loadArtBlocking path that
    // artNeedsLoad asks for. The folder's cover comes back only if it is
    // already decoded.
    return [self.folderArt cachedDisplayImageForAudioFilePath:path];
}

- (BOOL)artNeedsLoad {
    NSString *path;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching. The
        // backoff is applied here as well as in embeddedArt, so a pass inside
        // the window answers NO rather than dispatching a load that would take
        // the pending marker and immediately no-op.
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        if (!_embeddedUndecodable && (_embeddedArtData != nil || canExtract)) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // The file has no art of its own, or none that decodes. A load is still
    // worth dispatching while the folder's cover is unsettled or undecoded, and
    // FolderArtResolver answers NO for good once a folder is known to have none, so
    // this cannot spin.
    return [self.folderArt needsBackgroundLoadForAudioFilePath:path];
}

- (BOOL)isArtLoadPending {
    @synchronized (self) {
        return _artLoadPending;
    }
}

- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL **)sourceURL {
    NSParameterAssert(generation);
    NSParameterAssert(sourceURL);
    if (![self artNeedsLoad]) {
        return NO;
    }
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_artLoadPending || _embeddedArt) {
            return NO;
        }
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        BOOL needsEmbeddedWork = !_embeddedUndecodable &&
                (_embeddedArtData != nil || canExtract);
        *sourceURL = needsEmbeddedWork && canExtract && !_embeddedArtData
                ? [NSURL fileURLWithPath:_sourceFilePath] : nil;
        *generation = _artGeneration;
        _artLoadPending = YES;
        return YES;
    }
}

- (void)loadArtIfNeededWithLabel:(NSString *)label
                     stillWanted:(BOOL (^)(void))stillWanted
                       completion:(void (^)(VibeImage *))completion {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(stillWanted);
    NSParameterAssert(completion);
    [VibeSharedArtworkLoadRegistry() loadArtwork:self label:label
                                     stillWanted:stillWanted completion:completion];
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
    @synchronized (self) {
        return _artGeneration == generation;
    }
}

- (void)clearLoadPendingForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            _artLoadPending = NO;
        }
    }
}

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the whole session.
// Afterwards the instance behaves like a cache hit: loadArtBlocking re-reads the
// audio file on demand for the one track shown at full resolution.
- (void)discardArtData {
    @synchronized (self) {
        // There is deliberately no generation bump. This only wants the raw
        // bytes released, not an in-flight decode of those same bytes thrown
        // away.
        if (!_embeddedArtData) {
            // There is nothing to drop. Keep the settled flag: an artless
            // track has it set to YES from the parse, and resetting it would
            // trigger a full TagLib re-parse merely to rediscover that there
            // is no art.
            return;
        }
        _embeddedArtData = nil;
        if (!_embeddedArt) {
            // Art exists but is not yet decoded, so re-arm the on-demand
            // re-read.
            _embeddedExtractionSettled = NO;
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
        }
    }
}

// Called by the UI, on the main thread, when this track stops being current.
- (void)discardDecodedArt {
    NSParameterAssert(NSThread.isMainThread);
    @synchronized (self) {
        [self discardDecodedArtStateLocked];
    }
    [VibeExistingArtworkLoadRegistry() cancelLoadsForArtwork:self];
}

- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            [self discardDecodedArtStateLocked];
        }
    }
}

// Call with the monitor held.
- (void)discardDecodedArtStateLocked {
    // Bump before every early exit. This is both the store fence and the request
    // identity presented under the extraction-claim lock.
    _artGeneration++;
    _artLoadPending = NO;
    if (!_embeddedExtractionSettled && !_embeddedUndecodable) {
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
    // TRAP: _embeddedExtractionInFlight is deliberately NOT cleared here. It is
    // the single-flight claim over a read already running outside the monitor.
    if (!_embeddedArt && !_embeddedArtData) {
        return;
    }
    _embeddedArt = nil;
    _embeddedArtData = nil;
    _embeddedExtractionSettled = NO;
}

- (VibeImage *)cachedThumbnail {
    VibeImage *embedded = [self embeddedThumbnail];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        // A track with its own art never asks the folder anything, so a fully
        // tagged playlist never opens a cover file at all.
        path = [self folderFallbackPathLocked];
    }
    // Non-blocking, so a playlist cell may call this while drawing: an
    // unresolved folder resolves in the background, and the notification brings
    // the row back to be redrawn.
    return [self.folderArt cachedThumbnailForAudioFilePath:path resolveIfUnknown:YES];
}

- (VibeImage *)embeddedThumbnail {
    NSData *dataToDecode = nil;
    @synchronized (self) {
        if (_embeddedThumbnail) return _embeddedThumbnail;
        if (!_embeddedArtData) {
            return nil;
        }
        dataToDecode = _embeddedArtData;
    }
    // Decode outside the lock; see the file's discipline above.
    VibeImage *thumbnail = VibeDecodedImageWithData(dataToDecode, kVibeThumbnailArtDimension);
    @synchronized (self) {
        if (!thumbnail) {
            // The same undecodable marking as the full-resolution path.
            // Otherwise every playlist cell redraw retries the doomed decode.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
        }
        if (!_embeddedThumbnail && thumbnail) {
            _embeddedThumbnail = thumbnail;
        }
        return _embeddedThumbnail;
    }
}

@end
