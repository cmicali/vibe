//
//  WidgetPublisher.h
//  Vibe (iOS)
//
//  What the home-screen widget is told, and the ONLY thing that writes the
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
//  It writes only while a widget is placed. With none on any Home screen every
//  publish was two renders, two PNG encodes and ~220 KB of writes per track
//  change for nobody, so the writes are gated on `widgetPlaced` — while the
//  bookkeeping never is, so a widget that appears mid-track is handed the
//  current snapshot at once (republish) rather than at the next event.
//
//  Main thread only, like the controller that drives it. Every file write and
//  every WidgetKit reload lands on its own serial queue.
//

#import <Foundation/Foundation.h>

@class AudioTrack;
@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface WidgetPublisher : NSObject

// Whether at least one widget is on a Home screen, as last known. Turned off
// only by WidgetKit's own answer (refreshPlaced); turned on by that answer or
// by the extension's read signal (kVibeWidgetReadNotification), whichever
// comes first.
@property (nonatomic, readonly) BOOL widgetPlaced;

// Asks WidgetKit. Called at init and by the controller on every return to the
// foreground — the one moment a widget can have been REMOVED, since removing
// one means leaving the app. Adding one is covered by the read signal.
- (void)refreshPlaced;

// Called from the Now Playing publish, with the values that call already
// holds — the widget's snapshot must never disagree with the lock screen's,
// and re-reading the player would be four more lock round-trips per tick.
//
// This runs at 3 Hz. It is cheap on a tick that changes nothing: the gate is
// scalars, a pointer compare and the two line compares, and no snapshot
// object is built unless something is actually going to be published.
//
// `startPending` is the controller's `_trackStartPending`. While it is set the
// player reports playing with a pinned position, so the seek detector is
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
// card being involved; that is the whole reason this object subscribes to
// VibeDisplaySettingsDidChangeNotification itself.
- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
