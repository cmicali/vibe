//
//  MainPlayerController+Playlist.m
//  Vibe
//

#import "MainPlayerController+Playlist.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Transport.h" // prefetchSuccessor

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "OpenRequestCoordinator.h"
#import "PlaylistController.h"
#import "PlaylistFile.h"
#import "VibeStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation MainPlayerController (Playlist)

#pragma mark - Close and save

// stop sends no callback, so nothing auto-advances; didFinishPlaying:'s stale
// guard drops one already in flight.
- (IBAction)closeFile:(nullable id)sender {
    [OpenRequestCoordinator.sharedCoordinator invalidate];
    [self endLoadingProgress];
    [self.audioPlayer stop];
    [self.waveformCache cancelLoad];
    [self.playlistController clear];
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
    if (!url) return NO;
    [self loadTracks:@[[[AudioTrack alloc] initWithURL:url]] selectingIndex:0 startPaused:YES];
    return YES;
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

// The one removal funnel, and the only place a removal's playback consequences
// are decided: Playlist.removeTracksAtIndexes: touches no audio, so removing
// the current row there alone would leave the player sounding a track the
// playlist no longer holds, and every identity guard would read its events as
// stale. The files are never touched.
- (void)removePlaylistTracks:(NSArray<AudioTrack *> *)tracks {
    PlaylistController *playlist = self.playlistController;
    // Each exact object once; departed ones drop out.
    NSIndexSet *rows = [playlist rowsForTracks:tracks];
    if (rows.count == 0) {
        return;
    }
    // Removing every row is an unload, which closeFile: owns whole.
    if (rows.count == playlist.count) {
        [self closeFile:nil];
        return;
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

    // Undo restores the exact objects to their rows and never touches
    // transport. The generation keeps a restore off a replaced playlist.
    // Registering after the mutation is fine: both share this turn's group.
    NSArray<AudioTrack *> *removed = [playlist removeTracksAtIndexes:rows];
    NSUndoManager *undoManager = self.window.undoManager;
    [[undoManager prepareWithInvocationTarget:self]
            reinsertPlaylistTracks:removed
                         atIndexes:rows
                        generation:playlist.structureGeneration];
    [undoManager setActionName:STR_MENU_EDIT_REMOVE_FROM_PLAYLIST];

    // Departed rows must not spend a provider transfer; undo re-requests them.
    for (AudioTrack *track in removed) {
        [self.metadataCache abandonQueuedTrack:track];
    }
    // The cursor callback is not raised for a structural edit, so this is the
    // removal's one reconciliation.
    if (!removingCurrent) {
        // The current track survived; only the successor can have moved.
        [self reconcileAfterPlaylistStructureEdit];
        return;
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
    if (generation != self.playlistController.structureGeneration) {
        return;
    }
    [self.playlistController insertTracks:tracks atIndexes:indexes];
    // Re-requests the scan work abandoned at removal.
    for (AudioTrack *track in tracks) {
        [self.metadataCache loadMetadataNow:track];
    }
    [self reconcileAfterPlaylistStructureEdit];
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
