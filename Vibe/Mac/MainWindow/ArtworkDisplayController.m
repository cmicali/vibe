//
//  ArtworkDisplayController.m
//  Vibe
//

#import "ArtworkDisplayController.h"
#import "ArtworkDisplayRules.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"
#import "MainPlayerContentView.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "ArtworkImageView.h"
#import "NSDockTile+Util.h"
#import "NSImage+Util.h"
#import "PlatformImage.h"
#import "NSColor+OKLCH.h"
#import "NSView+DarkMode.h"
#import "CrossfadingImageView.h"
#import <QuartzCore/QuartzCore.h>
#if DEBUG
#import "ArtworkDisplayController+Debug.h"
#endif

// Per-appearance clamps keep the wash the art's color without swamping the
// glass or the labels. OKLCH, not HSB: HSB brightness is hue-blind, so an HSB
// cap lets bright hues wash out the unplayed waveform. Dark glass carries a
// light waveform, so lightness is capped low (floored so near-black keeps a
// hue); light mode's dark waveform clamps it high instead.
static const CGFloat kTintAlphaDark          = 0.4;
static const CGFloat kTintMinLightnessDark   = 0.16;
static const CGFloat kTintMaxLightnessDark   = 0.30;
static const CGFloat kTintMaxChromaDark      = 0.09;
// High: a subtle wash loses to the light glass's blur of what is behind.
static const CGFloat kTintAlphaLight         = 0.55;
static const CGFloat kTintMinLightnessLight  = 0.87;
static const CGFloat kTintMaxLightnessLight  = 0.94;
static const CGFloat kTintMaxChromaLight     = 0.10;

// The private image copy keeps the worker off any NSImage AppKit draws on main.
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

// One product, so the bitmap and its color cannot get ahead of each other.
@interface ArtworkDisplayResult : NSObject
@property (nonatomic, strong, readonly) NSImage *squareImage;
@property (nonatomic, strong, readonly, nullable) NSColor *dominantColor;
@property (nonatomic, readonly) BOOL lowerBandIsDark;
- (instancetype)initWithSquareImage:(NSImage *)squareImage
                       dominantColor:(nullable NSColor *)dominantColor
                     lowerBandIsDark:(BOOL)lowerBandIsDark;
@end

@implementation ArtworkDisplayResult

- (instancetype)initWithSquareImage:(NSImage *)squareImage
                       dominantColor:(nullable NSColor *)dominantColor
                     lowerBandIsDark:(BOOL)lowerBandIsDark {
    self = [super init];
    if (self) {
        _squareImage = squareImage;
        _dominantColor = dominantColor;
        _lowerBandIsDark = lowerBandIsDark;
    }
    return self;
}

@end

// The share of the art the transport row covers, its 50pt buttons reaching a
// little above kArtworkTransportExclusionHeight.
static const CGFloat kTransportBandFraction = 1.0 / 3;

@interface ArtworkDisplayController ()
- (void)startRenderRequest:(ArtworkRenderRequest *)request;
- (void)completeRenderRequest:(ArtworkRenderRequest *)request
                        result:(ArtworkDisplayResult *)result;
@end

@implementation ArtworkDisplayController {
    ArtworkImageView            *_artworkView;
    NSView                      *_headerTintView;
    NSView                      *_playlistTintView;
    NSColor                     *_dominantArtColor; // raw; clamps applied per-appearance at apply time
    // Per source image, weak-keyed so it dies with the decoded art: a shared
    // folder cover is sampled once, and a replaced source inherits no tint.
    NSMapTable<NSImage *, NSColor *> *_dominantColorByArt;
    __weak NSImage              *_displayedArt;
    // What is installed, which _displayedArt cannot answer: a folder cover's
    // only strong owner is FolderArtResolver's cache, so the weak source can
    // nil while its crop stays on screen.
    BOOL                         _showingDefaultArt;
    // The installed crop's owner, exact through a KeepPrevious transition.
    __weak AudioTrack           *_displayedArtTrack;
    __weak AudioTrackMetadata   *_displayedArtMetadata;
    // The source whose crop is in flight; _displayedArt describes only what
    // the view shows.
    __weak NSImage              *_pendingArt;
    // The track whose full-resolution art is held decoded. Weak, so a replaced
    // playlist takes the art with it.
    __weak AudioTrack           *_artOwnerTrack;
    // What the header describes. Changing any identity invalidates stale crops
    // without replacing the image kept through an unresolved transition.
    __weak AudioTrack           *_artworkTargetTrack;
    __weak AudioTrackMetadata   *_artworkTargetMetadata;
    __weak NSImage              *_artworkTargetArt;
    NSUInteger                  _artworkRenderGeneration;
    // Main-confined: one running render, and one waiting request that rapid
    // changes replace.
    dispatch_queue_t            _artworkRenderQueue;
    ArtworkRenderRequest       *_queuedRenderRequest;
    BOOL                        _renderInFlight;
    BOOL                        _initialized;
    void (^_renderer)(NSImage *, NSColor *, void (^)(NSImage *, NSColor *, BOOL));
    void (^_publication)(NSImage *, NSColor *, BOOL, BOOL);
}

- (instancetype)initWithContentView:(MainPlayerContentView *)contentView {
    self = [self initWithRenderer:nil publication:nil];
    if (self) {
        _artworkView = contentView.albumArtImageView;
        _headerTintView = contentView.headerTintView;
        _playlistTintView = contentView.playlistTintView;
    }
    return self;
}

- (instancetype)initWithRenderer:(void (^)(NSImage *, NSColor *, void (^)(NSImage *, NSColor *, BOOL)))renderer
                      publication:(void (^)(NSImage *, NSColor *, BOOL, BOOL))publication {
    self = [super init];
    if (self) {
        _renderer = [renderer copy];
        _publication = [publication copy];
        _dominantColorByArt = [NSMapTable weakToStrongObjectsMapTable];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _artworkRenderQueue = dispatch_queue_create("com.vibe.artwork.render", attributes);
    }
    return self;
}

// TRAP: light/dark comes from the window, not _headerTintView. The
// appearance-change caller is the content view's
// viewDidChangeEffectiveAppearance, where subviews, updated top-down, still
// report the outgoing appearance: the wash would lag a full toggle behind.
- (NSAppearance *)windowAppearance {
    return _headerTintView.window.effectiveAppearance ?: _headerTintView.effectiveAppearance;
}

- (BOOL)isDarkAppearance {
    return self.windowAppearance.isDark;
}

- (NSColor *)dominantArtColor {
    return _dominantArtColor;
}

// The one home of the wash rules. A custom color is used exactly as picked:
// the clamps tame only a color nobody chose. Mono or an unset custom: no wash.
- (NSColor *)resolvedWashForTint:(NSString *)tint
                     customColor:(NSColor *)customColor
                          isDark:(BOOL)dark {
    if ([tint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return customColor;
    }
    if (![tint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_ARTWORK] || !_dominantArtColor) {
        return nil;
    }
    return dark
            ? [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kTintMinLightnessDark
                                                          lightnessMax:kTintMaxLightnessDark
                                                             chromaMax:kTintMaxChromaDark
                                                                 alpha:kTintAlphaDark]
            : [_dominantArtColor vibe_colorByClampingOKLCHLightnessMin:kTintMinLightnessLight
                                                          lightnessMax:kTintMaxLightnessLight
                                                             chromaMax:kTintMaxChromaLight
                                                                 alpha:kTintAlphaLight];
}

// A backing layer has no implicit actions, so the fade is explicit, from the
// presentation color so an in-flight fade retargets. nil fades as clear.
static void FadeLayerToColor(CALayer *layer, NSColor *color) {
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

// Each wash is a plain view's background, never the glass tintColor, which
// AppKit discards whenever the window is not key.
- (void)refreshTintWashes {
    BOOL dark = [self isDarkAppearance];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    FadeLayerToColor(_headerTintView.layer,
            [self resolvedWashForTint:theme.windowTint
                          customColor:[theme windowTintColorForDark:dark]
                               isDark:dark]);
    FadeLayerToColor(_playlistTintView.layer,
            [self resolvedWashForTint:theme.playlistTint
                          customColor:[theme playlistTintColorForDark:dark]
                               isDark:dark]);
    // The placeholder is one dynamic image whose pixels follow the drawing
    // appearance, so it is re-sampled under the window's appearance on every
    // flip. A track's crop is sampled once, on the worker.
    if (_showingDefaultArt) {
        NSImage *placeholder = _artworkView.image;
        __block BOOL bandIsDark = YES;
        [self.windowAppearance performAsCurrentDrawingAppearance:^{
            bandIsDark = VibeImageLowerBandIsDark(placeholder, kTransportBandFraction);
        }];
        [self publishTransportBackdropDark:bandIsDark];
    }
}

// The worker draws a private copy: NSImage's drawing cache is not documented
// thread-safe, and the original may be drawn by Now Playing meanwhile.
- (void)renderArt:(NSImage *)art
         forTrack:(AudioTrack *)track
         metadata:(AudioTrackMetadata *)metadata {
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
    void (^complete)(NSImage *, NSColor *, BOOL) = ^(NSImage *square, NSColor *color, BOOL dark) {
        NSAssert(NSThread.isMainThread, @"Artwork delivery belongs on main");
        ArtworkDisplayResult *result = [[ArtworkDisplayResult alloc]
                initWithSquareImage:square dominantColor:color lowerBandIsDark:dark];
        [weakSelf completeRenderRequest:request result:result];
    };
    if (_renderer) {
        _renderer(request.renderSource, request.cachedColor, complete);
        return;
    }
    dispatch_async(_artworkRenderQueue, ^{
        @autoreleasepool {
            NSImage *square = [request.renderSource squareCroppedImage] ?: request.renderSource;
            NSColor *color = request.cachedColor ?: [square dominantColor];
            BOOL dark = VibeImageLowerBandIsDark(square, kTransportBandFraction);
            run_on_main_thread({ complete(square, color, dark); });
        }
    });
}

- (void)completeRenderRequest:(ArtworkRenderRequest *)request
                        result:(ArtworkDisplayResult *)result {
    // Even a stale color is right for its source image.
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
        _showingDefaultArt = NO;
        _dominantArtColor = result.dominantColor;
        _displayedArt = request.sourceArt;
        _displayedArtTrack = request.track;
        _displayedArtMetadata = request.metadata;
        [self publishImage:result.squareImage lowerBandIsDark:result.lowerBandIsDark];
    }

    _renderInFlight = NO;
    ArtworkRenderRequest *nextRequest = _queuedRenderRequest;
    _queuedRenderRequest = nil;
    if (nextRequest) {
        [self startRenderRequest:nextRequest];
    }
}

- (void)updateForTrack:(AudioTrack *)track {
    // One snapshot: the same track can gain new metadata, and one metadata a
    // new cached source after an async load.
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
    // The drag-out payload follows the displayed track, not the keep-previous
    // art: a drag in the unresolved gap exports the track the header names.
    _artworkView.fileURL = track.url;
    _artworkView.trackDisplayName = track.singleLineTitle;
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
            // A shared folder cover: the installed crop is exact, so only its
            // owner transfers.
            _displayedArtTrack = track;
            _displayedArtMetadata = metadata;
            _showingDefaultArt = NO;
        }
        else if (_pendingArt != art) {
            // The header and the Dock frame art square, so the worker crops
            // once. Identity marks stay on the source: the crop is a fresh
            // object every time. Now Playing keeps the uncropped original.
            [self renderArt:art forTrack:track metadata:metadata];
        }
        return;
    }

    // A dead controller answers "not wanted", demoting the decode: a track
    // that never played never becomes _artOwnerTrack, so nothing else would
    // drop the 4-9MB this load pins.
    __weak ArtworkDisplayController *weakSelf = self;
    [metadata loadArtIfNeededStillWanted:^BOOL{
        ArtworkDisplayController *strongSelf = weakSelf;
        AudioTrack *currentTrack = strongSelf.currentTrackProvider
                ? strongSelf.currentTrackProvider() : nil;
        return currentTrack == track && track.metadata == metadata;
    } completion:^(NSImage *loaded) {
        ArtworkDisplayController *strongSelf = weakSelf;
        // The same rule as above, so a load and a refresh cannot disagree.
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
                // Another worker holds the folder's claim; the next pass
                // retries.
                break;
        }
    }];
}

// Keep-previous would hold the old art for as long as a slow open runs, so
// show the default, unless the pending track's own art already landed.
- (void)showPlaceholderForSlowLoad {
    AudioTrack *track = self.currentTrackProvider ? self.currentTrackProvider() : nil;
    AudioTrackMetadata *metadata = track.metadata;
    NSImage *art = metadata.cachedArt;
    if (art && _displayedArt == art && _displayedArtTrack == track &&
            _displayedArtMetadata == metadata) {
        return;
    }
    // This track's crop in flight still replaces the placeholder; any other
    // render belongs to the departed track.
    BOOL currentCropPending = art && _pendingArt == art &&
            _artworkTargetTrack == track && _artworkTargetMetadata == metadata &&
            _artworkTargetArt == art;
    [self showDefaultArtworkInvalidatingRender:!currentCropPending];
}

// Invalidates any pending render, even when the visuals are already right.
- (void)showDefaultArtwork {
    [self showDefaultArtworkInvalidatingRender:YES];
}

- (void)refreshDefaultArtwork {
    // Pointer-identical when unchanged: TrackDisplay fires on every toggle,
    // and a re-install would reset the Dock tile and washes for nothing.
    if (_showingDefaultArt && _artworkView.image !=
            AppSettings.sharedInstance.currentTheme.resolvedDefaultArtworkImage) {
        _showingDefaultArt = NO;
        [self showDefaultArtworkInvalidatingRender:NO];
    }
}

// Runs at every install and default, and from the AppIcon effect.
- (void)applyDockIcon {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL wantsArt = [theme.dockIcon isEqualToString:SETTINGS_VALUE_DOCK_ICON_ALBUM_ART];
    if (wantsArt && _initialized && !_showingDefaultArt && _artworkView.image) {
        [NSDockTile setDockIcon:_artworkView.image shaped:theme.appIconShape];
    } else {
        [NSDockTile resetToAppIcon];
    }
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
    _showingDefaultArt = YES;
    _dominantArtColor = nil;
    _displayedArt = nil;
    _displayedArtTrack = nil;
    _displayedArtMetadata = nil;
    [self publishImage:nil lowerBandIsDark:YES];
}

// The injected sink never creates a view or touches the Dock.
- (void)publishImage:(NSImage *)image lowerBandIsDark:(BOOL)dark {
    if (!_publication) {
        _artworkView.image = _showingDefaultArt
                ? AppSettings.sharedInstance.currentTheme.resolvedDefaultArtworkImage : image;
    }
    if (self.dominantColorDidChangeHandler) self.dominantColorDidChangeHandler();
    if (_publication) {
        _publication(image, _dominantArtColor, _showingDefaultArt, dark);
    } else {
        [self refreshTintWashes]; // also samples default art's transport contrast
        [self applyDockIcon];
    }
    if (_publication || !_showingDefaultArt) [self publishTransportBackdropDark:dark];
}

- (void)publishTransportBackdropDark:(BOOL)dark {
    if (self.transportBackdropDidChangeHandler) {
        self.transportBackdropDidChangeHandler(dark, !_showingDefaultArt);
    }
}

- (void)trackDidStartPlaying:(AudioTrack *)track {
    // Or every played track pins its 4-9MB of art for the playlist's lifetime.
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
