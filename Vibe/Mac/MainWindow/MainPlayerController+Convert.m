//
//  MainPlayerController+Convert.m
//  Vibe
//

#import "MainPlayerController+Convert.h"
#import "MainPlayerControllerInternal.h"

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFileConverter.h"
#import "FLACConvertRules.h"
#import "VibeStrings.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"

@implementation MainPlayerController (Convert)

#pragma mark - Convert to FLAC

- (IBAction)convertCurrentTrackToFLAC:(id)sender {
    AudioTrack *track = self.playlistController.currentTrack;
    if (track) {
        [self convertTrackToFLAC:track completion:nil];
    }
}

- (IBAction)cancelConversion:(id)sender {
    [self.fileConverter cancelConversionWithCompletion:nil];
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
    // Follow the source URL even if the converting row was removed or the
    // playlist replaced. Every surviving duplicate must move before disposal.
    NSIndexSet *rows = [self.playlistController indexesOfTracksWithURL:track.url];
    if (rows.count == 0) {
        return;
    }
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
    VibePendingPlaybackIntent intent;
    BOOL wasLoaded = VibeFLACSwapPlaybackIntent(wasCurrent, position, wasPlaying,
            wasCurrent && !wasPlaying && self.audioPlayer.isPaused, &intent);

    NSUInteger nextRow = currentRow + 1;
    __block AudioTrack *converted = nil;
    rows = [self.playlistController replaceTracksMatchingTrack:track withURL:outputURL];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        AudioTrack *replacement = [self.playlistController trackAtIndex:row];
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
        self.convertSwapResumePosition = intent.position;
        // Replay the identical audio under the new URL, same playhead, same
        // play state. The entry is already swapped, so didStartPlaying:'s
        // identity guard passes and the per-track refresh comes free.
        [self.audioPlayer play:converted atPosition:intent.position startPaused:intent.paused];
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

- (BOOL)isConversionUndoRedoInFlight {
    return self.fileConverter.isUndoRedoInFlight;
}

- (void)registerUndoOfConversion:(VibeFLACConversionRecord *)record {
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter registerUndoForConversion:record undoManager:self.window.undoManager
            swap:^(NSURL *from, NSURL *to) {
        MainPlayerController *controller = weakSelf;
        AudioTrack *track = [controller.playlistController trackForURL:from];
        if (track) [controller swapConvertedTrack:track toURL:to];
    } completion:^(BOOL committed, NSString *reason, NSURL *strandedURL, NSError *error) {
        MainPlayerController *controller = weakSelf;
        if ([reason isEqualToString:@"restore_failed"]) {
            [controller revealFailedRestoreAt:strandedURL error:error];
        } else if ([reason isEqualToString:@"replacement_unavailable"]
                || [reason isEqualToString:@"replacement_location_unknown"]) {
            LogError(@"Conversion undo/redo kept the current file: %@ (%@)", reason, error);
            NSBeep();
        }
        [controller.fileConverter refreshDestinationStateForTrack:controller.playlistController.currentTrack];
        [controller conversionUndoRedoDidSettleCommitted:committed reason:reason];
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
