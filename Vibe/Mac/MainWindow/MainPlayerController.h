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
@class VibeSlider;

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

// YES when the mirror came back, parked on its last current row; NO when the
// setting is off or nothing was saved. Not an open (Mac/App/AGENTS.md).
- (BOOL)restoreLastPlaylist;
- (BOOL)loadWelcomeTrack;
// Quit-time: writes the mirror, or deletes it when off or empty.
- (void)saveLastPlaylist;

- (IBAction)closeApp:(id)sender;
- (IBAction)minimizeWindow:(id)sender;

- (IBAction)playPause:(nullable id)sender;
- (IBAction)next:(nullable id)sender;
- (IBAction)previous:(nullable id)sender;
// The header's volume slider: stores its position and pushes it to the player.
- (IBAction)volumeChanged:(VibeSlider *)sender;

// Plays the selected row, as a double-click does.
- (IBAction)playSelectedTrack:(nullable id)sender;

- (IBAction)closeFile:(nullable id)sender;

// The playlist as M3U; the audio files are never touched.
- (IBAction)savePlaylist:(nullable id)sender;

// Removes every selected row, never the file. A removed current row hands its
// play intent to its forward successor, or parks on the row before.
- (IBAction)removeSelectedPlaylistTracks:(nullable id)sender;

// The Transport, Window and Convert actions are declared in their category
// headers.

- (IBAction)setPitchRange:(id)sender;
- (IBAction)toggleShuffle:(nullable id)sender;
// Off, All, One, Off.
- (IBAction)cycleRepeatMode:(nullable id)sender;

- (IBAction)showInFinder:(id)sender;
- (IBAction)copyFile:(id)sender;
- (IBAction)copyName:(id)sender;

@end

NS_ASSUME_NONNULL_END
