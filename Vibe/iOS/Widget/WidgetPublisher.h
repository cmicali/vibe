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
//  Main thread only, like the controller that drives it. Every file write and
//  every WidgetKit reload lands on its own serial queue.
//

#import <Foundation/Foundation.h>

@class AudioTrack;
@class CodableAudioWaveform;

NS_ASSUME_NONNULL_BEGIN

@interface WidgetPublisher : NSObject

// Called from the Now Playing publish, with the values that call already
// holds — the widget's snapshot must never disagree with the lock screen's,
// and re-reading the player would be four more lock round-trips per tick.
//
// This runs at 3 Hz. It is cheap on a tick that changes nothing: the gate is
// scalars and a pointer compare, and no snapshot object is built unless
// something is actually going to be published.
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
