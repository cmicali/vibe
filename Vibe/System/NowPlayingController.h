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
//  TRAP: the debug-only --no-audio-hw and --no-now-playing flags suppress all
//  of it — no publish, no command registration. Publishing can pull AirPods
//  from another device even when rendering to a virtual output. The latter
//  flag leaves hardware rendering enabled for loopback tests. Verifying this
//  class needs a launch without either flag; see the vibe-debug skill.
//
//  It owns no playback state. MainPlayerController drives it with track and
//  timing updates through updateWithTrack:..., and receives the hardware
//  commands back through the delegate, routing them to the same transport
//  actions the on-screen buttons and the keyboard use.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

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
// Discrete play and pause, which some remotes and Control Center send. These
// name destination states, so delegates route them to idempotent start/resume
// and pause operations rather than through a play/pause toggle.
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

// Publication-only construction: no remote-command registration. The clock and
// sinks are the OS boundary; the same dirty check and artwork pipeline run.
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock
                      publish:(void (^)(NSDictionary * _Nullable, NowPlayingPlaybackState))publish
          commandAvailability:(void (^)(BOOL hasNext, BOOL hasPrevious))commandAvailability;

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
//
// placeholderArt is the shell's own no-artwork image, published while the
// track has no decoded art, so the card shows what the app shows. Pass the
// same object while it is unchanged: the dirty check compares identity.
- (void)updateWithTrack:(nullable AudioTrack *)track
         placeholderArt:(nullable VibeImage *)placeholderArt
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                  state:(NowPlayingPlaybackState)state
                   rate:(double)rate
                hasNext:(BOOL)hasNext
            hasPrevious:(BOOL)hasPrevious;

@end

NS_ASSUME_NONNULL_END
