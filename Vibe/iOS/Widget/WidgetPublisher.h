// Main thread only. File writes and reload requests use a private serial queue.
// Writes require widgetPlaced. The current snapshot is retained either way.
// A placed widget playing a track requests a timeline reload every minute.
// It reads no app setting or model: the app hands in each track and pushes
// the strip's look.

#import <UIKit/UIKit.h>

#import "VibePlayableItem.h"
#import "WaveformTheme.h"

@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

// A track as the widget shows it. The publisher keeps the object it is given
// and tells two tracks apart by identity, never by content.
@protocol VibeWidgetTrack <VibePlayableItem>
// The title, or the single line derived from the filename.
- (NSString *)displayTitle;
// nil means no second line.
- (nullable NSString *)displayArtist;
// Non-blocking: nil until the art is decoded.
- (nullable UIImage *)cachedArt;
@end

@interface WidgetPublisher : NSObject

// VibeWidgetState.trackKey for a track: its file's NSURL.pathKey, plus a cue
// row's window, so rows of one file render and seek apart. nil with no path.
+ (nullable NSString *)trackKeyForTrack:(nullable id<VibePlayableItem>)track NS_SWIFT_NAME(trackKey(for:));

// The theme is always asked for dark, because the widget's background is.
- (instancetype)initWithThemeProvider:(WaveformThemeProvider)themeProvider NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Turned off only by WidgetKit's answer (refreshPlaced); turned on by that or
// by the extension's read signal (kVibeWidgetReadNotification).
@property (nonatomic, readonly) BOOL widgetPlaced;

// Call on return to the foreground to detect removed widgets.
- (void)refreshPlaced;

// Uses the Now Playing publish values. Quiet ticks allocate nothing.
// startPending skips the seek test during a slow open.
- (void)updateWithTrack:(nullable id<VibeWidgetTrack>)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending;

// The strip's look. The app pushes it once before the first publish, and
// again on every change to a setting it reads. style is a resolved
// identifier (WaveformRendererRegistry), and drawsPlayheadLine is already
// resolved for it. Bakes again only when the look moved.
- (void)updateWaveformStyle:(NSString *)style
                   centered:(BOOL)centered
          drawsPlayheadLine:(BOOL)drawsPlayheadLine;

// Bakes only for the published track; the caller filters partial envelopes.
// Retained, so a settings change re-bakes without the card.
- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(id<VibeWidgetTrack>)track;

@end

NS_ASSUME_NONNULL_END
