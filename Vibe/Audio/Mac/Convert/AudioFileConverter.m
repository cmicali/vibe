//
//  AudioFileConverter.m
//  Vibe
//

#import "AudioFileConverterInternal.h"
#import "AudioFileConverter+Sandbox.h"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "FLACConvertRules.h"
#import "FLACTagCopier.h"
#import "NSURL+AudioOpen.h"
#import "VibeStrings.h"

NSString *const kVibeConvertErrorDomain = @"com.commonwealthrecordings.Vibe.convert";

// Frames per read-write pass: about 0.7 seconds at 44.1kHz, enough to
// amortize the per-buffer overhead against the encode.
static const AVAudioFrameCount kConvertBufferFrames = 32768;

// The encode's temp name in NSTemporaryDirectory(); the launch sweep matches
// it to remove what a crash or a kill left behind.
static NSString *const kConvertTempPrefix = @"vibe-convert-";

#pragma mark - Converter

// _queue and _relatedItemPresenters are in AudioFileConverterInternal.h: the
// sandbox category reaches both.
@implementation AudioFileConverter {
    // Disposal moves, unbounded on a cloud or network folder, so off main —
    // and off the converter queue, or an undo would wait out a running encode.
    // Serial, because an undo must follow the trash it reverses.
    dispatch_queue_t _disposeQueue;
    // The destination stats, serial: each menu open against an unreachable
    // mount would otherwise park another global-pool worker for the whole
    // mount timeout — the generation drops stale answers but not stale work.
    dispatch_queue_t _statQueue;
    // Whether the FLAC beside the track the menus name exists, and which
    // destination that answer is about. Menu validation reads this rather than
    // statting — a stat on an unreachable mount blocks the main thread.
    // refreshDestinationStateForTrack: keeps it warm; the generation drops a
    // superseded stat. Main-thread confined.
    NSURL *_destinationCheckedURL;
    BOOL _destinationExists;
    uint64_t _destinationGeneration;
    // Convert > Delete Original as it stood at accept. trashSourceIfEnabled:
    // consumes this, not the live setting, so a mid-encode toggle applies to
    // the next conversion, never the one in flight. Main-thread confined.
    BOOL _deleteOriginalAtAccept;
    // Set on main by cancelConversionWithCompletion:, polled once per buffer
    // on the converter queue, reset at accept.
    atomic_bool _cancelRequested;
    // The cancel completions parked until the running request completes.
    // Main-thread confined.
    NSMutableArray<dispatch_block_t> *_cancelWaiters;
}

- (void)dealloc {
    for (VibeRelatedItemPresenter *presenter in _relatedItemPresenters) {
        [NSFileCoordinator removeFilePresenter:presenter];
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _relatedItemPresenters = [NSMutableArray new];
        // Utility QoS: the encode must never outrank the player queue.
        _queue = dispatch_queue_create("com.vibe.flacconvert",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _disposeQueue = dispatch_queue_create("com.vibe.flacconvert.dispose",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _statQueue = dispatch_queue_create("com.vibe.flacconvert.stat",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // On the encode's own serial queue rather than the dispose queue, so
        // it finishes before the first conversion can create the temp it
        // would otherwise remove.
        dispatch_async(_queue, ^{ [self sweepStaleTempFiles]; });
    }
    return self;
}

// Converter queue. Every completed path removes its own temp; this catches
// what a crash or a kill left behind.
- (void)sweepStaleTempFiles {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *tmpDir = NSTemporaryDirectory();
    NSUInteger removed = 0;
    for (NSString *name in [fileManager contentsOfDirectoryAtPath:tmpDir error:nil]) {
        if ([name hasPrefix:kConvertTempPrefix] && [name.pathExtension isEqualToString:@"flac"]
                && [fileManager removeItemAtPath:[tmpDir stringByAppendingPathComponent:name] error:nil]) {
            removed++;
        }
    }
    if (removed > 0) {
        LogInfo(@"Removed %lu stale conversion temp file(s)", (unsigned long)removed);
    }
}

+ (NSURL *)flacDestinationForURL:(NSURL *)sourceURL {
    return [sourceURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:VibeFLACDestinationName(sourceURL.lastPathComponent)];
}

- (void)refreshDestinationStateForTrack:(AudioTrack *)track {
    NSAssert(NSThread.isMainThread, @"refreshDestinationStateForTrack must be called on the main thread");
    uint64_t generation = ++_destinationGeneration;
    NSURL *sourceURL = track.url;
    if (!sourceURL.isFileURL) {
        _destinationCheckedURL = nil;
        return;
    }
    NSURL *destinationURL = [self.class flacDestinationForURL:sourceURL];
    dispatch_async(_statQueue, ^{
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destinationURL.path];
        run_on_main_thread({
            if (generation != self->_destinationGeneration) {
                return; // a newer refresh owns the answer now
            }
            self->_destinationCheckedURL = destinationURL;
            self->_destinationExists = exists;
        });
    });
}

- (BOOL)validateConvertMenuItem:(NSMenuItem *)menuItem forTrack:(AudioTrack *)track {
    menuItem.title = STR_MENU_CONVERT_TO_FLAC;
    if (!track.url.isFileURL) {
        return NO;
    }
    if (!VibeTrackIsConvertibleToFLAC(track.metadata.fileType, track.url.pathExtension)) {
        return NO;
    }
    // The cached answer, never a stat (see refreshDestinationStateForTrack:),
    // re-warmed each validation. A stale cache lets the item through, and the
    // conversion's own check refuses the write — a beep, not an overwrite.
    // Irrelevant in ask-mode: the save panel handles an existing name itself,
    // and the conversion lifts its refusal to match.
    BOOL destinationExists = !AppSettings.sharedInstance.convertAsksWhereToSave &&
            _destinationExists &&
            [_destinationCheckedURL isEqual:[self.class flacDestinationForURL:track.url]];
    [self refreshDestinationStateForTrack:track];
    if (destinationExists) {
        // Disabled rather than auto-renamed; the title says why.
        menuItem.title = STR_MENU_CONVERT_FLAC_EXISTS;
        return NO;
    }
    return YES;
}

- (void)convertTrackToFLAC:(AudioTrack *)track
          presentingWindow:(NSWindow *)window
                completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    NSAssert(NSThread.isMainThread, @"convertTrackToFLAC must be called on the main thread");

    // Refusals report asynchronously too, so a caller is never re-entered
    // before this method returns.
    NSURL *sourceURL = track.url;
    // Snapshot like the delete toggle: a setting flipped mid-encode applies
    // to the next conversion, never the one in flight. Ask-mode also lifts
    // the destination-exists refusal below — the panel can save under
    // another name, or replace atomically after its own prompt.
    BOOL askWhereToSave = AppSettings.sharedInstance.convertAsksWhereToSave && window != nil;
    NSError *refusal = nil;
    if (self.converting) {
        refusal = [self errorWithCode:VibeConvertErrorBusy
                          description:@"A conversion is already running."];
    }
    else if (!sourceURL.isFileURL) {
        refusal = [self errorWithCode:VibeConvertErrorNotConvertible
                          description:@"That track is not a local file."];
    }
    else if (!VibeTrackIsConvertibleToFLAC(track.metadata.fileType, sourceURL.pathExtension)) {
        // The menus gate on the same rule; the debug channel calls in directly.
        refusal = [self errorWithCode:VibeConvertErrorNotConvertible
                          description:@"Only an uncompressed file converts to FLAC."];
    }
    NSURL *destinationURL = refusal ? nil : [self.class flacDestinationForURL:sourceURL];
    if (refusal) {
        run_on_main_thread({ completion(nil, refusal); });
        return;
    }

    _converting = YES;
    atomic_store(&_cancelRequested, false);
    _deleteOriginalAtAccept = AppSettings.sharedInstance.deleteOriginalAfterConvert;

    __weak AudioFileConverter *weakSelf = self;
    void (^progress)(double) = ^(double fraction) {
        run_on_main_thread({
            AudioFileConverter *strongSelf = weakSelf;
            if (strongSelf && strongSelf.progressHandler) {
                strongSelf.progressHandler(track, fraction);
            }
        });
    };

    dispatch_async(_queue, ^{
        // The destination sits beside the source, which can live on a network
        // mount, and a stat there can block until the mount times out — so
        // the exists re-check runs here, never on the main thread at accept.
        if (!askWhereToSave && [NSFileManager.defaultManager fileExistsAtPath:destinationURL.path]) {
            [self finishConversionWithURL:nil
                                    error:[self errorWithCode:VibeConvertErrorDestinationExists
                                                  description:@"A FLAC of that name already exists."]
                          tempURLToRemove:nil
                               completion:completion];
            return;
        }
        VibeUncompressedContainer sourceContainer =
                VibeSniffUncompressedContainer(sourceURL.path);
        if (sourceContainer == VibeUncompressedContainerUnknown) {
            [self finishConversionWithURL:nil
                                    error:[self errorWithCode:VibeConvertErrorNotConvertible
                                                  description:@"The source is not a readable WAV or AIFF file."]
                          tempURLToRemove:nil
                               completion:completion];
            return;
        }
        NSError *error = nil;
        NSURL *tempURL = [self encodeSource:sourceURL progress:progress error:&error];
        if (!tempURL) {
            // encodeSource: removed its own temp on failure.
            [self finishConversionWithURL:nil
                                    error:error
                          tempURLToRemove:nil
                               completion:completion];
            return;
        }
        // Metadata is part of conversion success. The copier revalidates the
        // header against the preflight result before choosing its tag reader.
        if (!VibeCopyTagsToFLAC(sourceURL.path, tempURL.path, sourceContainer)) {
            [self finishConversionWithURL:nil
                                    error:[self errorWithCode:VibeConvertErrorTagCopyFailed
                                                  description:@"The audio converted, but its tags could not be copied safely."]
                          tempURLToRemove:tempURL
                               completion:completion];
            return;
        }
        // Both silent rungs stay off the main thread: file coordination blocks
        // until every other presenter of the URL relinquishes it, unbounded on
        // a cloud or network folder. When the setting says always ask, skip
        // them and go straight to the panel.
        NSError *placeError = nil;
        NSURL *placedURL = askWhereToSave ? nil : [self moveTemp:tempURL
                                                          source:sourceURL
                                                     destination:destinationURL
                                                           error:&placeError];
        if (placedURL) {
            [self finishConversionWithURL:placedURL
                                    error:nil
                          tempURLToRemove:nil
                               completion:completion];
            return;
        }
        if (!window) {
            [self finishConversionWithURL:nil
                                    error:placeError
                          tempURLToRemove:tempURL
                               completion:completion];
            return;
        }
        run_on_main_thread({
            if (askWhereToSave) {
                LogInfo(@"Settings say ask where to save the converted FLAC");
            }
            else {
                LogInfo(@"Neither silent write worked; asking the user where to put it");
            }
            [self runSavePanelForTemp:tempURL
                               source:sourceURL
                          destination:destinationURL
                               window:window
                           completion:^(NSURL *outputURL, NSError *panelError) {
                [self finishConversionWithURL:outputURL
                                        error:panelError
                              tempURLToRemove:(outputURL ? nil : tempURL)
                                   completion:completion];
            }];
        });
    });
}

// Every terminal path of a conversion that reached _converting = YES funnels
// through here: the temp is removed unless it was placed, and _converting
// flips back on main before the completion runs. The refusals ahead of the flag
// must NOT route through this — a busy refusal would clear a running
// conversion's flag. Callable from any thread.
- (void)finishConversionWithURL:(nullable NSURL *)outputURL
                          error:(nullable NSError *)error
                tempURLToRemove:(nullable NSURL *)tempURL
                     completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    if (tempURL) {
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
    }
    if (!outputURL) {
        [self settleConversionWithURL:nil error:error completion:completion];
        return;
    }
    // Placement is another filesystem boundary after the encoded temp was
    // validated. Keep the source and the playlist untouched unless the file at
    // the URL handed to the controller is still readable as audio.
    dispatch_async(_disposeQueue, ^{
        NSError *verificationError = nil;
        BOOL playable = [self playableFileAtURL:outputURL error:&verificationError];
        if (!playable) {
            // The path may now hold an external replacement, and a save-panel
            // placement may have replaced a user file. Preserve it and make the
            // stranded location explicit rather than guessing it is safe to delete.
            LogError(@"The converted file failed verification and was left at %@: %@",
                    outputURL.path, verificationError.localizedDescription);
        }
        [self settleConversionWithURL:(playable ? outputURL : nil)
                                error:(playable ? error : verificationError)
                           completion:completion];
    });
}

// The request's completion on main, then the parked cancel completions —
// after it, so a Quit waiting on them exits with the controller's swap or
// reset already landed.
- (void)settleConversionWithURL:(nullable NSURL *)outputURL
                          error:(nullable NSError *)error
                     completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    run_on_main_thread({
        self->_converting = NO;
        completion(outputURL, error);
        NSArray<dispatch_block_t> *waiters = self->_cancelWaiters;
        self->_cancelWaiters = nil;
        for (dispatch_block_t waiter in waiters) {
            waiter();
        }
    });
}

- (void)cancelConversionWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"cancelConversionWithCompletion must be called on the main thread");
    if (!_converting) {
        if (completion) {
            run_on_main_thread({ completion(); });
        }
        return;
    }
    atomic_store(&_cancelRequested, true);
    if (completion) {
        if (!_cancelWaiters) {
            _cancelWaiters = [NSMutableArray new];
        }
        [_cancelWaiters addObject:completion];
    }
}

#pragma mark - Disposing of the source

- (void)trashSourceIfEnabled:(NSURL *)sourceURL
                 convertedTo:(NSURL *)outputURL
                  completion:(void (^)(VibeTrashOutcome outcome,
                                       NSURL *_Nullable trashedURL,
                                       NSError *_Nullable error))completion {
    NSAssert(NSThread.isMainThread, @"trashSourceIfEnabled must be called on the main thread");
    VibeSourceTrashResultingURLFilter resultingURLFilter =
            self.nextSourceTrashResultingURLFilter;
    self.nextSourceTrashResultingURLFilter = nil;
    // The nothing-to-do paths report asynchronously too, so a caller is never
    // re-entered before this method returns.
    if (!_deleteOriginalAtAccept || !sourceURL.isFileURL) {
        run_on_main_thread({
            if (completion) completion(VibeTrashOutcomeSkipped, nil, nil);
        });
        return;
    }
    // The placement rungs refuse this, but trashing here would take the only
    // audio with it if a filesystem alias escaped that boundary.
    if ([sourceURL.URLByStandardizingPath.path isEqualToString:outputURL.URLByStandardizingPath.path]) {
        LogWarn(@"Not deleting %@: the conversion landed on the source itself", sourceURL.lastPathComponent);
        run_on_main_thread({
            if (completion) completion(VibeTrashOutcomeSkipped, nil, nil);
        });
        return;
    }
    [self trashItemAtURL:sourceURL
      resultingURLFilter:resultingURLFilter
              completion:^(VibeTrashOutcome outcome, NSURL *trashedURL, NSError *error) {
        if (outcome == VibeTrashOutcomeFailed) {
            LogError(@"Could not delete the converted source %@: %@",
                    sourceURL.lastPathComponent, error.localizedDescription);
        }
        else if (outcome == VibeTrashOutcomeMovedUnknownURL) {
            LogWarn(@"Deleted converted source %@, but the Trash returned no location for undo",
                    sourceURL.lastPathComponent);
        }
        if (completion) {
            completion(outcome, trashedURL, error);
        }
    }];
}

#pragma mark - Trash and restore

// Dispose queue. One line of filesystem truth about a path, for the trash and
// restore logs: the move APIs' return values can disagree with what is on
// disk, so every step logs what a stat says.
static NSString *VibeFileStat(NSURL *url) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (!attributes) {
        return @"absent";
    }
    return [NSString stringWithFormat:@"%@, %llu bytes", attributes.fileType, attributes.fileSize];
}

- (void)trashItemAtURL:(NSURL *)url
            completion:(void (^)(VibeTrashOutcome,
                                 NSURL *_Nullable,
                                 NSError *_Nullable))completion {
    [self trashItemAtURL:url resultingURLFilter:nil completion:completion];
}

- (void)trashItemAtURL:(NSURL *)url
    resultingURLFilter:(VibeSourceTrashResultingURLFilter)resultingURLFilter
            completion:(void (^)(VibeTrashOutcome,
                                 NSURL *_Nullable,
                                 NSError *_Nullable))completion {
    dispatch_async(_disposeQueue, ^{
        LogInfo(@"Trash: %@ (%@)", url.path, VibeFileStat(url));
        __block NSURL *trashedURL = nil;
        __block NSError *error = nil;
        __block BOOL ok = NO;
        // Coordinated, never bare: at a path only the related-item rung could
        // write, an uncoordinated trash is denied.
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        [coordinator coordinateWritingItemAtURL:url
                                        options:NSFileCoordinatorWritingForDeleting
                                          error:&coordinationError
                                     byAccessor:^(NSURL *writeURL) {
            // A handed URL other than ours is a tracked older item; the
            // caller's record is the truth.
            NSURL *target = [writeURL.URLByStandardizingPath isEqual:url.URLByStandardizingPath]
                    ? writeURL : url;
            ok = [NSFileManager.defaultManager trashItemAtURL:target
                                             resultingItemURL:&trashedURL
                                                        error:&error];
        }];
        if (!ok && !error) {
            // coordinationError means the accessor never ran. A nil error
            // from both APIs is still a failed Trash result, not a skip.
            error = coordinationError ?: [self errorWithCode:VibeConvertErrorTrashFailed
                                                  description:[NSString stringWithFormat:
                    @"The Trash did not move %@ and returned no error.", url.lastPathComponent]];
        }
        if (resultingURLFilter) {
            trashedURL = resultingURLFilter(ok, trashedURL);
        }
        NSString *result = [NSString stringWithFormat:
                @"Trash result for %@: ok=%d, resultingItemURL=%@ (%@), source now %@%@%@",
                url.lastPathComponent, ok,
                trashedURL.path ?: @"(none)",
                trashedURL ? VibeFileStat(trashedURL) : @"-",
                VibeFileStat(url),
                error ? @", error: " : @"", error ?: @""];
        if (ok) {
            LogInfo(@"%@", result);
        }
        else {
            LogWarn(@"%@", result);
        }
        VibeTrashOutcome outcome = VibeTrashOutcomeForResult(ok, trashedURL != nil);
        run_on_main_thread({ completion(outcome, trashedURL, ok ? nil : error); });
    });
}

- (void)restoreTrashedItemAtURL:(NSURL *)trashedURL
                          toURL:(NSURL *)originalURL
                     completion:(void (^)(BOOL, NSError *_Nullable))completion {
    dispatch_async(_disposeQueue, ^{
        LogInfo(@"Restore: %@ (%@) -> %@ (%@)",
                trashedURL.path, VibeFileStat(trashedURL),
                originalURL.path, VibeFileStat(originalURL));
        __block NSError *error = nil;
        __block BOOL moved = NO;
        // Coordinated for the same reason as the trash: a redo's restore may
        // target a path writable only through the presenter's coordination.
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        [coordinator coordinateWritingItemAtURL:trashedURL
                                        options:NSFileCoordinatorWritingForMoving
                               writingItemAtURL:originalURL
                                        options:0
                                          error:&coordinationError
                                     byAccessor:^(NSURL *handedFromURL, NSURL *handedToURL) {
            NSURL *from = [handedFromURL.URLByStandardizingPath isEqual:trashedURL.URLByStandardizingPath]
                    ? handedFromURL : trashedURL;
            NSURL *to = [handedToURL.URLByStandardizingPath isEqual:originalURL.URLByStandardizingPath]
                    ? handedToURL : originalURL;
            // moveItemAtURL: refuses to overwrite: something new at the
            // original path blocks the restore rather than being clobbered.
            moved = [NSFileManager.defaultManager moveItemAtURL:from toURL:to error:&error];
            if (moved) {
                [coordinator itemAtURL:from didMoveToURL:to];
            }
        }];
        if (!moved && !error) {
            error = coordinationError; // coordination failed; the accessor never ran
        }
        // Trust the file, not the API: restored means a stat sees it there.
        BOOL atDestination = [NSFileManager.defaultManager fileExistsAtPath:originalURL.path];
        NSString *result = [NSString stringWithFormat:
                @"Restore result for %@: moved=%d, destination now %@, trash item now %@%@%@",
                originalURL.lastPathComponent, moved,
                VibeFileStat(originalURL), VibeFileStat(trashedURL),
                error ? @", error: " : @"", error ?: @""];
        BOOL restored = moved && atDestination;
        if (restored) {
            LogInfo(@"%@", result);
        }
        else {
            LogWarn(@"%@", result);
        }
        if (moved && !atDestination) {
            error = [self errorWithCode:VibeConvertErrorRestoreFailed
                            description:[NSString stringWithFormat:
                    @"The move out of the Trash reported success but %@ is not at %@.",
                    originalURL.lastPathComponent, originalURL.URLByDeletingLastPathComponent.path]];
        }
        run_on_main_thread({ completion(restored, restored ? nil : error); });
    });
}

- (void)verifyPlayableFileAtURL:(NSURL *)url
                     completion:(void (^)(BOOL, NSError *_Nullable))completion {
    NSAssert(NSThread.isMainThread, @"verifyPlayableFileAtURL must be called on the main thread");
    dispatch_async(_disposeQueue, ^{
        NSError *error = nil;
        BOOL playable = [self playableFileAtURL:url error:&error];
        run_on_main_thread({ completion(playable, error); });
    });
}

// A positive check. Called only off main; provider and network reads may block.
- (BOOL)playableFileAtURL:(NSURL *)url error:(NSError **)error {
    BOOL playable = [url validateAudioFileIsReadableAndHasContent];
    if (!playable && error) {
        NSString *path = url.path;
        *error = [self errorWithCode:VibeConvertErrorReplacementUnavailable
                         description:[NSString stringWithFormat:
                @"%@ is missing, unreadable, or not playable.",
                path.length > 0 ? path : @"The replacement audio file"]];
    }
    return playable;
}

#pragma mark - Encode

// The one refusal for a source with no frames. The pre-open
// failsAudioOpenPreflight guard is the load-bearing check (descriptor leak,
// see NSURL+AudioOpen); the per-open length checks back it up with this same
// answer.
- (NSError *)emptySourceError {
    return [self errorWithCode:VibeConvertErrorNotConvertible
                   description:@"That file contains no audio."];
}

// Encodes into the app's own tmp, always writable, so nothing partial ever
// appears beside the user's music. progress runs on the converter queue at
// about one-percent steps, plus a final 1.0.
- (nullable NSURL *)encodeSource:(NSURL *)sourceURL
                        progress:(void (^)(double fraction))progress
                           error:(NSError **)error {
    NSURL *tempURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@%@.flac", kConvertTempPrefix, NSUUID.UUID.UUIDString]]];

    // Ahead of the open, because the length check below only runs once the open
    // has already leaked its descriptor; see NSURL+AudioOpen. Both opens below
    // take this same URL, so one guard covers them.
    if (sourceURL.failsAudioOpenPreflight) {
        if (error) {
            *error = [self emptySourceError];
        }
        return nil;
    }

    AVAudioFile *probe = [[AVAudioFile alloc] initForReading:sourceURL error:error];
    if (!probe) {
        return nil;
    }
    if (probe.length <= 0) {
        // Zero frames would skip the loop and "succeed", swapping a playable
        // row for a FLAC nothing can play.
        if (error) {
            *error = [self emptySourceError];
        }
        return nil;
    }

    // TRAP: the buffer format is the ONLY thing that sets the FLAC's declared
    // source bit depth — AVEncoderBitDepthHintKey and AVLinearPCMBitDepthKey
    // are both silently ignored by this encoder. Int16 buffers give a 16-bit
    // FLAC; anything wider gives 24-bit, the format's ceiling. Float is the
    // one lossy case: FLAC stores integers, and every FLAC encoder quantizes
    // float to 24 bits.
    const AudioStreamBasicDescription *asbd = probe.fileFormat.streamDescription;
    BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    AVAudioCommonFormat bufferFormat = (!isFloat && asbd->mBitsPerChannel <= 16)
            ? AVAudioPCMFormatInt16
            : AVAudioPCMFormatInt32;

    AVAudioFile *source = [[AVAudioFile alloc] initForReading:sourceURL
                                                 commonFormat:bufferFormat
                                                  interleaved:NO
                                                        error:error];
    if (!source) {
        return nil;
    }
    if (source.length <= 0) {
        if (error) {
            *error = [self emptySourceError];
        }
        return nil;
    }

    NSDictionary *settings = @{
        AVFormatIDKey:         @(kAudioFormatFLAC),
        AVSampleRateKey:       @(source.fileFormat.sampleRate),
        AVNumberOfChannelsKey: @(source.fileFormat.channelCount),
    };

    AVAudioFile *destination = [[AVAudioFile alloc] initForWriting:tempURL
                                                          settings:settings
                                                      commonFormat:bufferFormat
                                                       interleaved:NO
                                                             error:error];
    if (!destination) {
        // initForWriting: can fail after creating the file at tempURL.
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        return nil;
    }

    // Rate, channels and buffer format all carry over unchanged, so the two
    // processing formats match and a read buffer is written as-is.
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:source.processingFormat
                                                            frameCapacity:kConvertBufferFrames];
    if (!buffer) {
        // initForWriting: already created the file at tempURL.
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        if (error) {
            *error = [self errorWithCode:VibeConvertErrorNotConvertible
                             description:@"Could not allocate an audio buffer for that format."];
        }
        return nil;
    }
    AVAudioFramePosition expectedFrameCount = source.length;
    BOOL ok = YES;
    double lastReported = 0;
    // The strong local carries a step's error out of its pool; writing the
    // autoreleasing out-param inside would leave it dangling after the drain.
    NSError *streamError = nil;
    while (source.framePosition < expectedFrameCount) {
        // Drained per pass: an hour-long file runs thousands of passes before
        // the queue block's own pool would.
        @autoreleasepool {
            if (atomic_load(&self->_cancelRequested)) {
                LogInfo(@"Conversion of %@ cancelled at frame %lld of %lld",
                        sourceURL.lastPathComponent,
                        (long long)source.framePosition, (long long)expectedFrameCount);
                streamError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                  code:NSUserCancelledError
                                              userInfo:nil];
                ok = NO;
                break;
            }
            NSError *stepError = nil;
            if (![source readIntoBuffer:buffer error:&stepError]) {
                streamError = stepError;
                ok = NO;
                break;
            }
            if (buffer.frameLength == 0) {
                if (source.framePosition < expectedFrameCount) {
                    streamError = [self errorWithCode:VibeConvertErrorEncodeFailed
                                          description:[NSString stringWithFormat:
                            @"The source ended early at frame %lld of %lld.",
                            (long long)source.framePosition, (long long)expectedFrameCount]];
                    ok = NO;
                }
                break;
            }
            if (![destination writeFromBuffer:buffer error:&stepError]) {
                streamError = stepError;
                ok = NO;
                break;
            }
            double fraction = (double)source.framePosition / (double)expectedFrameCount;
            if (progress && fraction - lastReported >= 0.01) {
                lastReported = fraction;
                progress(fraction);
            }
        }
    }
    if (streamError && error) {
        *error = streamError;
    }

    // Flushes the final partial FLAC packet; must precede TagLib's open. On
    // macOS 14, which predates -close, releasing the last reference closes
    // the file in dealloc — the only flush path that existed before the API.
    if (@available(macOS 15.0, *)) {
        [destination close];
    }
    else {
        destination = nil;
    }

    if (!ok) {
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        return nil;
    }

    NSError *validationError = nil;
    AVAudioFile *encoded = [[AVAudioFile alloc] initForReading:tempURL error:&validationError];
    if (!encoded || encoded.length != expectedFrameCount) {
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        if (error) {
            *error = validationError ?: [self errorWithCode:VibeConvertErrorEncodeFailed
                                                 description:[NSString stringWithFormat:
                    @"The encoded FLAC contains %lld of %lld expected frames.",
                    (long long)encoded.length, (long long)expectedFrameCount]];
        }
        return nil;
    }
    if (progress) {
        progress(1.0); // the last sub-percent span still gets its sweep
    }
    return tempURL;
}

#pragma mark - Errors

- (NSError *)errorWithCode:(VibeConvertErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:kVibeConvertErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@end
