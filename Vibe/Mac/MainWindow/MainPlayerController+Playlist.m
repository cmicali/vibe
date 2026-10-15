//
//  MainPlayerController+Playlist.m
//  Vibe
//

#import "MainPlayerController+Playlist.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Transport.h" // prefetchSuccessor

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioFileConverter.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "OpenRequestCoordinator.h"
#import "FolderAccessRules.h"
#import "PlaceholderFiles.h"
#import "PlaylistController.h"
#import "PlaylistFile.h"
#import "PlaylistFile+Session.h"
#import "VibeStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation MainPlayerController (Playlist)

#pragma mark - Close and save

- (IBAction)closeFile:(nullable id)sender {
    [self unloadPlaybackClearingPlaylist:YES];
}

// Close's teardown. A removal that empties the list keeps its structure, and
// with it every older undo registration, so it passes NO.
// stop sends no callback, so nothing auto-advances; didFinishPlaying:'s stale
// guard drops one already in flight.
- (void)unloadPlaybackClearingPlaylist:(BOOL)clear {
    [OpenRequestCoordinator.sharedCoordinator invalidate];
    [self endLoadingProgress];
    [self.audioPlayer stop];
    [self.waveformCache cancelLoad];
    if (clear) {
        [self.playlistController clear];
    }
    // A cancelled scan loader still holds every queued track; drop it.
    [self cancelDeferredMetadataLoad];
    [self.metadataCache cancelScan];
    [self clearErrorMask];
    _unplayablePlaylistName = nil;
    _emptyStateSuppressed = NO; // Close explicitly asks for the empty state
    _currentTrackDuration = 0;
    [self pauseUIUpdateTimer];
    [self endNotice];
    [self updateUI];
}

// Seeded from the tracks' common folder, so a folder's playlist lands beside
// its music.
- (IBAction)savePlaylist:(nullable id)sender {
    NSURL *common = [PlaylistFile commonDirectoryForTracks:self.playlistController.playlist];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeM3UPlaylist];
    panel.directoryURL = common;   // nil: the panel's own default
    panel.nameFieldStringValue = [(common.lastPathComponent ?: STR_PLAYLIST_SAVE_DEFAULT_NAME)
                                  stringByAppendingString:@".m3u"];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSError *error = nil;
        if (![self writePlaylistToURL:panel.URL error:&error]) {
            // A panel that just closes is indistinguishable from a saved file.
            [[NSAlert alertWithError:error] beginSheetModalForWindow:self.window completionHandler:nil];
        }
    }];
}

- (BOOL)writePlaylistToURL:(NSURL *)url error:(NSError **)error {
    // Relative to the chosen file's folder, which the reader resolves against.
    if (![PlaylistFile writeM3UForTracks:self.playlistController.playlist
                     relativeToDirectory:url.URLByDeletingLastPathComponent
                                   toURL:url error:error]) {
        return NO;
    }
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
    return YES;
}

#pragma mark - The last playlist

// The container mirror: absolute paths, never in Open Recent. The cursor is a
// defaults key written with the mirror; it is state, not a preference, so
// resetToDefaults leaves it.
static NSURL *VibeLastPlaylistURL(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                            NSUserDomainMask, YES).firstObject;
    NSString *dir = [support stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier];
    return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"LastPlaylist.m3u"] isDirectory:NO];
}

- (void)saveLastPlaylist {
    NSError *error = nil;
    if (![PlaylistFile saveSessionTracks:self.playlistController.playlist
            currentIndex:self.playlistController.currentIndex enabled:AppSettings.sharedInstance.reopenLastPlaylist
            toURL:VibeLastPlaylistURL() defaults:NSUserDefaults.standardUserDefaults write:nil error:&error]) {
        LogError(@"Last playlist not saved: %@", error.localizedDescription);
    }
}

- (void)removeLastPlaylist {
    [PlaylistFile removeSessionAtURL:VibeLastPlaylistURL() defaults:NSUserDefaults.standardUserDefaults];
}

- (BOOL)restoreLastPlaylist {
    return [PlaylistFile restoreSessionAtURL:VibeLastPlaylistURL()
            enabled:AppSettings.sharedInstance.reopenLastPlaylist defaults:NSUserDefaults.standardUserDefaults
            load:^(NSArray<AudioTrack *> *rows, NSUInteger index, BOOL paused) {
        [self loadTracks:rows selectingIndex:index startPaused:paused];
    }];
}

- (BOOL)loadWelcomeTrack {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"vibe-theme" withExtension:@"mp3"];
    if (!url || AppSettings.sharedInstance.welcomeTrackSpent) return NO;
    [self loadTracks:@[[[AudioTrack alloc] initWithURL:url]] selectingIndex:0 startPaused:YES];
    return YES;
}

// Spent by the user's first play or open, not by the park: a user who updates
// before doing either would otherwise lose the track to the relaunch.
- (void)spendWelcomeTrack {
    if (!AppSettings.sharedInstance.welcomeTrackSpent) {
        AppSettings.sharedInstance.welcomeTrackSpent = YES;
    }
}

- (void)applyReopenLastPlaylist {
    if (!AppSettings.sharedInstance.reopenLastPlaylist) {
        [self removeLastPlaylist];   // off means forget, not merely stop writing
    }
}

#pragma mark - Playlist editing

// Called from the index funnel and from structural edits, which that funnel
// does not fire for.
- (void)updateMetadataNeighborhood {
    [self.metadataCache setNeighborhoodTracks:self.playlistController.neighborhoodTracks];
}

- (IBAction)removeSelectedPlaylistTracks:(nullable id)sender {
    NSArray<AudioTrack *> *tracks = self.playlistController.selectedTracks;
    if (tracks.count == 0) {
        return;
    }
    [self removePlaylistTracks:tracks];
}

// Remove from Playlist: the funnel plus Remove's undo.
- (void)removePlaylistTracks:(NSArray<AudioTrack *> *)tracks {
    // A held playlist is waiting for Move to Trash's undo to land its rows.
    if (self.isFileMoveInFlight) {
        return;
    }
    PlaylistController *playlist = self.playlistController;
    // Each exact object once; departed ones drop out.
    NSIndexSet *rows = [playlist rowsForTracks:tracks];
    // Removing every row is File > Close, which stays un-undoable.
    if (rows.count > 0 && rows.count == playlist.count) {
        [self closeFile:nil];
        return;
    }
    NSArray<AudioTrack *> *removed = [self removePlaylistRows:rows];
    if (removed.count == 0) {
        return;
    }
    // Undo restores the exact objects to their rows and never touches
    // transport. The generation keeps a restore off a replaced playlist.
    // Registering after the mutation is fine: both share this turn's group.
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self]
            reinsertPlaylistTracks:removed
                         atIndexes:rows
                        generation:playlist.structureGeneration];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];
}

// The one removal funnel, and the only place a removal's playback consequences
// are decided: Playlist.removeTracksAtIndexes: touches no audio, so removing
// the current row there alone would leave the player sounding a track the
// playlist no longer holds, and every identity guard would read its events as
// stale. It touches no file and registers no undo; each caller registers its
// own. Answers the removed tracks in row order.
- (NSArray<AudioTrack *> *)removePlaylistRows:(NSIndexSet *)rows {
    PlaylistController *playlist = self.playlistController;
    if (rows.count == 0) {
        return @[];
    }

    NSUInteger currentIndex = playlist.currentIndex;
    BOOL removingCurrent = [rows containsIndex:currentIndex];
    // Only a removed current row with a surviving forward successor keeps
    // sounding; otherwise the cursor moves back, and removal never replays
    // backward. The intent resolves behind every transport command already
    // queued, and the model's query keeps other edits off that round trip.
    VibePendingPlaybackIntent intent;
    BOOL continuesPlaying = [playlist forwardTrackAfterRemovingTracksAtIndexes:rows] != nil
            && [self.audioPlayer getPlaybackIntent:&intent forTrack:nil]
            && !intent.paused;

    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
    // Departed rows must not spend a provider transfer; undo re-requests them.
    for (AudioTrack *track in removed) {
        [self.metadataCache abandonQueuedTrack:track];
    }
    // TRAP: emptied as an edit, never a clear. A clear bumps the generation,
    // which retires every older undo registration.
    if (playlist.count == 0) {
        [self unloadPlaybackClearingPlaylist:NO];
        return removed;
    }
    // The cursor callback is not raised for a structural edit, so this is the
    // removal's one reconciliation.
    if (!removingCurrent) {
        // The current track survived; only the successor can have moved.
        [self reconcileAfterPlaylistStructureEdit];
        return removed;
    }
    [self updateMetadataNeighborhood];

    // The current row is gone. The play funnel repaints at submission, brings
    // didStartPlaying:'s per-track refresh, and mints a newer play identity so
    // the removed open's settlement dies on submittedPlayIsCurrent:.
    [self clearErrorMask];
    // A fast local replacement never reaches didBeginLoading: to replace it.
    [self endLoadingProgress];
    BOOL startPaused = !continuesPlaying;
    if (startPaused) {
        // A slow parked open must not keep the UI tick running.
        [self pauseUIUpdateTimer];
    }
    [playlist playStartPaused:startPaused];
    return removed;
}

// The tail of every structural edit once the model is final.
- (void)reconcileAfterPlaylistStructureEdit {
    [self prefetchSuccessor];
    [self updateMetadataNeighborhood];
    [self updateUI];
}

// The removal's undo. The redo registration precedes the generation bail, so
// a refused restore is not also a lost one; a dead pair's redo no-ops in
// removePlaylistTracks:'s departed-object guard. Transport is untouched: a
// removed current row does not replay.
- (void)reinsertPlaylistTracks:(NSArray<AudioTrack *> *)tracks
                     atIndexes:(NSIndexSet *)indexes
                    generation:(NSUInteger)generation {
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self] removePlaylistTracks:tracks];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];
    [self restorePlaylistTracks:tracks atIndexes:indexes generation:generation];
}

// The row half of both removal undos. A replaced playlist takes nothing back.
- (void)restorePlaylistTracks:(NSArray<AudioTrack *> *)tracks
                    atIndexes:(NSIndexSet *)indexes
                   generation:(NSUInteger)generation {
    PlaylistController *playlist = self.playlistController;
    if (generation != playlist.structureGeneration) {
        return;
    }
    // Only Move to Trash empties the list as an edit, and nothing is loaded
    // then. Rows with nothing loaded would rest in Loading.
    BOOL emptied = playlist.count == 0;
    [playlist insertTracks:tracks atIndexes:indexes];
    // Re-requests the scan work abandoned at removal.
    for (AudioTrack *track in tracks) {
        [self.metadataCache loadMetadataNow:track];
    }
    if (!emptied) {
        [self reconcileAfterPlaylistStructureEdit];
        return;
    }
    // Parked on the cursor's row, as a removal parks. The play funnel
    // repaints and prefetches.
    [self updateMetadataNeighborhood];
    [self pauseUIUpdateTimer];
    [playlist playStartPaused:YES];
}

// A reorder's undo and redo. A replaced playlist, or indexes the model
// refuses, move nothing and register nothing.
- (void)movePlaylistTracksFromIndexes:(NSIndexSet *)sourceIndexes
                            toIndexes:(NSIndexSet *)destinationIndexes
                           generation:(NSUInteger)generation {
    if (generation != self.playlistController.structureGeneration) {
        return;
    }
    [self.playlistController moveTracksAtIndexes:sourceIndexes
                                       toIndexes:destinationIndexes];
}

#pragma mark - Move to Trash

- (IBAction)moveSelectedPlaylistTracksToTrash:(nullable id)sender {
    [self trashPlaylistTracks:self.playlistController.selectedTracks];
}

- (void)trashPlaylistTracks:(NSArray<AudioTrack *> *)tracks {
    // Rows whose files are still moving would trash or restore twice.
    if (self.isFileMoveInFlight) {
        return;
    }
    // The app's own files are not the user's to trash: the bundled welcome
    // track, and an Open URL link's copy, which its store owns.
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSMutableOrderedSet<NSURL *> *urls = [NSMutableOrderedSet orderedSet];
    for (AudioTrack *track in tracks) {
        NSURL *url = track.url;
        if (url.isFileURL && !VibeUncanonicalPathIsUnderFolder(url.path, bundle)
                && !VibePathIsUnderRemotePlaceholderRoot(url.path)) {
            [urls addObject:url];
        }
    }
    if (urls.count == 0) {
        NSBeep();
        return;
    }
    [self moveFilesToTrash:[urls.array copy] trashURLs:[NSMutableDictionary dictionary]];
}

// Move to Trash, and its redo. Every row of each file goes at once, found by
// URL as the model indexes rows: all of a cue image's rows share its URL, and
// a duplicate row must not outlive its file. The rows leave through the
// funnel, so the player lets go of a removed current file before it moves.
- (void)moveFilesToTrash:(NSArray<NSURL *> *)urls
               trashURLs:(NSMutableDictionary<NSURL *, id> *)trashURLs {
    PlaylistController *playlist = self.playlistController;
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSURL *url in urls) {
        [rows addIndexes:[playlist indexesOfTracksWithURL:url]];
    }
    NSUInteger generation = playlist.structureGeneration;
    NSArray<AudioTrack *> *tracks = [self removePlaylistRows:rows];
    NSUndoManager *undoManager = self.window.undoManager;
    [undoManager registerUndoWithTarget:self handler:^(MainPlayerController *controller) {
        [controller putBackFiles:urls tracks:tracks atIndexes:rows
                      generation:generation trashURLs:trashURLs];
    }];
    [undoManager setActionName:STR_MENU_EDIT_MOVE_TO_TRASH];
    [self moveFiles:urls toTrash:YES trashURLs:trashURLs completion:nil];
}

// Move to Trash's undo. The rows come back only once their files are back,
// so no prefetch or play reaches a file still in the Trash. The playlist is
// held until then (fileMoveInFlight), so every older registration's row
// numbers still hold when the rows land.
- (void)putBackFiles:(NSArray<NSURL *> *)urls
              tracks:(NSArray<AudioTrack *> *)tracks
           atIndexes:(NSIndexSet *)rows
          generation:(NSUInteger)generation
           trashURLs:(NSMutableDictionary<NSURL *, id> *)trashURLs {
    // TRAP: register the opposite first, synchronously. NSUndoManager's stack
    // direction is active only now, and the file moves settle later.
    NSUndoManager *undoManager = self.window.undoManager;
    [undoManager registerUndoWithTarget:self handler:^(MainPlayerController *controller) {
        [controller moveFilesToTrash:urls trashURLs:trashURLs];
    }];
    [undoManager setActionName:STR_MENU_EDIT_MOVE_TO_TRASH];
    [self moveFiles:urls toTrash:NO trashURLs:trashURLs completion:^{
        [self restorePlaylistTracks:tracks atIndexes:rows generation:generation];
    }];
}

// One direction of Move to Trash's file moves, through the converter's
// coordinated trash and restore, off main. trashURLs maps each file to its
// place in the Trash, or to NSNull when the Trash moved it without saying
// where (VibeTrashOutcomeMovedUnknownURL). Both directions rewrite it, so a
// file one direction could not move is skipped by the next rather than
// failing twice.
- (void)moveFiles:(NSArray<NSURL *> *)urls
          toTrash:(BOOL)toTrash
        trashURLs:(NSMutableDictionary<NSURL *, id> *)trashURLs
       completion:(nullable void (^)(void))completion {
    self.playlistController.structureEditsHeld = YES;
    __block NSError *failure = nil;
    dispatch_group_t group = dispatch_group_create();
    // The completions run on main, so trashURLs needs no lock. A nil place
    // removes the file's entry.
    void (^settle)(NSURL *, id, NSError *) = ^(NSURL *url, id place, NSError *error) {
        trashURLs[url] = place;
        failure = failure ?: error;
        dispatch_group_leave(group);
    };
    for (NSURL *url in urls) {
        id place = trashURLs[url];
        // TRAP: a file moved to an unknown place is never touched again. Its
        // path is no proof of where it is: redo would trash a stranger there.
        if (place == NSNull.null || (place != nil) == toTrash) {
            continue;
        }
        dispatch_group_enter(group);
        if (toTrash) {
            [self.fileConverter trashItemAtURL:url completion:^(VibeTrashOutcome outcome, NSURL *trashedURL, NSError *error) {
                id moved = outcome == VibeTrashOutcomeMovedUnknownURL ? NSNull.null : nil;
                settle(url, outcome == VibeTrashOutcomeMovedKnownURL ? trashedURL : moved,
                       outcome == VibeTrashOutcomeFailed ? error : nil);
            }];
        } else {
            NSURL *trashURL = place;
            [self.fileConverter restoreTrashedItemAtURL:trashURL toURL:url completion:^(BOOL restored, NSError *error) {
                settle(url, restored ? nil : trashURL, restored ? nil : error);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.playlistController.structureEditsHeld = NO;
        if (completion) {
            completion();
        }
        if (failure) {
            [[NSAlert alertWithError:failure] beginSheetModalForWindow:self.window completionHandler:nil];
        }
        [self undoRedoDidSettleCommitted:failure == nil reason:failure ? @"file_move_failed" : nil];
    });
}

#if DEBUG
- (NSDictionary *)debugLastPlaylistDictionary {
    return @{
        @"exists": @([NSFileManager.defaultManager fileExistsAtPath:VibeLastPlaylistURL().path]),
        @"rows": @([PlaylistFile rowsInM3UData:[NSData dataWithContentsOfURL:VibeLastPlaylistURL()]].count),
        @"currentIndex": @([NSUserDefaults.standardUserDefaults integerForKey:kVibeLastPlaylistCurrentIndexKey]),
    };
}
#endif

@end
