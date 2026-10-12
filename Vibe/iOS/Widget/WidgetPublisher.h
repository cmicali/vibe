// Main thread only. File writes and reload requests use a private serial queue.
// Writes require widgetPlaced. The current snapshot is retained either way.
// A placed widget playing a track requests a timeline reload every minute.

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

// Call on return to the foreground to detect removed widgets.
- (void)refreshPlaced;

// Uses the Now Playing publish values. Quiet ticks allocate nothing.
// startPending skips the seek test during a slow open.
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
