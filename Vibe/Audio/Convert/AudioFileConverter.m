//
//  AudioFileConverter.m
//  Vibe
//

#import "AudioFileConverterInternal.h"
#import "AudioFileConverter+Sandbox.h"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AudioTrack.h"
#import "FLACConvertRules.h"
#import "FLACTagCopier.h"
#import "VibeStrings.h"

NSString *const kVibeConvertErrorDomain = @"com.commonwealthrecordings.Vibe.convert";

// Frames per read-write pass: about 0.7 seconds at 44.1kHz, enough to
// amortize the per-buffer overhead against the encode.
static const AVAudioFrameCount kConvertBufferFrames = 32768;

#pragma mark - Converter

// _queue and _relatedItemPresenters are in AudioFileConverterInternal.h: the
// sandbox category reaches both.
@implementation AudioFileConverter {
    // Disposal moves, unbounded on a cloud or network folder, so off main —
    // and off the converter queue, or an undo would wait out a running encode.
    // Serial, because an undo must follow the trash it reverses.
    dispatch_queue_t _disposeQueue;
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
    }
    return self;
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
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
    if (self.converting) {
        menuItem.title = STR_MENU_CONVERT_CONVERTING;
        return NO;
    }
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
    BOOL destinationExists = !Settings.convertAsksWhereToSave &&
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
    BOOL askWhereToSave = Settings.convertAsksWhereToSave && window != nil;
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
    _deleteOriginalAtAccept = Settings.deleteOriginalAfterConvert;

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
            run_on_main_thread({
                self->_converting = NO;
                completion(nil, [self errorWithCode:VibeConvertErrorDestinationExists
                                        description:@"A FLAC of that name already exists."]);
            });
            return;
        }
        NSError *error = nil;
        NSURL *tempURL = [self encodeSource:sourceURL progress:progress error:&error];
        if (!tempURL) {
            run_on_main_thread({
                self->_converting = NO;
                completion(nil, error);
            });
            return;
        }
        // Tag failure is cosmetic: an untagged FLAC is still the user's audio.
        VibeCopyTagsToFLAC(sourceURL.path, tempURL.path);
        // Both silent rungs stay off the main thread: file coordination blocks
        // until every other presenter of the URL relinquishes it, unbounded on
        // a cloud or network folder. When the setting says always ask, skip
        // them and go straight to the panel.
        NSError *placeError = nil;
        NSURL *placedURL = askWhereToSave ? nil : [self moveTemp:tempURL
                                                          source:sourceURL
                                                     destination:destinationURL
                                                           error:&placeError];
        run_on_main_thread({
            if (placedURL) {
                self->_converting = NO;
                completion(placedURL, nil);
                return;
            }
            if (!window) {
                self->_converting = NO;
                [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
                completion(nil, placeError);
                return;
            }
            if (askWhereToSave) {
                LogInfo(@"Settings say ask where to save the converted FLAC");
            }
            else {
                LogInfo(@"Neither silent write worked; asking the user where to put it");
            }
            [self runSavePanelForTemp:tempURL
                          destination:destinationURL
                               window:window
                           completion:^(NSURL *outputURL, NSError *panelError) {
                self->_converting = NO;
                if (!outputURL) {
                    [NSFileManager.defaultManager removeItemAtURL:tempURL error:nil];
                }
                completion(outputURL, panelError);
            }];
        });
    });
}

#pragma mark - Disposing of the source

- (void)trashSourceIfEnabled:(NSURL *)sourceURL
                 convertedTo:(NSURL *)outputURL
                  completion:(void (^)(NSURL *_Nullable trashedURL))completion {
    NSAssert(NSThread.isMainThread, @"trashSourceIfEnabled must be called on the main thread");
    // The nothing-to-do paths report asynchronously too, so a caller is never
    // re-entered before this method returns.
    if (!_deleteOriginalAtAccept || !sourceURL.isFileURL) {
        run_on_main_thread({ if (completion) completion(nil); });
        return;
    }
    // No rung can land the FLAC on its own source, but trashing it here would
    // take the audio with it, so the guard stays.
    if ([sourceURL.URLByStandardizingPath.path isEqualToString:outputURL.URLByStandardizingPath.path]) {
        LogWarn(@"Not deleting %@: the conversion landed on the source itself", sourceURL.lastPathComponent);
        run_on_main_thread({ if (completion) completion(nil); });
        return;
    }
    [self trashItemAtURL:sourceURL completion:^(NSURL *trashedURL, NSError *error) {
        if (!trashedURL) {
            LogError(@"Could not delete the converted source %@: %@",
                    sourceURL.lastPathComponent, error.localizedDescription);
        }
        if (completion) {
            completion(trashedURL);
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
            completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
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
            error = coordinationError; // coordination failed; the accessor never ran
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
        // A trash with no resulting URL cannot be undone; report it as failed.
        run_on_main_thread({ completion(ok ? trashedURL : nil, ok ? nil : error); });
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

#pragma mark - Encode

// Encodes into the app's own tmp, always writable, so nothing partial ever
// appears beside the user's music. progress runs on the converter queue at
// about one-percent steps, plus a final 1.0.
- (nullable NSURL *)encodeSource:(NSURL *)sourceURL
                        progress:(void (^)(double fraction))progress
                           error:(NSError **)error {
    NSURL *tempURL = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"vibe-convert-%@.flac", NSUUID.UUID.UUIDString]]];

    AVAudioFile *probe = [[AVAudioFile alloc] initForReading:sourceURL error:error];
    if (!probe) {
        return nil;
    }
    if (probe.length <= 0) {
        // Zero frames would skip the loop and "succeed", swapping a playable
        // row for a FLAC nothing can play.
        if (error) {
            *error = [self errorWithCode:VibeConvertErrorNotConvertible
                             description:@"That file contains no audio."];
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
    BOOL ok = YES;
    double lastReported = 0;
    // The strong local carries a step's error out of its pool; writing the
    // autoreleasing out-param inside would leave it dangling after the drain.
    NSError *streamError = nil;
    while (source.framePosition < source.length) {
        // Drained per pass: an hour-long file runs thousands of passes before
        // the queue block's own pool would.
        @autoreleasepool {
            NSError *stepError = nil;
            if (![source readIntoBuffer:buffer error:&stepError]) {
                streamError = stepError;
                ok = NO;
                break;
            }
            if (buffer.frameLength == 0) {
                break; // end of file, whatever framePosition claims
            }
            if (![destination writeFromBuffer:buffer error:&stepError]) {
                streamError = stepError;
                ok = NO;
                break;
            }
            double fraction = (double)source.framePosition / (double)source.length;
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
