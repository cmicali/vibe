//
//  MainPlayerController+Convert.m
//  Vibe
//

#import "MainPlayerController+Convert.h"
#import "MainPlayerControllerInternal.h"

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFileConverter.h"
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

// Swaps first, then disposes of the source: the swap stops the row and the
// player pointing at the file about to go. completion runs on every path.
- (void)didConvertTrack:(AudioTrack *)track
                  toURL:(NSURL *)outputURL
                  error:(NSError *)error
             completion:(void (^)(BOOL sourceDeleted))completion {
    // Not while one still runs: this may be a busy rejection, and a reset
    // would re-dip everything the live sweep has covered.
    if (!self.fileConverter.isConverting) {
        [self.trackDisplay setConvertSweepFraction:0];
    }
    if (!outputURL) {
        // A dismissed save panel is not a failure. Failures beep and log.
        if (!([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError)) {
            LogError(@"Convert to FLAC failed: %@", error.localizedDescription);
            NSBeep();
        }
        completion(NO);
        return;
    }
    // Pinned to a plain path (MainWindow's file-reference trap): the undo
    // record must not follow the source into the Trash. A vanished file's
    // reference URL has a nil path, which fileURLWithPath: throws on.
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
    // Whether or not the swap found a row: the FLAC supersedes the source.
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

- (void)swapConvertedTrack:(AudioTrack *)track toURL:(NSURL *)outputURL {
    // By URL, even if the converting row was removed or the playlist replaced:
    // every surviving duplicate must move before disposal.
    NSIndexSet *rows = [self.playlistController indexesOfTracksWithURL:track.url];
    if (rows.count == 0) {
        return;
    }
    NSUInteger currentRow = self.playlistController.currentIndex;
    // Currency is the current row's, not the converted object's: a same-URL
    // duplicate made current mid-encode would otherwise be swapped out from
    // under the player with no replay.
    BOOL wasCurrent = [rows containsIndex:currentRow];
    VibePendingPlaybackIntent intent;
    BOOL wasLoaded = wasCurrent && [self.audioPlayer getPlaybackIntent:&intent
                                               forTrack:self.playlistController.currentTrack];

    NSUInteger nextRow = currentRow + 1;
    __block AudioTrack *converted = nil;
    rows = [self.playlistController replaceTracksMatchingTrack:track withURL:outputURL];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        AudioTrack *replacement = [self.playlistController trackAtIndex:row];
        if (!replacement) {
            return;
        }
        // Nothing else asks for the fresh track's metadata; the file is local.
        [self.metadataCache loadMetadataNow:replacement];
        if (row == currentRow) {
            converted = replacement;
        }
        if (row == nextRow) {
            // The parked handle is path-keyed and still holds the source.
            [self.audioPlayer prefetchTrack:self.successorPrefetchTrack];
        }
    }];
    if (!converted) {
        return;
    }

    if (wasLoaded) {
        // Or Now Playing rewinds to 0 through the replay's Loading gap.
        self.convertSwapResumeTrack = converted;
        self.convertSwapResumePosition = intent.position;
        // The entry is already swapped, so didStartPlaying:'s identity guard
        // passes and the per-track refresh comes free.
        [self.audioPlayer play:converted atPosition:intent.position startPaused:intent.paused];
    }
    else if (wasCurrent) {
        // Parked: nothing to replay, but the header describes this row.
        [self updateUI];
    }
}

#pragma mark - Undo and redo

// The window's manager is the player's one undo stack.
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

// A failed restore strands the file in the Trash, so reveal it there.
- (void)revealFailedRestoreAt:(NSURL *)trashURL error:(NSError *)error {
    LogError(@"Undo could not put %@ back: %@",
            trashURL.lastPathComponent, error.localizedDescription);
    NSBeep();
    if ([NSFileManager.defaultManager fileExistsAtPath:trashURL.path]) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[trashURL]];
    }
}

- (void)conversionUndoRedoDidSettleCommitted:(BOOL)committed
                                      reason:(nullable NSString *)reason {
    // Always nil in a shipping build. One shot, cleared before it runs: a
    // timed-out debug command's handler must not fire on a later undo.
    void (^handler)(BOOL, NSString *_Nullable) = self.conversionUndoRedoSettledHandler;
    self.conversionUndoRedoSettledHandler = nil;
    if (handler) {
        handler(committed, reason);
    }
}

- (IBAction)toggleDeleteOriginalAfterConvert:(id)sender {
    AppSettings.sharedInstance.deleteOriginalAfterConvert = !AppSettings.sharedInstance.deleteOriginalAfterConvert;
}

@end
