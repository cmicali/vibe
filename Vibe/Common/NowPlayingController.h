//
//  NowPlayingController.h
//  Vibe
//
//  Bridges the player to the system Now Playing UI — Control Center, the macOS
//  hardware media keys for play/pause, next and previous, and AirPods and
//  Bluetooth transport controls — through MediaPlayer's MPRemoteCommandCenter
//  and MPNowPlayingInfoCenter. Registering the command handlers is what routes
//  the media keys to Vibe, and publishing now-playing info is what makes Vibe
//  the system's active Now Playing app.
//
//  TRAP: the debug-only --no-audio-hw flag suppresses all of it — no publish,
//  no command registration. Becoming the system's active media app pulls
//  auto-switching AirPods over from another device even when no output device
//  was ever opened, which would defeat the flag's whole purpose, so a test
//  launch stays silent here too. Verifying this class therefore needs a launch
//  without that flag; see the vibe-debug skill.
//
//  It owns no playback state. MainPlayerController drives it with track and
//  timing updates through updateWithTrack:..., and receives the hardware
//  commands back through the delegate, routing them to the same transport
//  actions the on-screen buttons and the keyboard use.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class NowPlayingController;

// The three states the system Now Playing UI distinguishes. The player's
// transient Loading state maps to Playing, since a play is committed and
// imminent.
typedef NS_ENUM(NSInteger, NowPlayingPlaybackState) {
    NowPlayingPlaybackStateStopped = 0,
    NowPlayingPlaybackStatePlaying,
    NowPlayingPlaybackStatePaused,
};

@protocol NowPlayingControllerDelegate <NSObject>
// Discrete play and pause, which some remotes and Control Center send. The
// controller calls play only when not already playing, and pause only when
// playing.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller;
- (void)nowPlayingControllerPause:(NowPlayingController *)controller;
// The keyboard play/pause media key sends this toggle.
- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller;
- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller;
// A Control Center scrubber drag. position is in seconds from the track start.
- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position;
@end

@interface NowPlayingController : NSObject

// Registers the remote command handlers immediately. They are process-global,
// so the media keys can route to Vibe as soon as now-playing info is published.
- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate;

// Publishes the current track's metadata and artwork, and the playback timing
// and state. A nil track clears the now-playing info, meaning nothing is
// loaded, but only once something has been published: before the first track
// plays, a nil update is a no-op, so Vibe never claims the system Now Playing
// slot at launch.
//
// hasNext and hasPrevious come from PlaylistController's hasNextTrack and
// hasPreviousTrack, the same predicates the in-app Next button and menu items
// use, and they gate the system next and previous commands. They apply even
// before the first publish, because enabling a command does not claim the Now
// Playing slot.
//
// This is cheap enough to call on every transport event and every metadata or
// artwork delivery: a dirty check skips the republish when nothing has
// changed, and artwork is read non-blocking, using already-decoded art only,
// so it is safe on the main thread.
- (void)updateWithTrack:(nullable AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                  state:(NowPlayingPlaybackState)state
                   rate:(double)rate
                hasNext:(BOOL)hasNext
            hasPrevious:(BOOL)hasPrevious;

@end

NS_ASSUME_NONNULL_END
