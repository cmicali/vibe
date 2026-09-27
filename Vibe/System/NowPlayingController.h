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

@end

NS_ASSUME_NONNULL_END
