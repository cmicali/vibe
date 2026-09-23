//
//  WidgetPublisher.h
//  Vibe
//
//  What the widget is told, and the ONLY thing that writes the
//  shared app group. It is `System/NowPlayingController`'s shape pointed at a
//  second process instead of at MPNowPlayingInfoCenter: the caller hands it
//  what is playing, it decides whether that differs from what it last
//  published, and it owns the writing.
//
//  It exists as a type because the alternative was three owners — the Now
//  Playing category held its state, a view controller relayed settings changes
//  to it, and the writes happened on three different queues. Everything it
//  publishes is derived from what it is handed here, so nothing else needs to
//  know the widget exists.
//
//  It does nothing while no widget is placed. With none placed anywhere every
//  publish was two renders, two PNG encodes and ~220 KB of writes per track
//  change for nobody, so everything is gated on `widgetPlaced`: no snapshot is
//  built, no theme captured, no image drawn and no WidgetKit query made. The
//  one thing kept is the last update's raw inputs, so a widget that appears
//  mid-track is handed the current track at once (republish) rather than at
//  the next event.
//
//  Main thread only, like the controller that drives it. Every file write and
//  every WidgetKit reload lands on its own serial queue.
//

#import <Foundation/Foundation.h>

@class AudioTrack;
@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface WidgetPublisher : NSObject

// Whether at least one widget is placed, as last known. Turned off only by
// WidgetKit's own answer (asked at init and by refreshPlaced); turned on by
// that answer or by the extension's read signal (kVibeWidgetReadNotification),
// whichever comes first.
@property (nonatomic, readonly) BOOL widgetPlaced;

// Asks WidgetKit whether a widget is still placed, and only while one is: the
// shell calls it on every return to the foreground — the one moment a widget
// can have been REMOVED, since removing one means leaving the app. Adding one
// is covered by the read signal, so with none placed there is nothing to ask.
// init asks once if a widget has rendered since WidgetKit last said none
// (VibeWidgetState.widgetMayBePlaced), to learn of one placed before launch.
- (void)refreshPlaced;

// Called from the Now Playing publish, with the values that call already
// holds — the widget's snapshot must never disagree with the lock screen's,
// and re-reading the player would be four more lock round-trips per tick.
//
// This runs at 3 Hz. With no widget placed it records its arguments and
// returns. With one placed it is cheap on a tick that changes nothing: the
// gate is scalars, a pointer compare and the two line compares, and no
// snapshot object is built unless something is actually going to be published.
//
// `startPending` is the shell's "the open has not started the audio yet" —
// iOS's `_trackStartPending`, the mac's Loading display state. While it is set
// the player reports playing with a pinned position, so the seek detector is
// skipped — otherwise a slow cloud open republishes every couple of seconds
// for its whole duration with byte-identical content.
- (void)updateWithTrack:(nullable AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending;

// The card's waveform delivery, offered for the widget's strip. A delivery for
// anything but the published track is dropped — a decode outlives the track
// change that superseded it. Partial envelopes are the caller's to filter.
//
// The envelope is retained so a later settings change can re-bake without the
// card being involved.
- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

// The app is quitting: publishes the empty snapshot and blocks until every
// queued write and reload has landed. Without it the last snapshot outlives
// the app — claiming playback forever, or, published as paused, offering a
// track that a click relaunches into an empty playlist — since nothing else
// will ever publish again.
- (void)publishEmptyForTermination;

// Republishes if anything the widget draws from the mac theme moved — its
// colors, transport glyphs or no-artwork image; a compare otherwise, so it is
// safe on every theme edit, continuous ones included. A no-op on iOS.
- (void)themeDidChange;

// Re-bakes the strip if a waveform setting moved; a no-op otherwise, so it is
// safe to call on every settings change, continuous ones included. iOS
// subscribes it to VibeDisplaySettingsDidChangeNotification itself; the mac
// calls it from applySettingsLiveEffects:.
- (void)displaySettingsDidChange;

@end

#if TARGET_OS_OSX
// The widget buttons' mac transport, which VibeWidgetIntents.swift performs:
// once the launch open has settled, acts on the player, then calls
// `completion`. Implemented by the mac shell (AppDelegate), declared here in a
// Foundation-only header because the Swift calling it must not see AppKit —
// see that file's trap. Main thread. A seek applies `progress` of the current
// track only when it is still the one `trackKey` names.
typedef NS_ENUM(NSInteger, VibeWidgetAction) {
    VibeWidgetActionPlayPause,
    VibeWidgetActionNext,
    VibeWidgetActionSeek,
};
FOUNDATION_EXPORT void VibeWidgetPerformAction(VibeWidgetAction action, double progress,
                                               NSString *_Nullable trackKey,
                                               dispatch_block_t completion);
#endif

NS_ASSUME_NONNULL_END
