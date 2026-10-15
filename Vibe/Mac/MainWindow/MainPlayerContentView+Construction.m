//
//  MainPlayerContentView+Construction.m
//  Vibe
//

#import "MainPlayerContentViewInternal.h"
#import "MainPlayerController+Window.h" // declares the button action selectors
#import "SymbolButton.h"
#import "ArtworkImageView.h"
#import "WaveformView.h"
#import "PlaylistTableView.h"
#import "PlaylistDropZoneView.h"
#import "VolumeControlView.h"
#import "NSTextField+Label.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "VibeStrings.h"

@implementation VibePassthroughView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// Clicks on the empty header fall through to the window's background drag.
API_AVAILABLE(macos(26.0))
@interface VibePassthroughGlassView : NSGlassEffectView
@end

@implementation VibePassthroughGlassView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

@interface VibePassthroughFrostView : NSVisualEffectView
@end

@implementation VibePassthroughFrostView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// updateMaterialForAppearance sets the opacity. A field that changes every
// second opts out of rasterization.
static void configureLabelShadow(NSTextField *field, BOOL rasterize) {
    field.wantsLayer = YES;
    field.layer.shadowColor = NSColor.blackColor.CGColor;
    field.layer.shadowRadius = 0.25;
    field.layer.shadowOffset = CGSizeMake(0, -1);
    field.layer.masksToBounds = NO;
    field.layer.shouldRasterize = rasterize;
    if (rasterize) {
        field.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    }
}

@implementation MainPlayerContentView (Construction)

// The call order below IS the z-order.

- (void)buildSubviewsWithTarget:(id)target {
    [self buildHeaderBackdrop];
    [self buildAlbumArt];
    [self buildTransportControlsWithTarget:target];
    [self buildHeaderLabels];
    [self buildPlaylistPane];
    [self buildCornerReadouts];
    // Above the corner readouts, which keep catching clicks at zero alpha.
    [self buildVolumeControlWithTarget:target];
    [self applyThemedLabelFonts];
    [self applyThemedLabelColors];
    [self applyThemedTransportButtons];
    [self applyWindowBackgroundStyle];
}

// Hidden under clear rather than restyled Clear: a second Clear pane over the
// backdrop compounds into a visibly lighter band. Under solid the cover is the
// whole background; frosted is the same cover with this panel kept over it.
// The panel and its tint stop at the art's left edge, so a transparent
// placeholder shows only the window's backdrop, except under the window and
// glyph default artwork, which carry them under the square.
- (void)applyWindowBackgroundStyle {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSString *style = theme.windowBackgroundStyle;
    _backgroundGlassView.hidden = [style isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR] ||
            [style isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL panelUnderArt = [theme.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_WINDOW]
            || [theme.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_GLYPH];
    CGFloat panelX = panelUnderArt ? 0 : kArtSize;
    for (NSView *panel in @[_backgroundGlassView, _headerTintView]) {
        NSRect frame = panel.frame;
        if (frame.origin.x != panelX) {
            frame.size.width += frame.origin.x - panelX;
            frame.origin.x = panelX;
            panel.frame = frame;
        }
    }
    [self applyPlaylistBackground];
}

- (void)buildHeaderBackdrop {
    NSRect headerPanelFrame = NSMakeRect(kArtSize, kPlaylistHeight, kHeaderPanelWidth, kHeaderHeight);
    if (@available(macOS 26.0, *)) {
        _backgroundGlassView = [[VibePassthroughGlassView alloc] initWithFrame:headerPanelFrame];
    }
    else {
        VibePassthroughFrostView *frost = [[VibePassthroughFrostView alloc] initWithFrame:headerPanelFrame];
        frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        frost.state = NSVisualEffectStateActive; // never dims, like the playlist frost
        frost.material = NSVisualEffectMaterialUnderWindowBackground;
        _backgroundGlassView = frost;
    }
    [MainPlayerContentView applyCornerRadius:0 toBackdrop:_backgroundGlassView];
    // Fixed height: see the playlist frost's trap.
    _backgroundGlassView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_backgroundGlassView];

    // Not the glass's tintColor, which AppKit drops while the window is
    // inactive.
    _headerTintView = [[VibePassthroughView alloc] initWithFrame:_backgroundGlassView.frame];
    _headerTintView.wantsLayer = YES;
    _headerTintView.autoresizingMask = _backgroundGlassView.autoresizingMask;
    [self addSubview:_headerTintView];

    _waveformView = [[WaveformView alloc] initWithFrame:
            NSMakeRect(kHeaderContentX, kWaveformY, kHeaderContentWidth, kWaveformHeight)];
    _waveformView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_waveformView];
}

- (void)buildAlbumArt {
    _albumArtImageView = [[ArtworkImageView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    _albumArtImageView.image = AppSettings.sharedInstance.currentTheme.resolvedDefaultArtworkImage;
    _albumArtImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _albumArtImageView.refusesFirstResponder = YES;
    _albumArtImageView.focusRingType = NSFocusRingTypeNone;
    _albumArtImageView.wantsLayer = YES;
    _albumArtImageView.layer.shadowRadius = 6;
    _albumArtImageView.layer.shadowOpacity = 0.25;
    _albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    _albumArtImageView.layer.masksToBounds = NO;
    _albumArtImageView.layer.shouldRasterize = true;
    _albumArtImageView.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    _albumArtImageView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtImageView];

    // Darkens the art behind the transport row; visibility follows the
    // theme's buttonGradient (setControlsShown:animated:).
    _albumArtGradientView = [[VibePassthroughView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.82].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.47].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    artGradient.locations = @[@0.0, @0.35, @0.62];
    // Layer-hosting: the layer before wantsLayer, or the view ends up
    // layer-backed.
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.identifier = @"buttonGradient";
    _albumArtGradientView.wantsLayer = YES;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];
}

// All five start at zero alpha; see setControlsShown:animated:.
- (void)buildTransportControlsWithTarget:(id)target {
    _closeButton = [MainPlayerContentView transportButtonWithFrame:
                            NSMakeRect(kCloseButtonX, kTrafficLightY, kTrafficLightSize, kTrafficLightSize)
                                                        symbolName:@"circle.fill"
                                                             label:STR_A11Y_WINDOW_CLOSE
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.0;
    _closeButton.symbolPointSize = kTrafficLightSymbolSize;
    _closeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.64];
    _closeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:1.0];
    [self addSubview:_closeButton];

    _minimizeButton = [MainPlayerContentView transportButtonWithFrame:
                               NSMakeRect(kCloseButtonX + kTrafficLightSpacing, kTrafficLightY,
                                          kTrafficLightSize, kTrafficLightSize)
                                                           symbolName:@"circle.fill"
                                                                label:STR_WINDOW_MINIMIZE
                                                               action:@selector(performMiniaturize:)
                                                               target:nil]; // the window's, up the chain
    _minimizeButton.alphaValue = 0.0;
    _minimizeButton.symbolPointSize = kTrafficLightSymbolSize; // same dot as close
    _minimizeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:0.64];
    _minimizeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:1.0];
    [self addSubview:_minimizeButton];

    _playlistToggleButton = [MainPlayerContentView transportButtonWithFrame:
                                     NSMakeRect(kTransportRowX, kTransportButtonY,
                                                kTransportButtonSize, kTransportButtonSize)
                                                                 symbolName:@"list.bullet"
                                                                      label:STR_A11Y_TOGGLE_PLAYLIST
                                                                     action:@selector(toggleSize:)
                                                                     target:target];
    _playlistToggleButton.alphaValue = 0.0;
    [self addSubview:_playlistToggleButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"play.fill"
                                                            label:STR_TRANSPORT_PLAY
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.alphaValue = 0.0;
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + 2 * kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"forward.end.fill"
                                                            label:STR_TRANSPORT_NEXT
                                                           action:@selector(next:)
                                                           target:target];
    _nextButton.alphaValue = 0.0;
    _nextButton.enabled = NO;
    [self addSubview:_nextButton];
}

- (void)buildHeaderLabels {
    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [NSTextField labelWithFrame:
            NSMakeRect(kHeaderTextX, kArtistY, kArtistWidth, kArtistHeight)];
    // Truncating, not the clipping default: long artist tags are common, and
    // clipping cuts a glyph mid-stroke with no sign the string goes on.
    _artistTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_artistTextField, YES);
    [self addSubview:_artistTextField];

    _titleTextField = [NSTextField labelWithFrame:
            NSMakeRect(kHeaderTextX, kTitleY, kTitleWidth, kTitleHeight)];
    _titleTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_titleTextField, YES);
    [self addSubview:_titleTextField];

    _totalTimeTextField = [NSTextField labelWithFrame:
            NSMakeRect(kTotalTimeX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_totalTimeTextField, YES);
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [NSTextField labelWithFrame:
            NSMakeRect(kHeaderTextX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];

    // Left-anchored, unlike the right-aligned total time it pairs with.
    _currentTimeTextField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    // Not rasterized: it changes every second.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    _dropHintTextField = [NSTextField labelWithFrame:
            NSMakeRect(kDropHintX, kTimeRowY, kDropHintWidth, kSmallLabelHeight)];
    _dropHintTextField.font = [Fonts font:13];
    _dropHintTextField.alignment = NSTextAlignmentCenter;
    _dropHintTextField.textColor = dimmedTextColor;
    // Long translations ellipsize.
    _dropHintTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _dropHintTextField.maximumNumberOfLines = 1;
    _dropHintTextField.alphaValue = kDropHintAlpha;
    _dropHintTextField.hidden = YES;
    _dropHintTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_dropHintTextField, YES);
    [self addSubview:_dropHintTextField];
}

// It starts at zero alpha, like the transport (setControlsShown:animated:).
// Sized by its own layoutColumns and placed by positionVolumeControl, never
// the mask.
- (void)buildVolumeControlWithTarget:(id)target {
    _volumeControlView = [[VolumeControlView alloc] initWithFrame:NSMakeRect(0, 0, 0, kSmallLabelHeight)
                                                           target:target];
    _volumeControlView.alphaValue = 0.0;
    configureLabelShadow(_volumeControlView.label, YES);
    // Not rasterized: it changes under a drag.
    configureLabelShadow(_volumeControlView.percentLabel, NO);
    [self addSubview:_volumeControlView];
}

// Bottom to top: the frost, the background layer, the tint wash, the table,
// and the drop zone.
- (void)buildPlaylistPane {
    // Row text is unreadable over the window's Clear glass, so the playlist
    // gets its own frost. TRAP: an NSVisualEffectView, not an
    // NSGlassEffectView: a glass view stretched from design height to window
    // height fights the autoresizing (its SwiftUI hosting), and the window
    // silently refuses to grow past the design height. Under the scroll view,
    // since an NSClipView background does not composite translucent colors.
    _playlistFrostView = [[NSVisualEffectView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistFrostView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _playlistFrostView.state = NSVisualEffectStateActive;
    _playlistFrostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistFrostView];

    // A sibling, never the frost's child: the solid style hides the frost and
    // keeps this as the whole background.
    _playlistDimView = [[NSView alloc] initWithFrame:_playlistFrostView.frame];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDimView];

    // The playlist's headerTintView.
    _playlistTintView = [[NSView alloc] initWithFrame:_playlistFrostView.frame];
    _playlistTintView.wantsLayer = YES;
    _playlistTintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistTintView];

    NSScrollView *playlistScrollView = [PlaylistTableView scrollViewWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistTableView = (PlaylistTableView *)playlistScrollView.documentView;
    [self addSubview:playlistScrollView];

    // Hit-transparent while neither presentation is up.
    _playlistDropZoneView = [[PlaylistDropZoneView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistDropZoneView.hidden = YES;
    _playlistDropZoneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDropZoneView];
}

// One visual pair: a font, an alignment and a dimming rule.
- (void)buildCornerReadouts {
    _fileMetadataTextField = [NSTextField labelWithFrame:
            NSMakeRect(kCodecLabelX, kCodecLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    // Full alpha: a field alpha would dim the inline FX symbols too, so the
    // text dims in its color (cornerTextAttributes).
    _fileMetadataTextField.alphaValue = 1.0;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    // Framed by layoutCodecSpinner, once the fonts are applied.
    _codecSpinner = [[NSProgressIndicator alloc] init];
    _codecSpinner.style = NSProgressIndicatorStyleSpinning;
    _codecSpinner.controlSize = NSControlSizeSmall;
    _codecSpinner.displayedWhenStopped = NO;
    _codecSpinner.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:_codecSpinner];

    _bpmTextField = [NSTextField labelWithFrame:
            NSMakeRect(kCodecLabelX, kBPMLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _bpmTextField.alignment = NSTextAlignmentRight;
    _bpmTextField.alphaValue = 1.0;
    _bpmTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_bpmTextField, YES);
    [self addSubview:_bpmTextField];
}

+ (SymbolButton *)transportButtonWithFrame:(NSRect)frame
                                symbolName:(NSString *)symbolName
                                     label:(NSString *)label
                                    action:(SEL)action
                                    target:(id)target {
    SymbolButton *button = [[SymbolButton alloc] initWithFrame:frame];
    button.symbolName = symbolName;
    button.symbolPointSize = kTransportSymbolSize;
    button.accessibilityLabel = label;
    button.target = target;
    button.action = action;
    button.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    return button;
}

- (void)applyThemedLabelFonts {
    _artistTextField.font = [Fonts artistFont];
    _titleTextField.font = [Fonts titleFont];
    _totalTimeTextField.font = [Fonts infoFontBold:YES];
    _currentTimeTextField.font = [Fonts infoFontBold:YES];
    _fileMetadataTextField.font = [Fonts infoFontBold:NO];
    _bpmTextField.font = [Fonts infoFontBold:NO];
    [_volumeControlView applyThemedLabelFonts];
    [self layoutVolumeControl];
    // A font change moves the codec line's measure and baseline too.
    [self layoutCodecSpinner];
    [self layoutArtistLineClearOfCodecLine];
}

- (void)applyThemedLabelColors {
    // The corner readouts' color rides their attributed strings; the drop hint
    // stays unthemed.
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    _titleTextField.textColor = theme.resolvedTitleColor;
    _artistTextField.textColor = theme.resolvedArtistColor;
    _totalTimeTextField.textColor = theme.resolvedTimeColor;
    _currentTimeTextField.textColor = theme.resolvedTimeColor;
    [_volumeControlView applyThemedLabelColors];
}

// A glyph this macOS has, else the factory one, as Fonts falls back from an
// uninstalled face: a button drawing nothing is never the answer.
static NSString *ResolvedGlyph(NSString *glyph, NSString *factory) {
    // Fixed within a run, and the probe allocates an image.
    static NSMutableDictionary<NSString *, NSNumber *> *known;
    if (!known) {
        known = [NSMutableDictionary dictionary];
    }
    NSNumber *has = known[glyph];
    if (has == nil) {
        has = @([NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil] != nil);
        known[glyph] = has;
    }
    return has.boolValue ? glyph : factory;
}

static void ApplyThemeToButton(SymbolButton *button, AppTheme *theme, NSString *imageKey,
                               NSString *glyph, NSString *factoryGlyph,
                               NSString *colorBase, BOOL dark) {
    button.image = [theme buttonImageForKey:imageKey];
    button.symbolName = ResolvedGlyph(glyph, factoryGlyph);
    [button setSymbolColorsFromRestingColor:[theme displayColorForBase:colorBase dark:dark]];
}

- (BOOL)transportGradientEnabled {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    return theme.showTransportButtons
            && ![theme.buttonGradient isEqualToString:SETTINGS_VALUE_BUTTON_GRADIENT_NONE]
            && (![theme.buttonGradient isEqualToString:SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK] || _transportHasArtwork);
}

// An enabled gradient is under every visible button, so it reads dark;
// otherwise the image's lower band decides.
- (BOOL)transportBackdropIsDark {
    return self.transportGradientEnabled || _transportBackdropDark;
}

- (void)applyThemedTransportButtons {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL dark = self.transportBackdropIsDark;
    ApplyThemeToButton(_playlistToggleButton, theme,
                       dark ? kVibeThemeImagePlaylistButtonDark : kVibeThemeImagePlaylistButtonLight,
                       theme.playlistButtonGlyph, kVibeThemePlaylistButtonGlyphDefault,
                       kVibeThemeColorPlaylistButton, dark);
    ApplyThemeToButton(_nextButton, theme,
                       dark ? kVibeThemeImageNextButtonDark : kVibeThemeImageNextButtonLight,
                       theme.nextButtonGlyph, kVibeThemeNextButtonGlyphDefault,
                       kVibeThemeColorNextButton, dark);
    [self dressPlayButton];
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (void)setTransportBackdropDark:(BOOL)dark hasArtwork:(BOOL)hasArtwork {
    if (_transportBackdropDark == dark && _transportHasArtwork == hasArtwork) {
        return;
    }
    _transportBackdropDark = dark;
    _transportHasArtwork = hasArtwork;
    [self applyThemedTransportButtons];
}

// Each image slot falls back to its own glyph, so a theme with only a play
// image still shows a pause glyph while playing.
- (void)setPlayButtonShowsPause:(BOOL)showsPause {
    // updateUI asks on every transport event.
    if (showsPause == _playShowsPause) {
        return;
    }
    _playShowsPause = showsPause;
    [self dressPlayButton];
}

- (void)dressPlayButton {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL dark = self.transportBackdropIsDark, pause = _playShowsPause;
    NSString *imageKey = pause ? (dark ? kVibeThemeImagePauseButtonDark : kVibeThemeImagePauseButtonLight)
                               : (dark ? kVibeThemeImagePlayButtonDark : kVibeThemeImagePlayButtonLight);
    ApplyThemeToButton(_playButton, theme, imageKey,
                       pause ? theme.pauseButtonGlyph : theme.playButtonGlyph,
                       pause ? kVibeThemePauseButtonGlyphDefault : kVibeThemePlayButtonGlyphDefault,
                       kVibeThemeColorPlayButton, dark);
}

// The glass style's unthemed lift: clear in dark, a white wash in light that
// lifts row contrast while letting the blur through.
+ (NSColor *)defaultPlaylistBackgroundColorForDark:(BOOL)dark {
    return dark ? NSColor.clearColor : [NSColor colorWithWhite:1 alpha:0.35];
}

- (void)applyPlaylistBackground {
    BOOL dark = self.isDark;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL solid = [theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL clear = [theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR];
    // Solid: no blur, the theme's color. Glass: the unthemed lift (a themed
    // color over glass is the tint wash above). Clear: neither. The frost
    // blurs what is behind the WINDOW, so in a solid window it would punch
    // through the cover: there the glass is the window's own background. A
    // frosted window keeps it, as it keeps the header's panel.
    BOOL solidWindow = [theme.windowBackgroundStyle isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    _playlistFrostView.hidden = solid || clear || solidWindow;
    NSColor *background = solid
            ? [theme displayColorForBase:kVibeThemeColorPlaylistBackground dark:dark]
            : clear ? NSColor.clearColor
                    : [MainPlayerContentView defaultPlaylistBackgroundColorForDark:dark];
    _playlistDimView.layer.backgroundColor = background.CGColor;
}

+ (void)applyCornerRadius:(CGFloat)radius toBackdrop:(NSView *)backdrop {
    if (@available(macOS 26.0, *)) {
        if ([backdrop isKindOfClass:NSGlassEffectView.class]) {
            ((NSGlassEffectView *)backdrop).cornerRadius = radius;
            return;
        }
    }
    if ([backdrop isKindOfClass:NSVisualEffectView.class]) {
        ((NSVisualEffectView *)backdrop).maskImage =
                [MainPlayerContentView frostCornerMaskWithRadius:radius];
    }
}

// Cap-inset so the corners never scale. A layer cornerRadius clips an
// NSVisualEffectView's tint but not its blur.
+ (NSImage *)frostCornerMaskWithRadius:(CGFloat)radius {
    NSSize size = NSMakeSize(radius * 2 + 1, radius * 2 + 1);
    NSImage *mask = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor set];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    mask.resizingMode = NSImageResizingModeStretch;
    return mask;
}

@end
