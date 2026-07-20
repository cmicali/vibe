//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "ArtworkImageView.h"
#import "NSDockTile+Util.h"
#import "NSImage+Util.h"
#import "NSView+DarkMode.h"
#import "CrossfadingImageView.h"
#import <QuartzCore/QuartzCore.h>

// The raw dominant color can be anything from neon to near-black; pulling
// saturation/brightness into an appearance-specific band keeps the tint
// recognizable as the art's color without overpowering the glass or
// silhouetting the labels. Dark glass wants a deeper, fuller wash; the same
// values over the bright light material read as muddy paint, so light mode
// forces a brighter, softer pastel instead.
static const CGFloat kTintAlphaDark          = 0.4;
static const CGFloat kTintMaxBrightnessDark  = 0.39;
static const CGFloat kTintMinBrightnessDark  = 0.21;
static const CGFloat kTintMaxSaturationDark  = 0.75;
// Light alpha is deliberately high: the light glass shows a warm blur of
// whatever is behind the window, and a subtle wash loses to it — the wash
// has to own the header's color for the pastel to read.
static const CGFloat kTintAlphaLight         = 0.55;
static const CGFloat kTintMaxBrightnessLight = 0.97;
static const CGFloat kTintMinBrightnessLight = 0.85;
static const CGFloat kTintMaxSaturationLight = 0.45;

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    NSView                      *_headerTintView;
    NSColor                     *_dominantArtColor; // raw; clamps applied per-appearance at apply time
    // Raw dominant color per track (weak keys: dies with the playlist). The
    // color is a pure function of the track's art, which is stable for the
    // track's lifetime — revisiting a track re-decodes its demoted art
    // (deliberate memory tradeoff) but need not resample it for the tint.
    NSMapTable<AudioTrack *, NSColor *> *_dominantColorByTrack;
    __weak NSImage              *_displayedArt;
    // Track whose full-res art is currently held decoded (weak: if the
    // playlist was replaced the track deallocates and takes its art with it).
    __weak AudioTrack           *_artOwnerTrack;
    // Pairs each async dominant-color computation with the art that requested
    // it — utility-queue blocks can complete out of order, and a stale color
    // must not land over the tint that superseded it.
    NSUInteger                  _tintGeneration;
    BOOL                        _initialized;
}

- (instancetype)initWithArtworkView:(ArtworkImageView *)artworkView
                     headerTintView:(NSView *)headerTintView {
    self = [super init];
    if (self) {
        _artworkView = artworkView;
        _headerTintView = headerTintView;
        _dominantColorByTrack = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

// Derives the on-screen wash from the raw dominant color (appearance clamps
// applied here) and pushes it to the header. Also the public refresh hook for
// appearance changes. The wash is this view's own backgroundColor, not the
// glass's tintColor — AppKit silently discards a glass tint whenever the
// window isn't key, and the window must look the same active or not.
- (void)refreshHeaderTint {
    NSColor *color = nil;
    if (_dominantArtColor) {
        BOOL dark = _headerTintView.isDark;
        CGFloat maxSat = dark ? kTintMaxSaturationDark : kTintMaxSaturationLight;
        CGFloat minBri = dark ? kTintMinBrightnessDark : kTintMinBrightnessLight;
        CGFloat maxBri = dark ? kTintMaxBrightnessDark : kTintMaxBrightnessLight;
        CGFloat alpha  = dark ? kTintAlphaDark : kTintAlphaLight;
        CGFloat hue, saturation, brightness;
        [_dominantArtColor getHue:&hue saturation:&saturation brightness:&brightness alpha:NULL];
        color = [NSColor colorWithHue:hue
                           saturation:MIN(saturation, maxSat)
                           brightness:MAX(minBri, MIN(brightness, maxBri))
                                alpha:alpha];
    }
    // AppKit disables implicit actions on a view's backing layer, so the fade
    // is explicit: set the model value action-free, then animate from the
    // presentationLayer's current color (retargets a fade already in flight).
    // "No tint" animates as clearColor rather than nil so the fade-out is a
    // color ramp, not an instant clear.
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

// Tints the header glass to the art's dominant color. dominantColor renders
// a 32px downscale and samples 1024 pixels — too much for the main thread on
// the exact track-transition frame — so it runs off-main (bitmap-context
// drawing is thread-safe) and applies on main; the tint fades a beat after
// the art, which the crossfade hides. A track whose color was already
// computed this session applies synchronously from the cache instead.
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
            // Cache even a stale result — the color is still right for the
            // track that requested it, just not for the current tint.
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

// Artwork display policy: new art replaces old art directly. While the new
// track's art is still unresolved (metadata pending, load worth dispatching,
// or a load in flight), the PREVIOUS track's art stays on screen — no flash
// of the default between tracks. The default backdrop is installed only when
// the track is known to be artless.
- (void)updateForTrack:(AudioTrack *)track {
    if (!track) {
        // No file loaded. Without this, a nil track reads as "art unresolved"
        // below and the keep-previous-art policy would leave the closed
        // track's art and tint up.
        [self showDefaultArtwork];
        _initialized = YES;
        return;
    }
    if (track.albumArt) {
        if (_displayedArt != track.albumArt) {
            _artworkView.image = track.albumArt;
            [self applyHeaderTintFromArt:track.albumArt forTrack:track];
            [NSDockTile setDockIcon:track.albumArt];
            _displayedArt = track.albumArt;
        }
        _initialized = YES;
        return;
    }

    AudioTrackMetadata *metadata = track.metadata;
    // albumArtLoadDispatched is cleared when a load completes, so here it
    // means exactly "a load is in flight".
    BOOL artUnresolved = !metadata || metadata.albumArtNeedsLoad || metadata.albumArtLoadDispatched;
    if (!artUnresolved || !_initialized) {
        [self showDefaultArtwork];
    }
    _initialized = YES;

    // Cache-hit metadata doesn't carry the art bytes; extracting them
    // re-reads the audio file, which can block on a cloud placeholder
    // until it downloads. Do it off the main thread and refresh when done.
    if (metadata.albumArtNeedsLoad && !metadata.albumArtLoadDispatched) {
        metadata.albumArtLoadDispatched = YES;
        __weak ArtworkDisplayController *weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *loaded = metadata.albumArt; // may block; background thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Resolved either way — clear the in-flight marker. No
                // duplicate-dispatch risk: albumArtNeedsLoad is NO after any
                // completion (image decoded, or attempted and artless).
                metadata.albumArtLoadDispatched = NO;
                ArtworkDisplayController *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                AudioTrack *currentTrack = strongSelf.currentTrackProvider
                        ? strongSelf.currentTrackProvider() : nil;
                if (currentTrack != track) {
                    // Skipped away before the load resolved: a track that
                    // never started playing never becomes _artOwnerTrack, so
                    // nothing else would demote the full-res art (~4-9MB)
                    // this load just pinned.
                    [metadata discardDecodedAlbumArt];
                    return;
                }
                if (loaded) {
                    if (strongSelf.artDidResolveHandler) {
                        strongSelf.artDidResolveHandler();
                    }
                }
                else {
                    // Definitively artless: only now does the default
                    // replace the previous track's art.
                    [strongSelf showDefaultArtwork];
                }
            });
        });
    }
}

// A slow (cloud) open is taking long enough to show the loading shimmer. The
// keep-previous-art policy would hold the OLD track's art for up to the open
// timeout (20s) — show the empty-state default instead. If the pending
// track's art already resolved, updateForTrack: displayed it; keep that.
- (void)showPlaceholderForSlowLoad {
    AudioTrack *track = self.currentTrackProvider ? self.currentTrackProvider() : nil;
    if (track.albumArt && _displayedArt == track.albumArt) {
        return;
    }
    [self showDefaultArtwork];
}

// Installs the record-bg default art and clears the glass tint (no-op if
// already showing).
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
    // Demote the previous track's full-res art (decoded bitmap + compressed
    // bytes, ~4-9MB together). Without this, every track played in a session
    // stays pinned for the playlist's lifetime. The thumbnail is kept; the art
    // reloads on demand if the track becomes current again.
    if (_artOwnerTrack && _artOwnerTrack != track) {
        [_artOwnerTrack.metadata discardDecodedAlbumArt];
    }
    _artOwnerTrack = track;
}

@end
