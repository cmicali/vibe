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
// claims the system slot. After that, a nil sourceKey clears it once.
// sourceKey names the track, so a cue row of the same file is a change. A nil
// title publishes as empty, and a nil artist publishes none. artwork is the
// track's art, else its thumbnail, else the app's placeholder, each read
// without blocking. The thumbnail covers the gap until the full art decodes.
// The placeholder must already match the app's appearance, since the drawing
// appearance here is the system's. Pass the same image while it is unchanged,
// since the dirty check compares identity. hasNext and hasPrevious gate the
// system commands, even before the first publish. A dirty check skips
// unchanged publishes, so this is cheap on every transport event. Main thread.
- (void)updateWithSourceKey:(nullable NSString *)sourceKey
                      title:(nullable NSString *)title
                     artist:(nullable NSString *)artist
                    artwork:(nullable VibeImage *)artwork
                   position:(NSTimeInterval)position
                   duration:(NSTimeInterval)duration
                      state:(NowPlayingPlaybackState)state
                       rate:(double)rate
                    hasNext:(BOOL)hasNext
                hasPrevious:(BOOL)hasPrevious;

// The modes the system's controls show, and whether they offer them at all:
// unavailable, CarPlay draws neither button. There is no Now Playing info key
// for either: the state lives on the commands, so it is written wherever a
// mode is applied, whoever changed it. Main thread.
- (void)updateShuffleEnabled:(BOOL)shuffleEnabled
                  repeatMode:(VibeRepeatMode)repeatMode
                   available:(BOOL)available;

@end

NS_ASSUME_NONNULL_END
