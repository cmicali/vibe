//
//  MainPlayerContentView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class SymbolButton;
@class ArtworkImageView;
@class AudioWaveformView;
@class PlaylistTableView;
@class PlaylistDropZoneView;

NS_ASSUME_NONNULL_BEGIN

// The main window's whole UI. It builds the artwork, waveform, transport
// buttons, track labels and playlist table, and exposes them for the
// controller to drive. The view itself is transparent: the window's backdrop
// — Liquid Glass on macOS 26, the frosted fallback below before it — that
// MainPlayerController installs behind this view provides the background.
// Button and menu actions are sent to `target`, the controller. The view is
// pinned at its design width, with a flexible right margin, so that the
// window can widen past it to reveal the pitch panel.
@interface MainPlayerContentView : NSView

- (instancetype)initWithTarget:(id)target;

// The rounded-rect mask for the pre-26 frosted stand-ins for Liquid Glass:
// an NSVisualEffectView shapes its blur through maskImage — a layer
// cornerRadius clips its tint but not the blur region.
+ (NSImage *)frostCornerMaskWithRadius:(CGFloat)radius;

// The pre/post-26 backdrop dichotomy in one place: glass takes a layer
// radius, frost a regenerated mask. Shared by both build paths and both live
// re-applies (this view's instance applyCornerRadius: and the controller's
// applyWindowChrome).
+ (void)applyCornerRadius:(CGFloat)radius toBackdrop:(NSView *)backdrop;

// The unthemed playlist wash — clear in dark, a white brightening lift in
// light — shared with the theme editor's wells, which display it as
// "current".
+ (NSColor *)defaultPlaylistBackgroundColorForDark:(BOOL)dark;

// The solid background's seed — a near-opaque neutral in each appearance's
// register — shared by the window and playlist Solid choices' editor seeding
// and the playlist's fallback when a solid style arrives with no color (a
// hand-edited import).
+ (NSColor *)defaultSolidBackgroundColorForDark:(BOOL)dark;

// Re-shapes the header glass panel and its tint layer to the themed radius;
// the window mask and backdrop are the controller's (applyWindowChrome).
- (void)applyCornerRadius:(CGFloat)radius;

// Re-resolves the header labels' themed fonts and colors. The title's
// shrink-to-fit re-runs separately (TrackDisplayController owns the fit),
// and the corner readouts' color rides their attributed strings.
- (void)applyThemedTextStyle;

// Re-resolves the themed wash over the playlist frost; also runs on every
// appearance change (updateMaterialForAppearance).
- (void)applyPlaylistBackground;

// Fires from the effective-appearance funnel, after the view's own material
// and tint updates, so that appearance-dependent state owned elsewhere — the
// header art tint, in ArtworkDisplayController — can re-derive itself.
@property (nonatomic, copy, nullable) void (^appearanceChangedHandler)(void);

// Only the buttons the controller drives, through their symbol and enabled
// state, are exposed. The traffic lights and the playlist toggle keep their
// actions and hover fade internal, so they stay private to the view.
@property (readonly) SymbolButton *playButton;
@property (readonly) SymbolButton *nextButton;

// Applies the persisted visibility of the custom close and minimize buttons.
- (void)setTrafficLightsShown:(BOOL)shown;

// The tint wash over the header's glass panel. The artwork controller sets its
// layer background to the current track's dominant art color. It is a plain
// view rather than the glass's own tintColor, because NSGlassEffectView drops
// its tint entirely while the window is inactive, and the wash must not change
// with key state; see ArtworkDisplayController.
@property (readonly) NSView *headerTintView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) AudioWaveformView *waveformView;

@property (readonly) NSTextField *artistTextField;
@property (readonly) NSTextField *titleTextField;
@property (readonly) NSTextField *totalTimeTextField;
@property (readonly) NSTextField *currentTimeTextField;
// The empty-state hint, "Drop a file or press ⌘O", shown only while no track
// is loaded.
@property (readonly) NSTextField *dropHintTextField;
@property (readonly) NSTextField *fileMetadataTextField;
@property (readonly) NSTextField *bpmTextField;

@property (readonly) PlaylistTableView *playlistTableView;
// The drop-target UI spanning the playlist pane: the empty-state hint and the
// drag-over wells. It is built hidden. The controller drives it from the
// updateUI funnel, on playlistEmpty and the launch grace, and forwards the
// window's drag-over events.
@property (readonly) PlaylistDropZoneView *playlistDropZoneView;

// Re-caps the artist line's width so that it truncates clear of the codec
// line's text rather than running under it. The view calls this itself on every
// resize; TrackDisplayController calls it whenever the codec line's content
// changes, since the clearance depends on how wide that text renders.
- (void)layoutArtistLineClearOfCodecLine;

@end

NS_ASSUME_NONNULL_END
