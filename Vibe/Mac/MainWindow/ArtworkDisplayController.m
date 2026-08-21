//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "ArtworkDisplayRules.h"
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
#if DEBUG
#import "ArtworkDisplayController+Debug.h"
#endif

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

// Inputs owned by one background render. The private image copy prevents the
// worker from drawing an NSImage instance used by AppKit on the main thread.
@interface ArtworkRenderRequest : NSObject
@property (nonatomic, strong, readonly) NSImage *sourceArt;
@property (nonatomic, strong, readonly) NSImage *renderSource;
@property (nonatomic, strong, readonly) AudioTrack *track;
@property (nonatomic, strong, readonly) AudioTrackMetadata *metadata;
@property (nonatomic, strong, readonly, nullable) NSColor *cachedColor;
@property (nonatomic, readonly) NSUInteger artworkRenderGeneration;
- (instancetype)initWithSourceArt:(NSImage *)sourceArt
                     renderSource:(NSImage *)renderSource
                            track:(AudioTrack *)track
                         metadata:(AudioTrackMetadata *)metadata
                      cachedColor:(nullable NSColor *)cachedColor
                       generation:(NSUInteger)generation;
@end

@implementation ArtworkRenderRequest

- (instancetype)initWithSourceArt:(NSImage *)sourceArt
                     renderSource:(NSImage *)renderSource
                            track:(AudioTrack *)track
                         metadata:(AudioTrackMetadata *)metadata
                      cachedColor:(nullable NSColor *)cachedColor
                       generation:(NSUInteger)generation {
    self = [super init];
    if (self) {
        _sourceArt = sourceArt;
        _renderSource = renderSource;
        _track = track;
        _metadata = metadata;
        _cachedColor = cachedColor;
        _artworkRenderGeneration = generation;
    }
    return self;
}

@end

// The background render publishes one read-only product: the square bitmap and
// the color sampled from that exact bitmap. Neither can get ahead of the other
// at a track transition.
@interface ArtworkDisplayResult : NSObject
@property (nonatomic, strong, readonly) NSImage *squareImage;
@property (nonatomic, strong, readonly, nullable) NSColor *dominantColor;
- (instancetype)initWithSquareImage:(NSImage *)squareImage
                       dominantColor:(nullable NSColor *)dominantColor;
@end

@implementation ArtworkDisplayResult

- (instancetype)initWithSquareImage:(NSImage *)squareImage
                       dominantColor:(nullable NSColor *)dominantColor {
    self = [super init];
    if (self) {
        _squareImage = squareImage;
        _dominantColor = dominantColor;
    }
    return self;
}

@end

@interface ArtworkDisplayController ()
- (void)startRenderRequest:(ArtworkRenderRequest *)request;
- (void)completeRenderRequest:(ArtworkRenderRequest *)request
                        result:(ArtworkDisplayResult *)result;
@end

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    NSView                      *_headerTintView;
    NSColor                     *_dominantArtColor; // raw; clamps applied per-appearance at apply time
    // The raw dominant color per source image, under weak keys so it dies with
    // the decoded art. A shared folder cover is sampled once, while a replaced
    // source cannot inherit the previous image's tint.
    NSMapTable<NSImage *, NSColor *> *_dominantColorByArt;
    __weak NSImage              *_displayedArt;
    // What is actually installed, which _displayedArt cannot answer: it is
    // weak, and a FOLDER cover's only strong owner is FolderArtResolver's image
    // cache, so it self-nils the moment that cache drops the image while the
    // cropped copy stays on screen.
    BOOL                         _showingDefaultArt;
    // The track whose crop is actually installed. Unlike _displayedArt this
    // survives the source image's weak reference disappearing, so ownership
    // remains exact through a KeepPrevious transition.
    __weak AudioTrack           *_displayedArtTrack;
    __weak AudioTrackMetadata   *_displayedArtMetadata;
    // The source whose crop is in flight. Kept separately from _displayedArt:
    // the latter must describe what the view actually shows, especially while
    // the slow-load placeholder decides whether the pending track's art won.
    __weak NSImage              *_pendingArt;
    // The track whose full-resolution art is currently held decoded. The
    // reference is weak, so that if the playlist is replaced the track
    // deallocates and takes its art with it.
    __weak AudioTrack           *_artOwnerTrack;
    // The exact track, metadata and source image the header currently
    // describes. Changing any identity invalidates stale crops without
    // replacing the installed image kept through an unresolved transition.
    __weak AudioTrack           *_artworkTargetTrack;
    __weak AudioTrackMetadata   *_artworkTargetMetadata;
    __weak NSImage              *_artworkTargetArt;
    // Pairs each async crop-and-color render with the request that owns both
    // products. Neither a stale image nor its color may land over what
    // superseded it.
    NSUInteger                  _artworkRenderGeneration;
    // Main-confined admission for the serial utility lane. Only the running
    // request is dispatched; rapid changes replace this one waiting request.
    dispatch_queue_t            _artworkRenderQueue;
    ArtworkRenderRequest       *_queuedRenderRequest;
    BOOL                        _renderInFlight;
    BOOL                        _initialized;
}

- (instancetype)initWithContentView:(MainPlayerContentView *)contentView {
    self = [super init];
    if (self) {
        _artworkView = contentView.albumArtImageView;
        _headerTintView = contentView.headerTintView;
        _dominantColorByArt = [NSMapTable weakToStrongObjectsMapTable];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _artworkRenderQueue = dispatch_queue_create("com.vibe.artwork.render", attributes);
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

- (NSColor *)dominantArtColor {
    return _dominantArtColor;
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

// Produces the square display bitmap and its dominant color together off-main.
// The source copy belongs only to this worker: the original may be in Now
// Playing while the result, once complete, belongs to the artwork view. No one
// NSImage instance is therefore drawn concurrently across threads. The one
// main-thread delivery starts the image and tint crossfades together.
- (void)renderArt:(NSImage *)art
         forTrack:(AudioTrack *)track
         metadata:(AudioTrackMetadata *)metadata {
    // Copy before hopping queues, matching the dock renderer's ownership rule.
    // NSImage's per-instance drawing cache is not documented thread-safe.
    NSImage *renderSource = [art copy];
    if (!renderSource) {
        return;
    }
    NSUInteger generation = ++_artworkRenderGeneration;
    _pendingArt = art;
    NSColor *cachedColor = [_dominantColorByArt objectForKey:art];
    ArtworkRenderRequest *request = [[ArtworkRenderRequest alloc]
            initWithSourceArt:art renderSource:renderSource track:track
                      metadata:metadata cachedColor:cachedColor
                    generation:generation];
    if (_renderInFlight) {
        _queuedRenderRequest = request;
        return;
    }
    [self startRenderRequest:request];
}

- (void)startRenderRequest:(ArtworkRenderRequest *)request {
    _renderInFlight = YES;
    __weak ArtworkDisplayController *weakSelf = self;
    dispatch_async(_artworkRenderQueue, ^{
        @autoreleasepool {
            NSImage *square = [request.renderSource squareCroppedImage]
                    ?: request.renderSource;
            NSColor *color = request.cachedColor ?: [square dominantColor];
            ArtworkDisplayResult *result = [[ArtworkDisplayResult alloc]
                    initWithSquareImage:square dominantColor:color];
            dispatch_async(dispatch_get_main_queue(), ^{
                ArtworkDisplayController *strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                [strongSelf completeRenderRequest:request result:result];
            });
        }
    });
}

- (void)completeRenderRequest:(ArtworkRenderRequest *)request
                        result:(ArtworkDisplayResult *)result {
    // Cache even a stale color. It is still right for the source image that
    // requested it, merely not for the current display.
    if (result.dominantColor) {
        [_dominantColorByArt setObject:result.dominantColor
                                forKey:request.sourceArt];
    }
    if (VibeArtworkRenderResultMayInstall(request.artworkRenderGeneration,
                                          _artworkRenderGeneration,
                                          request.track,
                                          request.metadata,
                                          request.sourceArt,
                                          _artworkTargetTrack,
                                          _artworkTargetMetadata,
                                          _artworkTargetArt)) {
        _pendingArt = nil;
        _artworkView.image = result.squareImage;
        _dominantArtColor = result.dominantColor;
        if (self.dominantColorDidChangeHandler) {
            self.dominantColorDidChangeHandler();
        }
        [self refreshHeaderTint];
        [NSDockTile setDockIcon:result.squareImage];
        _displayedArt = request.sourceArt;
        _displayedArtTrack = request.track;
        _displayedArtMetadata = request.metadata;
        _showingDefaultArt = NO;
    }

    _renderInFlight = NO;
    ArtworkRenderRequest *nextRequest = _queuedRenderRequest;
    _queuedRenderRequest = nil;
    if (nextRequest) {
        [self startRenderRequest:nextRequest];
    }
}

// The artwork display policy: new art replaces old art directly. While the new
// track's art is still unresolved — metadata pending, a load worth
// dispatching, or a load in flight — the previous track's art stays on screen,
// so the default never flashes between tracks. The default backdrop is
// installed only once the track is known to be artless.
- (void)updateForTrack:(AudioTrack *)track {
    // Snapshot before choosing the render target. A failed fallback may be
    // replaced by successful metadata on the same AudioTrack, and one metadata
    // object can acquire a new cached source after an asynchronous art load.
    AudioTrackMetadata *metadata = track.metadata;
    NSImage *art = metadata.cachedArt;
    if (_artworkTargetTrack != track || _artworkTargetMetadata != metadata ||
            _artworkTargetArt != art) {
        _artworkTargetTrack = track;
        _artworkTargetMetadata = metadata;
        _artworkTargetArt = art;
        _artworkRenderGeneration++;
        _pendingArt = nil;
        _queuedRenderRequest = nil;
    }
    // The art view doubles as the track's drag-out source, and the URL follows
    // the displayed track directly rather than the keep-previous art policy
    // below: a drag during the unresolved gap must export the track the header
    // names.
    _artworkView.fileURL = track.url;
    // artLoadPending is cleared before a load completes, so here it means
    // exactly that a load is in flight.
    BOOL artResolved = metadata != nil && !metadata.artNeedsLoad &&
                       !metadata.artLoadPending;
    VibeArtworkDisplayAction action = VibeArtworkDisplayActionFor(track != nil, art != nil,
                                                                  artResolved, _initialized);
    _initialized = YES;
    if (action == VibeArtworkDisplayActionShowDefault) {
        [self showDefaultArtwork];
    }
    if (!track) {
        return;
    }
    if (action == VibeArtworkDisplayActionInstall) {
        if (_displayedArt == art) {
            // Adjacent files can share one folder-cover image. The installed
            // crop is already exact; transfer its presentation identity rather
            // than repeat the crop and color pass.
            _displayedArtTrack = track;
            _displayedArtMetadata = metadata;
            _showingDefaultArt = NO;
        }
        else if (_pendingArt != art) {
            // Both surfaces frame art square and aspect-fit it, so the worker
            // crops once rather than letterboxing a wide or tall cover in the
            // header view and again in the dock tile. Both identity marks stay
            // on the source image: the crop is a fresh object every time, and
            // comparing it would re-render on every update while it is pending
            // or after it lands.
            //
            // The crop is deliberately confined to these two. Now Playing
            // publishes track.cachedArt itself (NowPlayingController), and must
            // keep receiving the uncropped original — Control Center frames it
            // on its own terms.
            [self renderArt:art forTrack:track metadata:metadata];
        }
        return;
    }

    // A dead controller answers "not wanted", which demotes the decode rather
    // than stranding it: a track that never started playing never becomes
    // _artOwnerTrack, so nothing else would drop the 4-9MB this load pinned.
    __weak ArtworkDisplayController *weakSelf = self;
    [metadata loadArtIfNeededStillWanted:^BOOL{
        ArtworkDisplayController *strongSelf = weakSelf;
        AudioTrack *currentTrack = strongSelf.currentTrackProvider
                ? strongSelf.currentTrackProvider() : nil;
        return currentTrack == track && track.metadata == metadata;
    } completion:^(NSImage *loaded) {
        ArtworkDisplayController *strongSelf = weakSelf;
        // The same rule the pass above applies, so a load's outcome and a plain
        // refresh cannot disagree about when the backdrop wins.
        switch (VibeArtworkDisplayActionFor(YES, loaded != nil,
                                            !metadata.artNeedsLoad, YES)) {
            case VibeArtworkDisplayActionInstall:
                if (strongSelf.artDidResolveHandler) {
                    strongSelf.artDidResolveHandler();
                }
                break;
            case VibeArtworkDisplayActionShowDefault:
                [strongSelf showDefaultArtwork];
                break;
            case VibeArtworkDisplayActionKeepPrevious:
                // The folder is still being resolved by another worker, so this
                // nil is not artlessness. artNeedsLoad stays YES and the next
                // pass retries.
                break;
        }
    }];
}

// A slow cloud open is taking long enough to show the loading shimmer. The
// keep-previous-art policy would hold the old track's art for up to the
// 20-second open timeout, so show the empty-state default instead. If the
// pending track's art has already resolved, updateForTrack: displayed it, so
// keep that.
- (void)showPlaceholderForSlowLoad {
    AudioTrack *track = self.currentTrackProvider ? self.currentTrackProvider() : nil;
    AudioTrackMetadata *metadata = track.metadata;
    NSImage *art = metadata.cachedArt;
    if (art && _displayedArt == art && _displayedArtTrack == track &&
            _displayedArtMetadata == metadata) {
        return;
    }
    // If this track's crop is already in flight, the placeholder is only its
    // backdrop while it finishes; let that result replace the default. A render
    // for any other source belongs to the departed track and is invalidated.
    BOOL currentCropPending = art && _pendingArt == art &&
            _artworkTargetTrack == track && _artworkTargetMetadata == metadata &&
            _artworkTargetArt == art;
    [self showDefaultArtworkInvalidatingRender:!currentCropPending];
}

// Installs the record-bg default art and clears the glass tint. An ordinary
// default decision invalidates any pending render even when the visuals are
// already correct; the slow-load placeholder can preserve the current track's
// render so that its result still replaces the temporary backdrop.
- (void)showDefaultArtwork {
    [self showDefaultArtworkInvalidatingRender:YES];
}

- (void)showDefaultArtworkInvalidatingRender:(BOOL)invalidateRender {
    if (invalidateRender) {
        _artworkRenderGeneration++; // orphan any in-flight crop-and-color result
        _pendingArt = nil;
        _queuedRenderRequest = nil;
    }
    if (_showingDefaultArt && _initialized) {
        return;
    }
    _artworkView.image = [NSImage imageNamed:@"record-bg"];
    _dominantArtColor = nil;
    if (self.dominantColorDidChangeHandler) {
        self.dominantColorDidChangeHandler();
    }
    [self refreshHeaderTint];
    [NSDockTile resetToAppIcon];
    _displayedArt = nil;
    _displayedArtTrack = nil;
    _displayedArtMetadata = nil;
    _showingDefaultArt = YES;
}

- (void)trackDidStartPlaying:(AudioTrack *)track {
    // Demote the previous track's full-resolution art: the decoded bitmap and
    // the compressed bytes, some 4-9MB together. Without this, every track
    // played in a session stays pinned for the playlist's lifetime. The
    // thumbnail is kept, and the art reloads on demand if the track becomes
    // current again.
    if (_artOwnerTrack && _artOwnerTrack != track) {
        [_artOwnerTrack.metadata discardDecodedArt];
    }
    _artOwnerTrack = track;
}

#if DEBUG
- (AudioTrack *)debugArtworkTargetTrack {
    return _artworkTargetTrack;
}

- (AudioTrackMetadata *)debugArtworkTargetMetadata {
    return _artworkTargetMetadata;
}

- (NSImage *)debugArtworkTargetArt {
    return _artworkTargetArt;
}

- (AudioTrack *)debugInstalledArtworkOwnerTrack {
    return _displayedArtTrack;
}

- (AudioTrackMetadata *)debugInstalledArtworkMetadata {
    return _displayedArtMetadata;
}

- (NSImage *)debugInstalledArtworkSource {
    return _displayedArt;
}

- (BOOL)debugShowingDefaultArtwork {
    return _showingDefaultArt;
}

- (BOOL)debugArtworkRenderPending {
    return _pendingArt != nil && _pendingArt == _artworkTargetArt;
}
#endif

@end
