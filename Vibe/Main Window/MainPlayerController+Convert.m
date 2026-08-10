//
//  MainPlayerController+Convert.m
//  Vibe
//

#import "MainPlayerController+Convert.h"

#import "AudioFileConverter.h"
#import "VibeStrings.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"

// One finished conversion, as NSUndoManager's invocation argument: where the
// source was, where the FLAC landed, and where the Trash holds whichever of
// them was last moved aside — nil meaning the file sits at its original path.
// Mutated in place as moves land, so one object rides both undo directions.
@interface VibeFLACConversionRecord : NSObject
@property (strong) NSURL *sourceURL;
@property (strong) NSURL *outputURL;
@property (strong) NSURL *sourceTrashURL;
@property (strong) NSURL *outputTrashURL;
// Whether the conversion trashed its source, so redo re-trashes it rather
// than re-reading a setting that may have flipped.
@property BOOL sourceWasTrashed;
@end
@implementation VibeFLACConversionRecord
@end

// The main-class surface this category reads, synthesized and implemented in
// MainPlayerController.m. Deliberately no @implementation — the same pattern
// as MainPlayerController+Menus' MenuOutlets.
@interface MainPlayerController (ConvertSupport)
@property (strong, readonly) TrackDisplayController *trackDisplay;
// The Now Playing resume hint for the swap's Loading gap; see the class
// extension. The NowPlaying category reads it, didStartPlaying: clears it.
@property (weak) AudioTrack *convertSwapResumeTrack;
@property NSTimeInterval convertSwapResumePosition;
- (void)updateUI;
@end

@implementation MainPlayerController (Convert)

#if DEBUG
// Storage is the class extension's synthesized pair.
@dynamic conversionUndoRedoSettledHandler;
#endif

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
        [strongSelf didConvertTrack:track toURL:outputURL error:error completion:reply];
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
    [self swapConvertedTrack:track toURL:outputURL];
    [self.fileConverter refreshDestinationStateForTrack:self.playlistController.currentTrack];
    // Runs whether or not the swap found a row: the FLAC is on disk either
    // way, so the source is superseded even after a mid-encode re-drop.
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter trashSourceIfEnabled:sourceURL
                                 convertedTo:outputURL
                                  completion:^(NSURL *trashedURL) {
        MainPlayerController *strongSelf = weakSelf;
        if (strongSelf) {
            VibeFLACConversionRecord *record = [VibeFLACConversionRecord new];
            record.sourceURL = sourceURL;
            record.outputURL = outputURL;
            record.sourceTrashURL = trashedURL;
            record.sourceWasTrashed = trashedURL != nil;
            [strongSelf registerUndoOfConversion:record];
        }
        completion(trashedURL != nil);
    }];
}

// Puts the finished FLAC into the rows its source occupied, so the conversion
// reads as the file changing format in place. Main thread.
- (void)swapConvertedTrack:(AudioTrack *)track toURL:(NSURL *)outputURL {
    // The row the converted track occupies now, not at conversion start: a
    // mid-encode re-drop replaces the playlist, and then there is nothing to
    // swap and the FLAC simply stays on disk.
    NSInteger convertedRow = [self.playlistController getIndexForTrack:track];
    if (convertedRow < 0) {
        return;
    }
    BOOL wasCurrent = [self.playlistController isCurrentTrack:track];
    // The player keeps running under these reads, so order matters: playhead
    // first — a track that ends in between yields a stale-but-real position,
    // where reading after would give a just-stopped player's 0. isPlaying
    // covers Loading, and pairing it with isPaused rather than !isStopped
    // keeps the pair consistent when a track ends between the reads.
    NSTimeInterval position = wasCurrent ? self.audioPlayer.position : 0;
    BOOL wasPlaying = wasCurrent && self.audioPlayer.isPlaying;
    BOOL wasLoaded = wasPlaying || (wasCurrent && self.audioPlayer.isPaused);

    // Every row holding the source: the same file can sit in the playlist
    // twice, and a row left behind would point at a file about to be trashed.
    NSUInteger nextRow = self.playlistController.currentIndex + 1;
    __block AudioTrack *converted = nil;
    [[self.playlistController indexesOfTracksWithURL:track.url]
            enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        AudioTrack *replacement = [self.playlistController replaceTrackAtIndex:row withURL:outputURL];
        if (!replacement) {
            return;
        }
        // Nothing else asks for the fresh track's metadata — the playlist
        // sweep has long finished — and without it the row falls back to its
        // filename. Just written locally, so it cannot block.
        [self.metadataCache loadMetadataNow:replacement];
        if (row == (NSUInteger)convertedRow) {
            converted = replacement;
        }
        if (row == nextRow) {
            // The parked prefetch handle is path-keyed and still holds the
            // source; re-arm it or the swapped-in FLAC pays a cold open.
            [self.audioPlayer prefetchTrack:replacement];
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
    [self.window.undoManager undo];
}

- (IBAction)redo:(id)sender {
    [self.window.undoManager redo];
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
    // Register the inverse here, synchronously: only while the manager
    // isUndoing does a registration land on the redo stack, and the file
    // moves below outlive this invocation. Both directions therefore re-check
    // reality against the record rather than trusting that the moves landed.
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] redoConversion:record];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];

    LogInfo(@"Undo conversion: source=%@ (trash: %@), output=%@ (trash: %@)",
            record.sourceURL.path, record.sourceTrashURL.path ?: @"-",
            record.outputURL.path, record.outputTrashURL.path ?: @"-");
    __weak MainPlayerController *weakSelf = self;
    if (record.sourceTrashURL) {
        [self.fileConverter restoreTrashedItemAtURL:record.sourceTrashURL
                                              toURL:record.sourceURL
                                         completion:^(BOOL restored, NSError *error) {
            MainPlayerController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!restored) {
                [strongSelf revealFailedRestoreAt:record.sourceTrashURL error:error];
                [strongSelf conversionUndoRedoDidSettle];
                return;
            }
            record.sourceTrashURL = nil;
            [strongSelf finishUndoConversion:record];
        }];
    }
    else {
        // Delete Original was off, so the source never left its folder.
        [self finishUndoConversion:record];
    }
}

- (void)finishUndoConversion:(VibeFLACConversionRecord *)record {
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
                            completion:^(NSURL *trashedURL, NSError *error) {
        if (trashedURL) {
            record.outputTrashURL = trashedURL;
        }
        else {
            // Non-fatal: the FLAC stays beside the restored original, and
            // redo finds it in place through the nil outputTrashURL.
            LogError(@"Undo could not trash the FLAC %@: %@",
                    record.outputURL.lastPathComponent, error.localizedDescription);
        }
        MainPlayerController *strongSelf = weakSelf;
        [strongSelf.fileConverter refreshDestinationStateForTrack:strongSelf.playlistController.currentTrack];
        [strongSelf conversionUndoRedoDidSettle];
    }];
}

// Edit > Redo, the mirror image: restore the FLAC from the Trash, give it
// the row back, then re-trash the original if the conversion had.
- (void)redoConversion:(VibeFLACConversionRecord *)record {
    // Same constraint as undoConversion:, mirrored: only while isRedoing does
    // this registration land back on the undo stack.
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] undoConversion:record];
    [undoManager setActionName:STR_MENU_CONVERT_TO_FLAC];

    LogInfo(@"Redo conversion: source=%@ (trash: %@), output=%@ (trash: %@)",
            record.sourceURL.path, record.sourceTrashURL.path ?: @"-",
            record.outputURL.path, record.outputTrashURL.path ?: @"-");
    __weak MainPlayerController *weakSelf = self;
    if (record.outputTrashURL) {
        [self.fileConverter restoreTrashedItemAtURL:record.outputTrashURL
                                              toURL:record.outputURL
                                         completion:^(BOOL restored, NSError *error) {
            MainPlayerController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (!restored) {
                [strongSelf revealFailedRestoreAt:record.outputTrashURL error:error];
                [strongSelf conversionUndoRedoDidSettle];
                return;
            }
            record.outputTrashURL = nil;
            [strongSelf finishRedoConversion:record];
        }];
    }
    else {
        [self finishRedoConversion:record];
    }
}

- (void)finishRedoConversion:(VibeFLACConversionRecord *)record {
    AudioTrack *sourceTrack = [self.playlistController trackForURL:record.sourceURL];
    if (sourceTrack) {
        [self swapConvertedTrack:sourceTrack toURL:record.outputURL];
    }
    [self.fileConverter refreshDestinationStateForTrack:self.playlistController.currentTrack];
    if (!record.sourceWasTrashed) {
        [self conversionUndoRedoDidSettle];
        return;
    }
    __weak MainPlayerController *weakSelf = self;
    [self.fileConverter trashItemAtURL:record.sourceURL
                            completion:^(NSURL *trashedURL, NSError *error) {
        if (trashedURL) {
            record.sourceTrashURL = trashedURL;
        }
        else {
            LogError(@"Redo could not re-trash the original %@: %@",
                    record.sourceURL.lastPathComponent, error.localizedDescription);
        }
        [weakSelf conversionUndoRedoDidSettle];
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
- (void)conversionUndoRedoDidSettle {
#if DEBUG
    void (^handler)(void) = self.conversionUndoRedoSettledHandler;
    // One shot, cleared before it runs: a handler a timed-out debug command
    // left behind must not fire on a later menu-driven undo.
    self.conversionUndoRedoSettledHandler = nil;
    if (handler) {
        handler();
    }
#endif
}

// Convert > Delete Original. A preference, not an action: it takes effect on
// the next conversion — a running one keeps the value it was accepted with.
- (IBAction)toggleDeleteOriginalAfterConvert:(id)sender {
    Settings.deleteOriginalAfterConvert = !Settings.deleteOriginalAfterConvert;
}

@end
