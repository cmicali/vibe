//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "MainPlayerContentView.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "ArtworkImageView.h"
#import "NSDockTile+Util.h"
#import "NSImage+Util.h"
#import "NSColor+OKLCH.h"
#import "NSView+DarkMode.h"
#import "CrossfadingImageView.h"
#import <QuartzCore/QuartzCore.h>

// The raw dominant color can be anything from neon to near-black. Pulling it
// into an appearance-specific band keeps the tint recognizable as the art's
// color without overpowering the glass or silhouetting the labels.
//
// The clamps are perceptual, in OKLCH through NSColor+OKLCH, rather than HSB.
// The waveform must stay distinguishable from the wash over any artwork, and
// HSB brightness is hue-blind: a yellow at B=0.39 is far lighter to the eye
// than a blue at B=0.39, so an HSB cap lets bright-hued art wash the unplayed
// waveform out.
//
// Dark glass carries a light waveform, so cap perceptual lightness low, at
// 0.30 or less, with a floor so that near-black art still shows a hue. The
// same values over the bright light material read as muddy paint, so light
// mode, with its dark waveform, clamps lightness high instead: the same
// contrast goal in the opposite direction. Chroma is capped moderately in both.
static const CGFloat kTintAlphaDark          = 0.4;
static const CGFloat kTintMinLightnessDark   = 0.16;
static const CGFloat kTintMaxLightnessDark   = 0.30;
static const CGFloat kTintMaxChromaDark      = 0.09;
// The light-mode alpha is deliberately high. The light glass shows a warm blur
// of whatever is behind the window, and a subtle wash loses to it: the wash has
// to own the header's color for the pastel to read.
static const CGFloat kTintAlphaLight         = 0.55;
static const CGFloat kTintMinLightnessLight  = 0.87;
static const CGFloat kTintMaxLightnessLight  = 0.94;
static const CGFloat kTintMaxChromaLight     = 0.10;

// The playlist accent, on the playing row's equalizer bars, is the same
// dominant color normalized into a band that reads as color over the playlist
// frost: lighter than the wash in dark mode, darker in light.
static const CGFloat kAccentMinLightnessDark  = 0.72;
static const CGFloat kAccentMaxLightnessDark  = 0.84;
static const CGFloat kAccentMinLightnessLight = 0.40;
static const CGFloat kAccentMaxLightnessLight = 0.52;
static const CGFloat kAccentMaxChroma         = 0.17;

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    NSView                      *_headerTintView;
    NSColor                     *_dominantArtColor; // raw; clamps applied per-appearance at apply time
    // The raw dominant color per track, under weak keys so it dies with the
    // playlist. The color is a pure function of the track's art, which is
    // stable for the track's lifetime. Revisiting a track re-decodes its
    // demoted art, a deliberate memory tradeoff, but need not resample it for
    // the tint.
    NSMapTable<AudioTrack *, NSColor *> *_dominantColorByTrack;
    __weak NSImage              *_displayedArt;
    // The track whose full-resolution art is currently held decoded. The
    // reference is weak, so that if the playlist is replaced the track
    // deallocates and takes its art with it.
    __weak AudioTrack           *_artOwnerTrack;
    // Pairs each async dominant-color computation with the art that requested
    // it. Utility-queue blocks can complete out of order, and a stale color
    // must not land over the tint that superseded it.
    NSUInteger                  _tintGeneration;
    BOOL                        _initialized;
}

- (instancetype)initWithContentView:(MainPlayerContentView *)contentView {
    self = [super init];
    if (self) {
        _artworkView = contentView.albumArtImageView;
        _headerTintView = contentView.headerTintView;
        _dominantColorByTrack = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

// Derives the on-screen wash from the raw dominant color, applying the
// appearance clamps here, and pushes it to the header. It is also the public
// refresh hook for appearance changes. The wash is this view's own
// backgroundColor rather than the glass's tintColor, because AppKit silently
// discards a glass tint whenever the window is not key, and the window must
// look the same whether active or not.
//
// The appearance to clamp against is resolved from the window, not from
// _headerTintView. This method's appearance-change caller is the content
// view's own viewDidChangeEffectiveAppearance, and at that point a subview's
// effectiveAppearance still reports the outgoing appearance, because AppKit
// updates the tree top-down, one callback per view. Reading the tint view
// there left both the wash and the accent a full appearance behind on every
// live light-dark toggle, and a dark-band wash under the light appearance is
// exactly the waveform-contrast failure the clamps exist to prevent. The
// window's appearance is set before any of those callbacks, so it is never
// stale.
- (BOOL)isDarkAppearance {
    NSAppearance *appearance = _headerTintView.window.effectiveAppearance
            ?: _headerTintView.effectiveAppearance;
    return [NSAppearanceNameDarkAqua isEqualToString:
            [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                            NSAppearanceNameDarkAqua ]]];
}

- (void)refreshHeaderTint {
    NSColor *color = nil;
    BOOL dark = [self isDarkAppearance];
    if (_dominantArtColor) {
        color = dark
                ? [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kTintMinLightnessDark
                                                              lightnessMax:kTintMaxLightnessDark
                                                                 chromaMax:kTintMaxChromaDark
                                                                     alpha:kTintAlphaDark]
                : [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kTintMinLightnessLight
                                                              lightnessMax:kTintMaxLightnessLight
                                                                 chromaMax:kTintMaxChromaLight
                                                                     alpha:kTintAlphaLight];
    }
    // The accent rides the tint's resolution: the same source color and the
    // same triggers — a track or art change, an appearance flip, a clear to
    // the default.
    if (self.accentColorDidChangeHandler) {
        NSColor *accent = nil;
        if (_dominantArtColor) {
            accent = dark
                    ? [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kAccentMinLightnessDark
                                                                  lightnessMax:kAccentMaxLightnessDark
                                                                     chromaMax:kAccentMaxChroma
                                                                         alpha:1.0]
                    : [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kAccentMinLightnessLight
                                                                  lightnessMax:kAccentMaxLightnessLight
                                                                     chromaMax:kAccentMaxChroma
                                                                         alpha:1.0];
        }
        self.accentColorDidChangeHandler(accent);
    }
    // AppKit disables implicit actions on a view's backing layer, so the fade
    // is explicit: set the model value action-free, then animate from the
    // presentationLayer's current color, which retargets a fade already in
    // flight. "No tint" animates as clearColor rather than nil, so the fade-out
    // is a color ramp rather than an instant clear.
    CALayer *layer = _headerTintView.layer;
    CGColorRef newColor = (color ?: NSColor.clearColor).CGColor;
    CALayer *presentation = layer.presentationLayer ?: layer;
    CGColorRef fromColor = presentation.backgroundColor ?: NSColor.clearColor.CGColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.backgroundColor = newColor;
    [CATransaction commit];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    fade.fromValue = (__bridge id)fromColor;
    fade.toValue = (__bridge id)newColor;
    fade.duration = kVibeArtCrossfadeDuration;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:fade forKey:@"tintFade"];
}

// Tints the header glass to the art's dominant color. dominantColor renders a
// 32px downscale and samples 1,024 pixels, which is too much for the main
// thread on the exact track-transition frame, so it runs off-main —
// bitmap-context drawing is thread-safe — and applies on main. The tint
// therefore fades a beat after the art, which the crossfade hides. A track
// whose color was already computed this session applies synchronously from the
// cache instead.
- (void)applyHeaderTintFromArt:(NSImage *)art forTrack:(AudioTrack *)track {
    NSUInteger generation = ++_tintGeneration;
    NSColor *cached = track ? [_dominantColorByTrack objectForKey:track] : nil;
    if (cached) {
        _dominantArtColor = cached;
        [self refreshHeaderTint];
        return;
    }
    __weak ArtworkDisplayController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSColor *color = [art dominantColor];
        dispatch_async(dispatch_get_main_queue(), ^{
            ArtworkDisplayController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            // Cache even a stale result. The color is still right for the
            // track that requested it, merely not for the current tint.
            if (color && track) {
                [strongSelf->_dominantColorByTrack setObject:color forKey:track];
            }
            if (generation != strongSelf->_tintGeneration) {
                return; // newer art (or the default) owns the tint now
            }
            strongSelf->_dominantArtColor = color;
            [strongSelf refreshHeaderTint];
        });
    });
}

// The artwork display policy: new art replaces old art directly. While the new
// track's art is still unresolved — metadata pending, a load worth
// dispatching, or a load in flight — the previous track's art stays on screen,
// so the default never flashes between tracks. The default backdrop is
// installed only once the track is known to be artless.
- (void)updateForTrack:(AudioTrack *)track {
    // The art view doubles as the track's drag-out source, and the URL follows
    // the displayed track directly rather than the keep-previous art policy
    // below: a drag during the unresolved gap must export the track the header
    // names.
    _artworkView.fileURL = track.url;
    if (!track) {
        // No file is loaded. Without this, a nil track would read as art
        // unresolved below, and the keep-previous-art policy would leave the
        // closed track's art and tint on screen.
        [self showDefaultArtwork];
        _initialized = YES;
        return;
    }
    // One read, because the identity check and the install must see the same
    // object.
    NSImage *art = track.albumArt;
    if (art) {
        if (_displayedArt != art) {
            _artworkView.image = art;
            [self applyHeaderTintFromArt:art forTrack:track];
            [NSDockTile setDockIcon:art];
            _displayedArt = art;
        }
        _initialized = YES;
        return;
    }

    AudioTrackMetadata *metadata = track.metadata;
    // albumArtLoadDispatched is cleared when a load completes, so here it
    // means exactly that a load is in flight.
    BOOL artUnresolved = !metadata || metadata.albumArtNeedsLoad || metadata.albumArtLoadDispatched;
    if (!artUnresolved || !_initialized) {
        [self showDefaultArtwork];
    }
    _initialized = YES;

    // Cache-hit metadata does not carry the art bytes, and extracting them
    // re-reads the audio file, which can block on a cloud placeholder until it
    // downloads. Do it off the main thread and refresh when it is done.
    if (metadata.albumArtNeedsLoad && !metadata.albumArtLoadDispatched) {
        metadata.albumArtLoadDispatched = YES;
        __weak ArtworkDisplayController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *loaded = metadata.albumArt; // may block; background thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // It is resolved either way, so clear the in-flight marker.
                // There is no risk of a duplicate dispatch, because
                // albumArtNeedsLoad is NO after any completion, whether the
                // image was decoded or the attempt found the track artless.
                metadata.albumArtLoadDispatched = NO;
                ArtworkDisplayController *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                AudioTrack *currentTrack = strongSelf.currentTrackProvider
                        ? strongSelf.currentTrackProvider() : nil;
                if (currentTrack != track) {
                    // The user skipped away before the load resolved. A track
                    // that never started playing never becomes
                    // _artOwnerTrack, so nothing else would demote the 4-9MB
                    // of full-resolution art this load has just pinned.
                    [metadata discardDecodedAlbumArt];
                    return;
                }
                if (loaded) {
                    if (strongSelf.artDidResolveHandler) {
                        strongSelf.artDidResolveHandler();
                    }
                }
                else {
                    // Definitively artless. Only now does the default replace
                    // the previous track's art.
                    [strongSelf showDefaultArtwork];
                }
            });
        });
    }
}

// A slow cloud open is taking long enough to show the loading shimmer. The
// keep-previous-art policy would hold the old track's art for up to the
// 20-second open timeout, so show the empty-state default instead. If the
// pending track's art has already resolved, updateForTrack: displayed it, so
// keep that.
- (void)showPlaceholderForSlowLoad {
    AudioTrack *track = self.currentTrackProvider ? self.currentTrackProvider() : nil;
    NSImage *art = track.albumArt;
    if (art && _displayedArt == art) {
        return;
    }
    [self showDefaultArtwork];
}

// Installs the record-bg default art and clears the glass tint. It is a no-op
// if they are already showing.
- (void)showDefaultArtwork {
    if (!_displayedArt && _initialized) {
        return;
    }
    _artworkView.image = [NSImage imageNamed:@"record-bg"];
    _tintGeneration++; // orphan any in-flight dominant-color computation
    _dominantArtColor = nil;
    [self refreshHeaderTint];
    [NSDockTile resetToAppIcon];
    _displayedArt = nil;
}

- (void)trackDidStartPlaying:(AudioTrack *)track {
    // Demote the previous track's full-resolution art: the decoded bitmap and
    // the compressed bytes, some 4-9MB together. Without this, every track
    // played in a session stays pinned for the playlist's lifetime. The
    // thumbnail is kept, and the art reloads on demand if the track becomes
    // current again.
    if (_artOwnerTrack && _artOwnerTrack != track) {
        [_artOwnerTrack.metadata discardDecodedAlbumArt];
    }
    _artOwnerTrack = track;
}

@end
