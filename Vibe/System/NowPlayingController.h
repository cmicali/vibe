//
//  NowPlayingController.h
//  Vibe
//
//  The MPRemoteCommandCenter / MPNowPlayingInfoCenter bridge. It owns no
//  playback state: each shell's +NowPlaying category drives it and takes the
//  commands back through the delegate.
//
//  TRAP: the debug-only --no-audio-hw and --no-now-playing flags suppress all
//  of it, no publish and no command registration, because publishing can pull
//  AirPods from another device even when rendering to a virtual output.
//  Verifying this class needs a launch without either flag (vibe-debug).
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"
#import "RepeatMode.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class NowPlayingController;

// Loading maps by its intent: an ordinary load is Playing, a parked one Paused.
typedef NS_ENUM(NSInteger, NowPlayingPlaybackState) {
    NowPlayingPlaybackStateStopped = 0,
    NowPlayingPlaybackStatePlaying,
    NowPlayingPlaybackStatePaused,
};

@protocol NowPlayingControllerDelegate <NSObject>
// Destination states, not a toggle: route them to idempotent operations.
- (void)nowPlayingControllerPlay:(NowPlayingController *)controller;
- (void)nowPlayingControllerPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerTogglePlayPause:(NowPlayingController *)controller;
- (void)nowPlayingControllerNextTrack:(NowPlayingController *)controller;
- (void)nowPlayingControllerPreviousTrack:(NowPlayingController *)controller;
// Seconds from the track start.
- (void)nowPlayingController:(NowPlayingController *)controller seekToPosition:(NSTimeInterval)position;
// The system's shuffle and repeat controls (Siri, the Watch, accessories):
// write the setting and apply it as the app's own control does.
- (void)nowPlayingController:(NowPlayingController *)controller setShuffleEnabled:(BOOL)enabled;
- (void)nowPlayingController:(NowPlayingController *)controller setRepeatMode:(VibeRepeatMode)mode;
@end

@interface NowPlayingController : NSObject

// Registers the remote command handlers at once.
- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate;

// Publication only, no command registration: the tests' OS boundary.
- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock
                      publish:(void (^)(NSDictionary * _Nullable, NowPlayingPlaybackState))publish
          commandAvailability:(void (^)(BOOL hasNext, BOOL hasPrevious))commandAvailability;

// Nothing is published until the first Playing update, so a launch never
// claims the system slot; after that a nil track clears it once. hasNext and
// hasPrevious gate the system commands and apply even before the first
// publish. Cheap on every transport event: a dirty check skips unchanged
// publishes, and art is read non-blocking. placeholderArt stands in while the
// track has no decoded art; pass the same object while it is unchanged, since
// the dirty check compares identity. Main thread.
- (void)updateWithTrack:(nullable AudioTrack *)track
         placeholderArt:(nullable VibeImage *)placeholderArt
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                  state:(NowPlayingPlaybackState)state
                   rate:(double)rate
                hasNext:(BOOL)hasNext
            hasPrevious:(BOOL)hasPrevious;

// The modes the system's controls show. There is no Now Playing info key for
// either: the state lives on the commands, so it is written wherever a mode is
// applied, whoever changed it. Written only on a change. Main thread.
- (void)updateShuffleEnabled:(BOOL)shuffleEnabled repeatMode:(VibeRepeatMode)repeatMode;

@end

NS_ASSUME_NONNULL_END
