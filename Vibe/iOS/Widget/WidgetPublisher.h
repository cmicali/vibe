//
//  WidgetPublisher.h
//  Vibe (iOS)
//
//  What the home-screen widget is told, and the ONLY writer of the shared app
//  group: NowPlayingController's shape pointed at a second process. Nothing
//  else needs to know the widget exists.
//
//  Writes are gated on `widgetPlaced` (each track change is two renders, two
//  PNG encodes and ~220 KB); the bookkeeping never is, so a widget that
//  appears mid-track is handed the current snapshot at once.
//
//  Main thread only. Every file write and WidgetKit reload lands on its own
//  serial queue.
//

#import <Foundation/Foundation.h>

@class AudioTrack;
@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface WidgetPublisher : NSObject

// VibeWidgetState.trackKey for a track: its NSURL.pathKey, plus a cue row's
// window, so rows of one file render and seek apart. nil with no path.
+ (nullable NSString *)trackKeyForTrack:(nullable AudioTrack *)track;

// Turned off only by WidgetKit's answer (refreshPlaced); turned on by that or
// by the extension's read signal (kVibeWidgetReadNotification).
@property (nonatomic, readonly) BOOL widgetPlaced;

// Called at init and on every return to the foreground, the one moment a
// widget can have been REMOVED.
- (void)refreshPlaced;

// From the Now Playing publish, with its values, so the widget never disagrees
// with the lock screen. Runs at 3 Hz and allocates nothing on a quiet tick.
// While `startPending` the position is pinned, so the seek detector is skipped,
// or a slow cloud open republishes identical content every couple of seconds.
- (void)updateWithTrack:(nullable AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending;

// Bakes only for the published track; the caller filters partial envelopes.
// Retained, so a settings change re-bakes without the card.
- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
