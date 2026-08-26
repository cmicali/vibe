//
//  ArtworkDisplayController.h
//  Vibe
//
//  Owns the artwork display policy for the main window: which image shows in
//  the album-art view, whether the track's art or the default record-bg
//  backdrop, the header and playlist tint washes drawn from the theme and the
//  dominant art color, and the dock icon. It also owns the deferred
//  off-main-thread art loads and the full-resolution art memory lifecycle.
//
//  It is one of the two display controllers, with TrackDisplayController, that
//  render into MainPlayerContentView's widgets. The content view builds and
//  owns the hierarchy, each display controller adopts its subset at init and
//  renders one facet, and MainPlayerController decides what they render.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// Main thread only.
@interface ArtworkDisplayController : NSObject

// Adopts the album-art view and the two tint views — header and playlist —
// from the content view. Each tint view is a layer-backed wash whose
// background this controller resolves from the theme's tint choice and the
// art's dominant color. MainPlayerContentView keeps ownership of the view
// hierarchy.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// A deferred art load must re-check which track is current when it completes,
// since the user may have skipped on, and the owner answers here. Set once at
// startup.
@property (nonatomic, copy) AudioTrack * _Nullable (^currentTrackProvider)(void);

// Called on the main thread when a deferred art load resolves with an image.
// The owner then refreshes the art-dependent UI, which calls back into
// updateForTrack: with the art now decodable.
@property (nonatomic, copy) void (^artDidResolveHandler)(void);

// The settled art's raw dominant color, nil while the default art shows. Set
// only when a render result installs, which is generation- and target-matched
// against the current track — so a stale delivery can never surface a
// previous track's color here.
@property (nonatomic, readonly, nullable) NSColor *dominantArtColor;

// Called on the main thread whenever dominantArtColor settles — art
// installed, or the default art cleared it. The owner forwards it into the
// waveform's album-art theme.
@property (nonatomic, copy) void (^dominantColorDidChangeHandler)(void);

// Reflects the track's art; a nil track shows the default. New art replaces
// old art directly, and while a track's art is still unresolved the previous
// track's art stays on screen, so the default never flashes between tracks. It
// also keeps the art view's drag-out fileURL on the displayed track.
- (void)updateForTrack:(nullable AudioTrack *)track;

// A slow open has crossed the loading-indicator threshold, so drop the
// keep-previous policy and show the default, empty-state art, unless the
// pending track's own art is already displayed. It pairs with the waveform's
// loading shimmer.
- (void)showPlaceholderForSlowLoad;

// Re-derives the header and playlist washes from the theme and the stored art
// color. A wash depends on the appearance — a deep wash in dark mode, a
// pastel one in light — but not on key-window state: its strength is constant
// whether or not the window is active. That is why each is a plain view's
// background rather than the glass's own tintColor; see the .m. Call it on
// appearance changes.
- (void)refreshTintWashes;

// Demotes the previous track's full-resolution art — both the decoded bitmap
// and the compressed bytes — when playback moves to a new track, so that art
// does not accumulate for the playlist's lifetime.
- (void)trackDidStartPlaying:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
