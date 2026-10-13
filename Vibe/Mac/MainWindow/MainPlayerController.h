//
//  MainPlayerController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class AudioPlayer;
@class PlaylistController;
@class AudioTrack;
@class AudioTrackMetadataCache;
@class AudioWaveformCache;
@class AudioFileConverter;
@class OutputDevicesMenuController;

NS_ASSUME_NONNULL_BEGIN

// Outlets and most conformances are in MainPlayerControllerInternal.h, the
// debug surface in MainPlayerController+Debug.h. NSMenuDelegate is public
// because MainMenuBuilder makes the controller View > Theme's delegate.
@interface MainPlayerController : NSWindowController <NSMenuDelegate>

// Created once in init and never replaced, so no caller can orphan a
// collaborator's delegate wiring.
@property (readonly, strong) OutputDevicesMenuController *devicesMenuController;
@property (readonly, strong) AudioPlayer *audioPlayer;
@property (readonly, strong) PlaylistController *playlistController;
@property (readonly, strong) AudioTrackMetadataCache *metadataCache;
@property (readonly, strong) AudioWaveformCache *waveformCache;
@property (readonly, strong) AudioFileConverter *fileConverter;

- (void)play:(NSArray<AudioTrack *> *)tracks;

// The varispeed rate, 1.0 + pitch/100. Time labels and Now Playing show file
// time divided by it.
- (double)playbackRate;

// Appends without disturbing playback; plays when the playlist is empty.
- (void)addTracks:(NSArray<AudioTrack *> *)tracks;

// Ends the launch grace, which keeps the header blank rather than flashing the
// empty state while a launch-time open resolves. play: ends it too. `name` is
// an opened playlist that listed nothing playable, which the empty header
// shows until the next load or Close; nil for none. Idempotent.
- (void)revealEmptyStateNamingPlaylist:(nullable NSString *)name;

// A dropped link's resolve shows the waveform's loading shimmer. An append
// over a shown track shows nothing, since that track's waveform stays. The
// end puts back what the header shows. It leaves the strip to a track's open
// still in flight.
- (void)beginLinkResolveFeedbackAppending:(BOOL)append;
- (void)endLinkResolveFeedback;

// A link that failed to open. The header shows status over the link's name,
// in the Error look, for 4 s. Then it shows what it showed before. Playback
// and Now Playing go on under it. A newer open ends it early, and so does
// Close.
- (void)showNotice:(NSString *)status naming:(NSString *)name;
- (void)endNotice;

- (IBAction)closeApp:(id)sender;
- (IBAction)minimizeWindow:(id)sender;

- (IBAction)playPause:(nullable id)sender;
- (IBAction)next:(nullable id)sender;
- (IBAction)previous:(nullable id)sender;

// Plays the selected row, as a double-click does.
- (IBAction)playSelectedTrack:(nullable id)sender;

// The Playlist, Transport, Window and Convert actions are declared in their
// category headers.

- (IBAction)showInFinder:(id)sender;
- (IBAction)copyFile:(id)sender;
- (IBAction)copyName:(id)sender;

// The window's NSUndoManager, gated on fileMoveInFlight. A conversion's round
// trip and Move to Trash move files through the Trash; a removal or reorder
// moves no files.
- (IBAction)undo:(nullable id)sender;
- (IBAction)redo:(nullable id)sender;

// YES until the last file move of an undoable action settles: a conversion
// inverse's, or Move to Trash's, its undo's or its redo's. So an async action
// cannot be re-entered, nor undone before its files land.
@property (nonatomic, readonly, getter=isFileMoveInFlight) BOOL fileMoveInFlight;

// Fires the debug channel's one-shot undo/redo hook, once the file moves of
// an undo or redo settle.
- (void)undoRedoDidSettleCommitted:(BOOL)committed reason:(nullable NSString *)reason;

@end

NS_ASSUME_NONNULL_END
