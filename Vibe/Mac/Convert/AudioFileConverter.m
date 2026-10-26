//
//  AudioFileConverter.m
//  Vibe
//

#import "AudioFileConverterInternal.h"
#import "AudioFileConverter+Sandbox.h"

#import <AppKit/AppKit.h>
#import <AVFAudio/AVFAudio.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdatomic.h>

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "FLACConvertRules.h"
#import "FLACTagCopier.h"
#import "AudioFileHandle.h"
#import "VibeStrings.h"

NSString *const kVibeConvertErrorDomain = @"com.commonwealthrecordings.Vibe.convert";

// Frames per read-write pass: about 0.7 seconds at 44.1kHz, enough to
// amortize the per-buffer overhead against the encode.
static const AVAudioFrameCount kConvertBufferFrames = 32768;

// The encode's temp name in NSTemporaryDirectory(); the launch sweep matches
// it to remove what a crash or a kill left behind.
static NSString *const kConvertTempPrefix = @"vibe-convert-";

// TRAP: progress and settlement reach main through the run loop's block queue,
// never the main dispatch queue. Quit waits on a cancel's settlement, and a
// Quit issued from a main-queue block (the debug channel's quit) waits inside
// it, where libdispatch never drains the main queue. Progress shares the queue
// so no report can land after the settlement's sweep reset.
static void VibeConverterPerformOnMain(dispatch_block_t block) {
    CFRunLoopRef mainRunLoop = CFRunLoopGetMain();
    CFRunLoopPerformBlock(mainRunLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(mainRunLoop);
}

@implementation VibeFLACConversionRecord
@end

#pragma mark - Converter

// The ivars the sandbox and disposal categories reach are in
// AudioFileConverterInternal.h.
@implementation AudioFileConverter {
    // Whether the FLAC beside the track the menus name exists, and which
    // destination that answer is about. TRAP: menu validation reads this,
    // never a stat. A stat on an unreachable mount blocks the main thread.
    // refreshDestinationStateForTrack: keeps it warm. One stat runs at a time,
    // and only the newest destination asked for waits behind it. A hung mount
    // then parks one worker, not one per menu open. Main-thread confined.
    NSURL *_destinationCheckedURL;
    BOOL _destinationExists;
    BOOL _destinationStatRunning;
    NSURL *_destinationQueuedURL; // asked for while a stat runs; nil when none waits
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
    self = [self initWithRestore:nil verify:nil trash:nil];
    if (self) dispatch_async(_queue, ^{ [self sweepStaleTempFiles]; });
    return self;
}

- (instancetype)initWithRestore:(void (^)(NSURL *, NSURL *, void (^)(BOOL, NSError *)))restore
                         verify:(void (^)(NSURL *, void (^)(BOOL, NSError *)))verify
                          trash:(void (^)(NSURL *, void (^)(VibeTrashOutcome, NSURL *, NSError *)))trash {
    self = [super init];
    if (self) {
        _restore = [restore copy];
        _verify = [verify copy];
        _trash = [trash copy];
        _relatedItemPresenters = [NSMutableArray new];
        // Utility QoS: the encode must never outrank the player queue.
        _queue = dispatch_queue_create("com.vibe.flacconvert",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // User-initiated: the user waits on every move here before Undo works.
        _disposeQueue = dispatch_queue_create("com.vibe.flacconvert.dispose",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
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
    NSURL *sourceURL = track.url;
    if (!sourceURL.isFileURL) {
        _destinationCheckedURL = nil;
        _destinationQueuedURL = nil;
        return;
    }
    _destinationQueuedURL = [self.class flacDestinationForURL:sourceURL];
    if (!_destinationStatRunning) {
        [self statQueuedDestination];
    }
}

// Main. Stats the newest destination asked for, then the next one asked for
// meanwhile, if any.
- (void)statQueuedDestination {
    NSURL *destinationURL = _destinationQueuedURL;
    _destinationQueuedURL = nil;
    _destinationStatRunning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:destinationURL.path];
        run_on_main_thread({
            // Labeled with its destination, which validation matches.
            self->_destinationStatRunning = NO;
            self->_destinationCheckedURL = destinationURL;
            self->_destinationExists = exists;
            if (self->_destinationQueuedURL) {
                [self statQueuedDestination];
            }
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

    [self beginConversionDeletingOriginal:AppSettings.sharedInstance.deleteOriginalAfterConvert];

    __weak AudioFileConverter *weakSelf = self;
    void (^progress)(double) = ^(double fraction) {
        VibeConverterPerformOnMain(^{
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
        NSURL *tempURL = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%@%@.flac", kConvertTempPrefix, NSUUID.UUID.UUIDString]]];
        if (![self encodeSource:sourceURL toURL:tempURL progress:progress error:&error]) {
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

- (void)beginConversionDeletingOriginal:(BOOL)deleteOriginal {
    NSAssert(!_converting, @"Only one accepted conversion may run");
    _converting = YES;
    atomic_store(&_cancelRequested, false);
    _deleteOriginalAtAccept = deleteOriginal;
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
    VibeConverterPerformOnMain(^{
        self->_converting = NO;
        NSArray<dispatch_block_t> *waiters = self->_cancelWaiters;
        self->_cancelWaiters = nil;
        completion(outputURL, error);
        for (dispatch_block_t waiter in waiters) {
            waiter();
        }
    });
}

- (void)cancelConversionWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"cancelConversionWithCompletion must be called on the main thread");
    if (!_converting) {
        if (completion) {
            VibeConverterPerformOnMain(completion);
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

#pragma mark - Encode

// Encodes into the supplied temp URL. progress runs on the converter queue
// at about one-percent steps, plus a final 1.0.
- (nullable NSURL *)encodeSource:(NSURL *)sourceURL
                           toURL:(NSURL *)tempURL
                        progress:(void (^)(double fraction))progress
                           error:(NSError **)error {
    AudioFileHandle *source = [[AudioFileHandle alloc] initForReading:sourceURL error:error];
    if (!source) {
        return nil;
    }
    if (source.length <= 0) {
        // Zero frames would skip the loop and "succeed", swapping a playable
        // row for a FLAC nothing can play.
        if (error) {
            *error = [self errorWithCode:VibeConvertErrorNotConvertible description:@"That file contains no audio."];
        }
        return nil;
    }

    // The FLAC's declared source depth, the file format's flag: 16 bits for
    // an integer source of at most 16, else 24. The
    // encoder rounds the float32 read to it without dither, so integer
    // sources up to 24 bits are exact. TRAP: fed Int32 buffers, the encoder
    // wraps a positive full-scale sample to negative full scale.
    const AudioStreamBasicDescription *asbd = source.fileFormat.streamDescription;
    BOOL sixteen = !(asbd->mFormatFlags & kAudioFormatFlagIsFloat) && asbd->mBitsPerChannel <= 16;

    AudioStreamBasicDescription flac = {0};
    flac.mFormatID = kAudioFormatFLAC;
    flac.mSampleRate = source.fileFormat.sampleRate;
    flac.mChannelsPerFrame = source.fileFormat.channelCount;
    flac.mFormatFlags = sixteen ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData;
    AudioFileHandle *destination = [[AudioFileHandle alloc]
            initForWriting:tempURL fileType:kAudioFileFLACType
                fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&flac]
          processingFormat:source.processingFormat error:error];
    if (!destination) {
        // The create can fail after making the file at tempURL.
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        return nil;
    }

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
    // Flushes the final partial FLAC packet; must precede the validation and
    // TagLib's open, and its own failure fails the conversion.
    if (ok && ![destination closeWithError:&streamError]) {
        ok = NO;
    }
    if (!ok) {
        if (error) {
            *error = streamError;
        }
        [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
        return nil;
    }

    NSError *validationError = nil;
    AudioFileHandle *encoded = [[AudioFileHandle alloc] initForReading:tempURL error:&validationError];
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
