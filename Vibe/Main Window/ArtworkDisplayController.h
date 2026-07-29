//
//  ArtworkDisplayController.h
//  Vibe
//
//  Owns the artwork display policy for the main window: which image (track
//  art or the default record-bg backdrop) is showing in the album-art view,
//  the header glass tint (dominant art color), and the dock icon, plus the
//  deferred off-main-thread art loads and the full-res art memory lifecycle.
//
//  One of the two display controllers (with TrackDisplayController) that
//  render into MainPlayerContentView's widgets: the content view builds and
//  owns the hierarchy, each display controller adopts its subset at init and
//  renders one facet, and MainPlayerController decides what they render.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// Main thread only.
@interface ArtworkDisplayController : NSObject

// Adopts the album-art view and the header tint view (the layer-backed wash
// over the header glass whose background this controller sets to the art's
// dominant color) from the content view; the view hierarchy stays owned by
// MainPlayerContentView.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// A deferred art load must re-check which track is current when it completes
// (the user may have skipped on); the owner answers here. Set once at startup.
@property (nonatomic, copy) AudioTrack * _Nullable (^currentTrackProvider)(void);

// Called on the main thread when a deferred art load resolves with an image;
// the owner refreshes the art-dependent UI (which calls back into
// updateForTrack: with the art now decodable).
@property (nonatomic, copy) void (^artDidResolveHandler)(void);

// Fired (main thread) whenever the artwork-derived accent color changes —
// with the tint, from the same dominant-color resolution: on track/art
// changes and appearance flips, nil when no art color is available. The
// accent is the dominant color normalized (OKLCH) into a lightness band that
// stays legible over the playlist frost; the owner routes it to the playing
// row's equalizer indicator.
@property (nonatomic, copy, nullable) void (^accentColorDidChangeHandler)(NSColor *_Nullable accentColor);

// Reflect track's art (nil track shows the default). New art replaces old art
// directly; while the track's art is still unresolved the previous track's
// art stays on screen — no flash of the default between tracks. Also keeps
// the art view's drag-out fileURL on the displayed track.
- (void)updateForTrack:(nullable AudioTrack *)track;

// A slow open crossed the loading-indicator threshold: drop the keep-previous
// policy and show the default (empty-state) art, unless the pending track's
// own art is already displayed. Pairs with the waveform's loading shimmer.
- (void)showPlaceholderForSlowLoad;

// Re-derives the header wash from the stored art color. The wash is
// appearance-dependent (dark: deep wash, light: pastel) and key-window-
// dependent (half strength inactive); call on appearance changes — key
// changes are observed internally.
- (void)refreshHeaderTint;

// Demotes the previous track's full-res art (decoded bitmap + compressed
// bytes) when playback moves to a new track, so art doesn't accumulate for
// the playlist's lifetime.
- (void)trackDidStartPlaying:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
