//
//  MainPlayerController+Playlist.h
//  Vibe
//
//  The playlist edits the shell owns: Close, Save Playlist, the last playlist,
//  removing and moving rows with their undo, and Move to Trash. The model
//  touches no audio, so each edit's playback consequences are decided here.
//

#import "MainPlayerController.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (Playlist)

- (IBAction)closeFile:(nullable id)sender;

// The playlist as M3U; the audio files are never touched.
- (IBAction)savePlaylist:(nullable id)sender;
// Extended M3U, noted in Open Recent; the playlist is snapshotted at the
// write. Shared with the save_playlist debug verb.
- (BOOL)writePlaylistToURL:(NSURL *)url error:(NSError **)error;

// YES when the mirror came back, parked on its last current row; NO when the
// setting is off or nothing was saved. Not an open (Mac/App/AGENTS.md).
- (BOOL)restoreLastPlaylist;
// Parks the bundled vibe-theme.mp3 until it has been played once.
- (BOOL)loadWelcomeTrack;
// From every open, and from the two deliveries that mean sound: a playing
// start and a resume.
- (void)spendWelcomeTrack;
// Quit-time: writes the mirror, or deletes it when off or empty.
- (void)saveLastPlaylist;
- (void)applyReopenLastPlaylist;

// Removes every selected row, never the file. A removed current row hands its
// play intent to its forward successor, or parks on the row before.
- (IBAction)removeSelectedPlaylistTracks:(nullable id)sender;
- (void)removePlaylistTracks:(NSArray<AudioTrack *> *)tracks;
// Moves every selected row's file to the Trash and removes every row of each
// file: all of a cue sheet's rows, and any duplicate. Undo puts the files
// back and restores the rows; redo trashes them again.
- (IBAction)moveSelectedPlaylistTracksToTrash:(nullable id)sender;
- (void)trashPlaylistTracks:(NSArray<AudioTrack *> *)tracks;
- (void)movePlaylistTracksFromIndexes:(NSIndexSet *)sourceIndexes
                            toIndexes:(NSIndexSet *)destinationIndexes
                           generation:(NSUInteger)generation;
- (void)reconcileAfterPlaylistStructureEdit;
- (void)updateMetadataNeighborhood;

@end

NS_ASSUME_NONNULL_END
