//
//  ArtworkDisplayController.h
//  Vibe
//
//  Owns the artwork display policy for the main window: which image (track
//  art or the default record-bg backdrop) is showing in the album-art view,
//  the header glass tint (dominant art color), and the dock icon, plus the
//  deferred off-main-thread art loads and the full-res art memory lifecycle.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class ArtworkImageView;

NS_ASSUME_NONNULL_BEGIN

// Main thread only.
@interface ArtworkDisplayController : NSObject

// headerTintView: layer-backed wash over the header glass; this controller
// sets its background color to the art's dominant color (half strength while
// the window isn't key).
- (instancetype)initWithArtworkView:(ArtworkImageView *)artworkView
                     headerTintView:(NSView *)headerTintView;

// A deferred art load must re-check which track is current when it completes
// (the user may have skipped on); the owner answers here. Set once at startup.
@property (nonatomic, copy) AudioTrack * _Nullable (^currentTrackProvider)(void);

// Called on the main thread when a deferred art load resolves with an image;
// the owner refreshes the art-dependent UI (which calls back into
// updateForTrack: with the art now decodable).
@property (nonatomic, copy) void (^artDidResolveHandler)(void);

// Reflect track's art (nil track shows the default). New art replaces old art
// directly; while the track's art is still unresolved the previous track's
// art stays on screen — no flash of the default between tracks.
- (void)updateForTrack:(nullable AudioTrack *)track;

// Demotes the previous track's full-res art (decoded bitmap + compressed
// bytes) when playback moves to a new track, so art doesn't accumulate for
// the playlist's lifetime.
- (void)trackDidStartPlaying:(AudioTrack *)track;

@end

NS_ASSUME_NONNULL_END
