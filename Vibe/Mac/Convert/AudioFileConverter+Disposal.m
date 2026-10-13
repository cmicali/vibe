//
//  AudioFileConverter+Disposal.m
//  Vibe
//
//  Trashing the source, undo and redo of a conversion, and the trash, restore
//  and verify primitives under them. File I/O runs on the dispose queue.
//  Undo registration and callbacks run on main.
//

#import "AudioFileConverterInternal.h"

#import <AVFAudio/AVFAudio.h>

#import "AudioFileHandle.h"
#import "FilePaths.h"
#import "VibeStrings.h"

@implementation AudioFileConverter (Disposal)


#pragma mark - Undo and redo

- (void)registerUndoForConversion:(VibeFLACConversionRecord *)record
                    undoManager:(NSUndoManager *)undoManager
                           swap:(void (^)(NSURL *, NSURL *))swap
                     completion:(void (^)(BOOL, NSString *, NSURL *, NSError *))completion {
    [self registerConversionInverse:record undo:YES undoManager:undoManager swap:swap completion:completion];
}

- (void)registerConversionInverse:(VibeFLACConversionRecord *)record undo:(BOOL)undo
                     undoManager:(NSUndoManager *)undoManager
                            swap:(void (^)(NSURL *, NSURL *))swap
                      completion:(void (^)(BOOL, NSString *, NSURL *, NSError *))completion {
    __weak NSUndoManager *weakManager = undoManager;
    [undoManager registerUndoWithTarget:self handler:^(AudioFileConverter *converter) {
        [converter applyConversion:record undo:undo undoManager:weakManager swap:swap completion:completion];
    }];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];
}

- (void)applyConversion:(VibeFLACConversionRecord *)record undo:(BOOL)undo
           undoManager:(NSUndoManager *)undoManager
                  swap:(void (^)(NSURL *, NSURL *))swap
            completion:(void (^)(BOOL, NSString *, NSURL *, NSError *))completion {
    // TRAP: register the opposite first, synchronously, even for a refused
    // inverse: NSUndoManager's stack direction is active only now, and a
    // failed restore must leave a recoverable Undo/Redo entry.
    [self registerConversionInverse:record undo:!undo undoManager:undoManager swap:swap completion:completion];
    if (_undoRedoInFlight) return;
    _undoRedoInFlight = YES;
    void (^settle)(BOOL, NSString *, NSURL *, NSError *) = ^(BOOL committed, NSString *reason, NSURL *stranded, NSError *error) {
        self->_undoRedoInFlight = NO;
        completion(committed, reason, stranded, error);
    };
    NSURL *replacement = undo ? record.sourceURL : record.outputURL;
    NSURL *retiring = undo ? record.outputURL : record.sourceURL;
    NSURL *trashURL = undo ? record.sourceTrashURL : record.outputTrashURL;
    VibeFLACFileLocation location = undo ? record.sourceLocation : record.outputLocation;
    void (^verify)(void) = ^{
        [self verifyPlayableFileAtURL:replacement completion:^(BOOL playable, NSError *error) {
            if (!playable) { settle(NO, @"replacement_unavailable", nil, error); return; }
            BOOL dispose = undo || record.sourceWasTrashed;
            VibeFLACFileLocation retiringLocation = undo ? record.outputLocation : record.sourceLocation;
            if (dispose && !VibeFLACMayDisposeExpectedPath(retiringLocation)) {
                settle(NO, @"already_at_target", nil, nil);
                return;
            }
            swap(retiring, replacement);
            if (!dispose) { settle(YES, nil, nil, nil); return; }
            [self trashItemAtURL:retiring completion:^(VibeTrashOutcome outcome, NSURL *movedURL, NSError *trashError) {
                NSURL *knownURL = outcome == VibeTrashOutcomeMovedKnownURL ? movedURL : nil;
                if (undo) {
                    record.outputTrashURL = knownURL;
                    record.outputLocation = VibeFLACFileLocationAfterTrash(outcome);
                } else {
                    record.sourceTrashURL = knownURL;
                    record.sourceLocation = VibeFLACFileLocationAfterTrash(outcome);
                }
                if (outcome == VibeTrashOutcomeFailed) LogError(@"Conversion inverse could not trash %@: %@", retiring.path, trashError);
                // The verified row swap committed even when disposal failed.
                settle(YES, nil, nil, nil);
            }];
        }];
    };
    if (location == VibeFLACFileLocationUnknownTrashURL) {
        run_on_main_thread({ settle(NO, @"replacement_location_unknown", nil, nil); });
    } else if (location == VibeFLACFileLocationKnownTrashURL) {
        [self restoreTrashedItemAtURL:trashURL toURL:replacement completion:^(BOOL restored, NSError *error) {
            if (!restored) { settle(NO, @"restore_failed", trashURL, error); return; }
            if (undo) {
                record.sourceTrashURL = nil;
                record.sourceLocation = VibeFLACFileLocationExpectedPath;
            } else {
                record.outputTrashURL = nil;
                record.outputLocation = VibeFLACFileLocationExpectedPath;
            }
            verify();
        }];
    } else {
        verify();
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
    // audio with it if a filesystem alias escaped that boundary. Compared by
    // spelling, as the controller's guard is, since this runs on main.
    if ([VibeComparablePath(sourceURL.path) isEqualToString:VibeComparablePath(outputURL.path)]) {
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
    if (_trash) { _trash(url, completion); return; }
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
    if (_restore) { _restore(trashedURL, originalURL, completion); return; }
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
        // Require both a successful move and a file at the destination.
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
    if (_verify) { _verify(url, completion); return; }
    NSAssert(NSThread.isMainThread, @"verifyPlayableFileAtURL must be called on the main thread");
    dispatch_async(_disposeQueue, ^{
        NSError *error = nil;
        BOOL playable = [self playableFileAtURL:url error:&error];
        run_on_main_thread({ completion(playable, error); });
    });
}

// A positive check — the file opens and decodes at least one frame — not the
// absence of a refusal. Called only off main; provider and network reads may
// block.
- (BOOL)playableFileAtURL:(NSURL *)url error:(NSError **)error {
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:NULL];
    AVAudioPCMBuffer *buffer = file.length > 0
            ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:1] : nil;
    BOOL playable = buffer && [file readIntoBuffer:buffer error:NULL] && buffer.frameLength == 1;
    if (!playable && error) {
        NSString *path = url.path;
        *error = [self errorWithCode:VibeConvertErrorReplacementUnavailable
                         description:[NSString stringWithFormat:
                @"%@ is missing, unreadable, or not playable.",
                path.length > 0 ? path : @"The replacement audio file"]];
    }
    return playable;
}

@end
