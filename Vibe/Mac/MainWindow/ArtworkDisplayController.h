//
//  ArtworkDisplayController.h
//  Vibe
//
//  The artwork display: the art view (the track's art or the theme's
//  default), the header and playlist tint washes, the Dock tile, the deferred
//  art loads and the full-resolution art's lifetime. MainPlayerController
//  decides what it renders.
//

#import <Cocoa/Cocoa.h>

@class AudioTrack;
@class MainPlayerContentView;

NS_ASSUME_NONNULL_BEGIN

// Main thread only.
@interface ArtworkDisplayController : NSObject

// Adopts the art view and both tint views; the content view keeps ownership.
- (instancetype)initWithContentView:(MainPlayerContentView *)contentView;

// The same admission and delivery policy with injected rendering and
// publication (tests). Completions deliver on main; nil uses the real renderer
// or views and Dock. A nil published image is default art.
- (instancetype)initWithRenderer:(void (^_Nullable)(NSImage *source, NSColor * _Nullable cachedColor,
        void (^completion)(NSImage *image, NSColor * _Nullable color, BOOL dark)))renderer
                      publication:(void (^_Nullable)(NSImage * _Nullable image, NSColor * _Nullable color,
                                                     BOOL defaultArt, BOOL dark))publication;

// A deferred art load re-checks the current track through this. Set once.
@property (nonatomic, copy) AudioTrack * _Nullable (^currentTrackProvider)(void);

// On main when a deferred load resolves with an image; the owner's refresh
// calls updateForTrack: again.
@property (nonatomic, copy) void (^artDidResolveHandler)(void);

// nil while the default shows. Set only by a generation- and target-matched
// install, so it never carries a previous track's color.
@property (nonatomic, readonly, nullable) NSColor *dominantArtColor;

// On main whenever dominantArtColor settles.
@property (nonatomic, copy) void (^dominantColorDidChangeHandler)(void);

// Whether the image band under the transport row reads dark, sampled from the
// image on screen, placeholder included. Fires with every install and default;
// the receiver drops an unchanged answer. hasArtwork excludes the default.
@property (nonatomic, copy) void (^transportBackdropDidChangeHandler)(BOOL dark, BOOL hasArtwork);

// A nil track shows the default. While a track's art is unresolved the
// previous art stays, so the default never flashes between tracks.
- (void)updateForTrack:(nullable AudioTrack *)track;

// With the loading shimmer: drops keep-previous and shows the default, unless
// the pending track's own art is up.
- (void)showPlaceholderForSlowLoad;

// Re-derives both washes and, while the placeholder is up, its transport
// contrast. Call on appearance changes.
- (void)refreshTintWashes;

// Demotes the previous track's full-resolution art, so played art does not
// accumulate.
- (void)trackDidStartPlaying:(AudioTrack *)track;

// For a changed theme default: showDefaultArtwork's already-showing guard
// would keep the old image.
- (void)refreshDefaultArtwork;

// The installed crop or the app icon, per the theme's dockIcon.
- (void)applyDockIcon;

@end

NS_ASSUME_NONNULL_END
