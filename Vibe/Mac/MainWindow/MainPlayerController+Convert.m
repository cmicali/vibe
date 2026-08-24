//
//  MainPlayerController+Convert.m
//  Vibe
//

#import "MainPlayerController+Convert.h"
#import "MainPlayerControllerInternal.h"

#import "AppSettings.h"
#import "AudioFileConverter.h"
#import "VibeStrings.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"

// One finished conversion, as NSUndoManager's invocation argument: where the
// source was, where the FLAC landed, and any known Trash location for whichever
// was last moved aside. A nil Trash URL says only that no location is known;
// the expected live path must still be verified before either direction
// commits. Mutated in place as moves land, so one object rides both directions.
@interface VibeFLACConversionRecord : NSObject
@property (strong) NSURL *sourceURL;
@property (strong) NSURL *outputURL;
@property (strong) NSURL *sourceTrashURL;
@property (strong) NSURL *outputTrashURL;
@property VibeFLACFileLocation sourceLocation;
@property VibeFLACFileLocation outputLocation;
// Whether the conversion trashed its source, so redo re-trashes it rather
// than re-reading a setting that may have flipped.
@property BOOL sourceWasTrashed;
@end
@implementation VibeFLACConversionRecord
@end

@implementation MainPlayerController (Convert)

#pragma mark - Convert to FLAC

- (IBAction)convertCurrentTrackToFLAC:(id)sender {
    AudioTrack *track = self.playlistController.currentTrack;
    if (track) {
        [self convertTrackToFLAC:track completion:nil];
    }
}

- (void)convertTrackToFLAC:(AudioTrack *)track
                completion:(void (^)(NSURL *_Nullable, BOOL, NSError *_Nullable))completion {
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter convertTrackToFLAC:track
                          presentingWindow:self.window
                                completion:^(NSURL *outputURL, NSError *error) {
        void (^reply)(BOOL) = ^(BOOL sourceDeleted) {
            if (completion) {
                completion(outputURL, sourceDeleted, error);
            }
        };
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf) {
            reply(NO); // nothing left to swap into; do not stand the caller up
            return;
        }
        [strongSelf didConvertTrack:track
                              toURL:outputURL
                              error:error
                         completion:reply];
    }];
}

// Main thread. Swaps first, then disposes of the source — the swap is what
// stops the row and the player from pointing at the file being deleted.
// completion runs on every path once the disposal settles.
- (void)didConvertTrack:(AudioTrack *)track
                  toURL:(NSURL *)outputURL
                  error:(NSError *)error
             completion:(void (^)(BOOL sourceDeleted))completion {
    // Not while a conversion still runs: this call may be a busy-rejected
    // request, and resetting the live sweep's front would make its next
    // report re-dip everything swept so far.
    if (!self.fileConverter.isConverting) {
        [self.trackDisplay setConvertSweepFraction:0];
    }
    if (!outputURL) {
        // A dismissed save panel is a decision, not a failure. Real failures
        // beep and log; the house style has no alerts.
        if (!([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError)) {
            LogError(@"Convert to FLAC failed: %@", error.localizedDescription);
            NSBeep();
        }
        completion(NO);
        return;
    }
    // Pin to a plain path URL: a file-reference URL from a Finder drag
    // re-resolves, and the undo record must mean the path the source is at
    // now — not follow it into the Trash. A file-reference URL whose file
    // vanished mid-encode has a nil path, and fileURLWithPath: throws on nil.
    NSString *sourcePath = track.url.path;
    NSURL *sourceURL = sourcePath ? [NSURL fileURLWithPath:sourcePath] : track.url;
    if ([sourceURL.URLByStandardizingPath.path
            isEqualToString:outputURL.URLByStandardizingPath.path]) {
        LogError(@"Convert to FLAC kept the playlist unchanged because the output replaced its source at %@",
                sourceURL.path);
        NSBeep();
        completion(NO);
        return;
    }
    [self swapConvertedTrack:track toURL:outputURL];
    [self.fileConverter refreshDestinationStateForTrack:self.playlistController.currentTrack];
    // Runs whether or not the swap found a row: the FLAC is on disk either
    // way, so the source is superseded even after a mid-encode re-drop.
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter trashSourceIfEnabled:sourceURL
                                 convertedTo:outputURL
                                  completion:^(VibeTrashOutcome outcome,
                                               NSURL *trashedURL,
                                               NSError *__unused disposalError) {
        MainPlayerController *strongSelf = weakSelf;
        if (strongSelf) {
            VibeFLACConversionRecord *record = [VibeFLACConversionRecord new];
            record.sourceURL = sourceURL;
            record.outputURL = outputURL;
            record.sourceTrashURL = trashedURL;
            record.sourceLocation = VibeFLACFileLocationAfterTrash(outcome);
            record.outputLocation = VibeFLACFileLocationExpectedPath;
            record.sourceWasTrashed = VibeTrashOutcomeDidMove(outcome);
            [strongSelf registerUndoOfConversion:record];
        }
        completion(VibeTrashOutcomeDidMove(outcome));
    }];
}

// Puts the finished FLAC into the rows its source occupied, so the conversion
// reads as the file changing format in place. Main thread.
- (void)swapConvertedTrack:(AudioTrack *)track toURL:(NSURL *)outputURL {
    // The row the converted track occupies now, not at conversion start: a
    // mid-encode re-drop replaces the playlist, and then there is nothing to
    // swap and the FLAC simply stays on disk.
    if ([self.playlistController getIndexForTrack:track] < 0) {
        return;
    }
    // Every row holding the source: the same file can sit in the playlist
    // twice, and a row left behind would point at a file about to be trashed.
    NSIndexSet *rows = [self.playlistController indexesOfTracksWithURL:track.url];
    NSUInteger currentRow = self.playlistController.currentIndex;
    // Currency is the current row's, not the converted object's: mid-encode
    // the user can make a same-URL duplicate row current, and deciding by
    // object would swap that row out from under the player with no replay —
    // the player left holding a track the playlist has dropped, every UI tick
    // skipped by the promote guard.
    BOOL wasCurrent = [rows containsIndex:currentRow];
    // The player keeps running under these reads, so order matters: playhead
    // first — a track that ends in between yields a stale-but-real position,
    // where reading after would give a just-stopped player's 0. isPlaying
    // covers Loading, and pairing it with isPaused rather than !isStopped
    // keeps the pair consistent when a track ends between the reads.
    NSTimeInterval position = wasCurrent ? self.audioPlayer.position : 0;
    BOOL wasPlaying = wasCurrent && self.audioPlayer.isPlaying;
    BOOL wasLoaded = wasPlaying || (wasCurrent && self.audioPlayer.isPaused);

    NSUInteger nextRow = currentRow + 1;
    __block AudioTrack *converted = nil;
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        AudioTrack *replacement = [self.playlistController replaceTrackAtIndex:row withURL:outputURL];
        if (!replacement) {
            return;
        }
        // Nothing else asks for the fresh track's metadata — the playlist
        // sweep has long finished — and without it the row falls back to its
        // filename. Just written locally, so it cannot block.
        [self.metadataCache loadMetadataNow:replacement];
        if (row == currentRow) {
            converted = replacement;
        }
        if (row == nextRow) {
            // The parked prefetch handle is path-keyed and still holds the
            // source; re-arm it or the swapped-in FLAC pays a cold open. The
            // accessor names this same row, and reads nil under On track end =
            // Pause, where there was nothing parked to re-arm.
            [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
        }
    }];
    if (!converted) {
        return;
    }

    if (wasLoaded) {
        // The replay's open renders as the Loading gap, whose Now Playing
        // publish would otherwise rewind Control Center's elapsed to 0 until
        // didStartPlaying: republishes the live position.
        self.convertSwapResumeTrack = converted;
        self.convertSwapResumePosition = position;
        // Replay the identical audio under the new URL, same playhead, same
        // play state. The entry is already swapped, so didStartPlaying:'s
        // identity guard passes and the per-track refresh comes free.
        [self.audioPlayer play:converted atPosition:position startPaused:!wasPlaying];
    }
    else if (wasCurrent) {
        // Parked at the end of the playlist: nothing to replay, but the header
        // still describes this row through displayedTrack.
        [self updateUI];
    }
}

#pragma mark - Undo and redo

// Explicitly the window's manager — its lazily created NSUndoManager is the
// app's one undo stack.
- (IBAction)undo:(id)sender {
    NSUndoManager *manager = self.window.undoManager;
    if (!self.isConversionUndoRedoInFlight && manager.canUndo) {
        [manager undo];
    }
}

- (IBAction)redo:(id)sender {
    NSUndoManager *manager = self.window.undoManager;
    if (!self.isConversionUndoRedoInFlight && manager.canRedo) {
        [manager redo];
    }
}

- (void)registerUndoOfConversion:(VibeFLACConversionRecord *)record {
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] undoConversion:record];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];
}

// Edit > Undo of a conversion: put the trashed original back, return its
// playlist row to it, then trash the FLAC. Restore first because the swap
// replays the row from the restored file; FLAC last because the swap is what
// stops the row and the player from pointing at the file about to be moved.
- (void)undoConversion:(VibeFLACConversionRecord *)record {
    // Register the inverse here, synchronously and BEFORE any bail-out: only
    // while the manager isUndoing does a registration land on the redo stack,
    // and the file moves below outlive this invocation. Both directions
    // therefore re-check reality against the record rather than trusting that
    // the moves landed. The ordering also matters for the in-flight bail
    // below: NSUndoManager has already popped this action, so returning
    // without a registration would drop the conversion off BOTH stacks and
    // make it permanently un-undoable.
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] redoConversion:record];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];
    // Every entry point gates on this already — the menu items validate to
    // disabled, and undo:/redo: and the debug channel refuse — so reaching
    // here means a path that bypassed them. Refuse rather than interleave two
    // move chains against one mutable record; the action stays on the stack.
    if (self.isConversionUndoRedoInFlight) {
        LogWarn(@"Undo of a conversion arrived while one was still in flight; ignoring");
        return;
    }
    self.conversionUndoRedoInFlight = YES;

    LogInfo(@"Undo conversion: source=%@ (trash: %@), output=%@ (trash: %@)",
            record.sourceURL.path, record.sourceTrashURL.path ?: @"-",
            record.outputURL.path, record.outputTrashURL.path ?: @"-");
    __weak MainPlayerController *weakSelf = self;
    if (record.sourceLocation == VibeFLACFileLocationKnownTrashURL) {
        [self.fileConverter restoreTrashedItemAtURL:record.sourceTrashURL
                                              toURL:record.sourceURL
                                         completion:^(BOOL restored, NSError *error) {
            MainPlayerController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!restored) {
                [strongSelf revealFailedRestoreAt:record.sourceTrashURL error:error];
                [strongSelf conversionUndoRedoDidSettleCommitted:NO reason:@"restore_failed"];
                return;
            }
            record.sourceTrashURL = nil;
            record.sourceLocation = VibeFLACFileLocationExpectedPath;
            [strongSelf verifyConversionReplacementAtURL:record.sourceURL
                                                   ready:^(MainPlayerController *controller) {
                [controller finishUndoConversion:record];
            }];
        }];
    }
    else if (record.sourceLocation == VibeFLACFileLocationExpectedPath) {
        [self verifyConversionReplacementAtURL:record.sourceURL
                                         ready:^(MainPlayerController *controller) {
            [controller finishUndoConversion:record];
        }];
    }
    else {
        [self conversionReplacementLocationIsUnknown:record.sourceURL];
    }
}

- (void)conversionReplacementLocationIsUnknown:(NSURL *)url {
    LogError(@"Conversion undo/redo kept the current file because the Trash did not return a location for %@",
            url.lastPathComponent);
    NSBeep();
    // Keep settlement asynchronous like every filesystem path. NSUndoManager
    // finishes moving the inverse between stacks after this invocation returns.
    __weak MainPlayerController *weakSelf = self;
    run_on_main_thread({
        [weakSelf conversionUndoRedoDidSettleCommitted:NO
                                                reason:@"replacement_location_unknown"];
    });
}

// The one commit gate for both directions. A stale record may name an absent,
// unreadable or invalid file; in every case keep the row and its currently
// playable counterpart untouched.
- (void)verifyConversionReplacementAtURL:(NSURL *)url
                                   ready:(void (^)(MainPlayerController *controller))ready {
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter verifyPlayableFileAtURL:url
                                     completion:^(BOOL playable, NSError *error) {
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (!playable) {
            LogError(@"Conversion undo/redo kept the current file because %@ could not replace it: %@",
                    url.lastPathComponent, error.localizedDescription);
            NSBeep();
            [strongSelf conversionUndoRedoDidSettleCommitted:NO
                                                      reason:@"replacement_unavailable"];
            return;
        }
        ready(strongSelf);
    }];
}

- (void)finishUndoConversion:(VibeFLACConversionRecord *)record {
    // TRAP: a failed redo still registered this undo. A non-live output means
    // the target state is already in place; outputURL may now name someone
    // else's file, so neither its row nor the path may be touched.
    if (!VibeFLACMayDisposeExpectedPath(record.outputLocation)) {
        LogInfo(@"Undo conversion: output is already away from its expected path; nothing to commit");
        [self conversionUndoRedoDidSettleCommitted:NO reason:@"already_at_target"];
        return;
    }
    // A playlist replaced since the conversion has no row to swap; the files
    // still round-trip.
    AudioTrack *flacTrack = [self.playlistController trackForURL:record.outputURL];
    LogInfo(@"Undo conversion: original is back; %@",
            flacTrack ? @"returning its row to it" : @"no row holds the FLAC, files only");
    if (flacTrack) {
        [self swapConvertedTrack:flacTrack toURL:record.sourceURL];
    }
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter trashItemAtURL:record.outputURL
                            completion:^(VibeTrashOutcome outcome,
                                         NSURL *trashedURL,
                                         NSError *error) {
        if (outcome == VibeTrashOutcomeMovedKnownURL) {
            record.outputTrashURL = trashedURL;
            record.outputLocation = VibeFLACFileLocationKnownTrashURL;
        }
        else if (outcome == VibeTrashOutcomeMovedUnknownURL) {
            record.outputTrashURL = nil;
            record.outputLocation = VibeFLACFileLocationUnknownTrashURL;
            LogWarn(@"Undo trashed %@ without a location for redo",
                    record.outputURL.lastPathComponent);
        }
        else {
            record.outputTrashURL = nil;
            record.outputLocation = VibeFLACFileLocationExpectedPath;
        }
        if (outcome == VibeTrashOutcomeFailed) {
            // Non-fatal: the FLAC stays beside the restored original, and
            // redo finds it in place through the nil outputTrashURL.
            LogError(@"Undo could not trash the FLAC %@: %@",
                    record.outputURL.lastPathComponent, error.localizedDescription);
        }
        MainPlayerController *strongSelf = weakSelf;
        [strongSelf.fileConverter refreshDestinationStateForTrack:strongSelf.playlistController.currentTrack];
        [strongSelf conversionUndoRedoDidSettleCommitted:YES reason:nil];
    }];
}

// Edit > Redo, the mirror image: restore the FLAC from the Trash, give it
// the row back, then re-trash the original if the conversion had.
- (void)redoConversion:(VibeFLACConversionRecord *)record {
    // Same constraints as undoConversion:, mirrored: only while isRedoing does
    // this registration land back on the undo stack, and it precedes the
    // in-flight bail so a refused redo is not also a lost one.
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] undoConversion:record];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];
    if (self.isConversionUndoRedoInFlight) {
        LogWarn(@"Redo of a conversion arrived while one was still in flight; ignoring");
        return;
    }
    self.conversionUndoRedoInFlight = YES;

    LogInfo(@"Redo conversion: source=%@ (trash: %@), output=%@ (trash: %@)",
            record.sourceURL.path, record.sourceTrashURL.path ?: @"-",
            record.outputURL.path, record.outputTrashURL.path ?: @"-");
    __weak MainPlayerController *weakSelf = self;
    if (record.outputLocation == VibeFLACFileLocationKnownTrashURL) {
        [self.fileConverter restoreTrashedItemAtURL:record.outputTrashURL
                                              toURL:record.outputURL
                                         completion:^(BOOL restored, NSError *error) {
            MainPlayerController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!restored) {
                [strongSelf revealFailedRestoreAt:record.outputTrashURL error:error];
                [strongSelf conversionUndoRedoDidSettleCommitted:NO reason:@"restore_failed"];
                return;
            }
            record.outputTrashURL = nil;
            record.outputLocation = VibeFLACFileLocationExpectedPath;
            [strongSelf verifyConversionReplacementAtURL:record.outputURL
                                                   ready:^(MainPlayerController *controller) {
                [controller finishRedoConversion:record];
            }];
        }];
    }
    else if (record.outputLocation == VibeFLACFileLocationExpectedPath) {
        [self verifyConversionReplacementAtURL:record.outputURL
                                         ready:^(MainPlayerController *controller) {
            [controller finishRedoConversion:record];
        }];
    }
    else {
        [self conversionReplacementLocationIsUnknown:record.outputURL];
    }
}

- (void)finishRedoConversion:(VibeFLACConversionRecord *)record {
    // Mirror finishUndoConversion:'s failed-inverse guard. When the source was
    // meant to stay beside the FLAC there is no disposal to protect.
    if (record.sourceWasTrashed &&
            !VibeFLACMayDisposeExpectedPath(record.sourceLocation)) {
        LogInfo(@"Redo conversion: source is already away from its expected path; nothing to commit");
        [self conversionUndoRedoDidSettleCommitted:NO reason:@"already_at_target"];
        return;
    }
    AudioTrack *sourceTrack = [self.playlistController trackForURL:record.sourceURL];
    if (sourceTrack) {
        [self swapConvertedTrack:sourceTrack toURL:record.outputURL];
    }
    [self.fileConverter refreshDestinationStateForTrack:self.playlistController.currentTrack];
    if (!record.sourceWasTrashed) {
        [self conversionUndoRedoDidSettleCommitted:YES reason:nil];
        return;
    }
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter trashItemAtURL:record.sourceURL
                            completion:^(VibeTrashOutcome outcome,
                                         NSURL *trashedURL,
                                         NSError *error) {
        if (outcome == VibeTrashOutcomeMovedKnownURL) {
            record.sourceTrashURL = trashedURL;
            record.sourceLocation = VibeFLACFileLocationKnownTrashURL;
        }
        else if (outcome == VibeTrashOutcomeMovedUnknownURL) {
            record.sourceTrashURL = nil;
            record.sourceLocation = VibeFLACFileLocationUnknownTrashURL;
            LogWarn(@"Redo trashed %@ without a location for undo",
                    record.sourceURL.lastPathComponent);
        }
        else {
            record.sourceTrashURL = nil;
            record.sourceLocation = VibeFLACFileLocationExpectedPath;
        }
        if (outcome == VibeTrashOutcomeFailed) {
            LogError(@"Redo could not re-trash the original %@: %@",
                    record.sourceURL.lastPathComponent, error.localizedDescription);
        }
        [weakSelf conversionUndoRedoDidSettleCommitted:YES reason:nil];
    }];
}

// Log and beep like a failed conversion, no alert — but a failed restore
// strands the file in the Trash, so reveal it there.
- (void)revealFailedRestoreAt:(NSURL *)trashURL error:(NSError *)error {
    LogError(@"Undo could not put %@ back: %@",
            trashURL.lastPathComponent, error.localizedDescription);
    NSBeep();
    if ([NSFileManager.defaultManager fileExistsAtPath:trashURL.path]) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[trashURL]];
    }
}

// A no-op in Release: the handler is debug-channel plumbing and nothing else
// can set it.
- (void)conversionUndoRedoDidSettleCommitted:(BOOL)committed
                                      reason:(nullable NSString *)reason {
    self.conversionUndoRedoInFlight = NO;
    // The debug channel's settled hook, if one is armed — nothing arms it in a
    // shipping build, so this is an always-nil read there rather than a
    // conditional. One shot, cleared before it runs: a handler a timed-out
    // debug command left behind must not fire on a later menu-driven undo.
    void (^handler)(BOOL, NSString *_Nullable) = self.conversionUndoRedoSettledHandler;
    self.conversionUndoRedoSettledHandler = nil;
    if (handler) {
        handler(committed, reason);
    }
}

// Convert > Delete Original. A preference, not an action: it takes effect on
// the next conversion — a running one keeps the value it was accepted with.
- (IBAction)toggleDeleteOriginalAfterConvert:(id)sender {
    AppSettings.sharedInstance.deleteOriginalAfterConvert = !AppSettings.sharedInstance.deleteOriginalAfterConvert;
}

@end
