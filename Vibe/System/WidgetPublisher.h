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
//  It publishes nothing while no widget is placed. With none placed anywhere
//  every publish was two renders, two PNG encodes and ~220 KB of writes per
//  track change for nobody, so every entry point returns at `widgetPlaced`
//  before it builds, captures, draws or writes anything, and nothing is kept
//  alive: offerWaveform: only takes weak references, and the theme dictionary
//  and placeholder signature are all that outlive a deactivation. A widget
//  that appears mid-track gets the current track from the shell at once
//  (activationHandler), not a copy the publisher kept while nobody looked.
//  What stays for everyone is the object, its queue, one Darwin registration
//  and a marker check at launch; the System doc lists what discovery costs.
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
// WidgetKit's own answer (asked at init and by refreshPlaced), which also
// leaves the empty snapshot on disk, since nothing is written after it; turned
// on by that answer or by the extension's demand signal
// (VibeWidgetDemandNotification), whichever comes first.
@property (nonatomic, readonly) BOOL widgetPlaced;

// Called on main at every admission — publishing starting, and each placement
// answer that lets held work go out — for the shell to hand over what is true
// now: its Now Playing publish (updateWithTrack:…), which the publisher then
// compares with what the widget has. The complete waveform needs no second
// offer — offerWaveform: keeps it weakly whatever the gate says.
@property (nonatomic, copy, nullable) dispatch_block_t activationHandler;

// Asks WidgetKit whether a widget is still placed, while one is (or the last
// query failed): the shell calls it on every return to the foreground, when a
// removal is most likely to have happened, since removing one means using the
// desktop. A removal while the app stays in the background is found by the
// next write instead: every write — a track, a seek or pause, a cover, a
// strip, a theme — waits for an answer asked after it was wanted, and what
// arrives meanwhile joins that one question. So a placed widget costs one
// query per change that writes, and an unchanged tick asks nothing. Adding
// one is covered by the demand signal, so
// with none placed there is nothing to ask. init asks once if a widget has
// rendered since WidgetKit last said none (VibeWidgetState.widgetMayBePlaced),
// to learn of one placed before launch. Queries run one at a time, and an
// answer to a question asked before the latest demand signal is dropped.
- (void)refreshPlaced;

// Called from the Now Playing publish, with the values that call already
// holds — the widget's snapshot must never disagree with the lock screen's,
// and re-reading the player would be four more lock round-trips per tick.
//
// This runs at 3 Hz. With no widget placed it returns at once. With one
// placed it is cheap on a tick that changes nothing: the
// gate is scalars, a pointer compare and the two line compares, and no
// snapshot object is built unless something is actually going to be published.
//
// `startPending` is the shell's "the open has not started the audio yet" —
// iOS's `_trackStartPending`, the mac's Loading display state. While it is set
// the player reports playing with a pinned position, so the seek detector is
// skipped — otherwise a slow cloud open republishes every couple of seconds
// for its whole duration with byte-identical content — and it is published
// (VibeWidgetState.startPending), so the widget holds its playhead until the
// open lands rather than playing through audio that has not started.
- (void)updateWithTrack:(nullable AudioTrack *)track
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                playing:(BOOL)playing
           startPending:(BOOL)startPending;

// The card's waveform delivery, offered for the widget's strip. A delivery for
// anything but the published track is dropped — a decode outlives the track
// change that superseded it. Partial envelopes are the caller's to filter.
//
// The envelope is referenced weakly, so a later settings change or a widget
// placed afterwards can bake without the card being involved while the card
// still holds it — and the publisher keeps no envelope, or track, alive itself.
- (void)offerWaveform:(CodableAudioWaveform *)waveform forTrack:(AudioTrack *)track;

// The app is quitting: publishes the empty snapshot and blocks until every
// queued write and reload has landed. Without it the last snapshot outlives
// the app — claiming playback forever, or, published as paused, offering a
// track that a click relaunches into an empty playlist — since nothing else
// will ever publish again.
- (void)publishEmptyForTermination;

// Republishes what moved of what the widget draws from the settings: the mac
// theme's colors, transport glyphs and no-artwork image, and the strip's
// style, colors and levels. A compare otherwise, so it is safe on every
// settings change, continuous ones included. iOS subscribes it to
// VibeDisplaySettingsDidChangeNotification itself; the mac calls it from
// applySettingsLiveEffects:.
- (void)settingsDidChange;

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
