//
//  NowPlayingController.h
//  Vibe
//
//  Bridges the player to the system Now Playing UI — Control Center, the macOS
//  hardware media keys (play/pause, next, previous), and AirPods/Bluetooth
//  transport controls — via MediaPlayer's MPRemoteCommandCenter and
//  MPNowPlayingInfoCenter. Registering the command handlers is what makes the
//  media keys route to Vibe; publishing now-playing info is what makes Vibe the
//  system's active "Now Playing" app.
//
//  It owns no playback state: MainPlayerController drives it with track/timing
//  updates (updateWithTrack:...) and receives the hardware commands back
//  through the delegate, routing them to the same transport actions the
//  on-screen buttons and keyboard use.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class NowPlayingController;

// The three states the system Now Playing UI distinguishes. The player's
// transient Loading state maps to Playing (a play is committed and imminent).
typedef NS_ENUM(NSInteger, NowPlayingPlaybackState) {
    NowPlayingPlaybackStateStopped = 0,
    NowPlayingPlaybackStatePlaying,
    NowPlayingPlaybackStatePaused,
};

@protocol NowPlayingControllerDelegate <NSObject>
// Discrete play/pause (some remotes and Control Center send these) — the
// controller only calls play when not already playing, and pause when playing.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller;
- (void)nowPlayingControllerPause:(NowPlayingController *)controller;
// The keyboard play/pause media key sends this toggle.
- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller;
- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller;
// Control Center scrubber drag; position is in seconds from the track start.
- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position;
@end

@interface NowPlayingController : NSObject

// Registers the remote command handlers immediately (process-global, so the
// media keys can route to Vibe as soon as now-playing info is published).
- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate;

// Publishes the current track's metadata, artwork, and playback timing/state.
// A nil track clears the now-playing info (nothing loaded). Cheap enough to
// call on every transport event and metadata/artwork delivery; artwork is read
// non-blocking (already-decoded art only) so it's safe on the main thread.
- (void)updateWithTrack:(nullable AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                  state:(NowPlayingPlaybackState)state
                   rate:(double)rate;

@end

NS_ASSUME_NONNULL_END
