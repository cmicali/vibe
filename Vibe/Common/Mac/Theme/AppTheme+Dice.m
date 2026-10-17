//
//  AppTheme+Dice.m
//  Vibe
//

#import "AppThemeInternal.h"
#import <AppKit/AppKit.h>
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "SettingsRules.h"

@implementation AppTheme (Dice)

static NSString *const kRandomMonoFontFace = @"Menlo-Regular";

static NSUInteger RandomIndex(NSUInteger count) {
    return arc4random_uniform((uint32_t)count);
}

static BOOL RandomChance(uint32_t percent) {
    return arc4random_uniform(100) < percent;
}

static id RandomPick(NSArray *choices) {
    return choices[RandomIndex(choices.count)];
}

+ (NSArray<NSString *> *)randomizableFontFaces {
    return @[@"Georgia", @"Baskerville", @"Palatino-Roman",
             @"HelveticaNeue-Medium", @"AvenirNext-Medium", @"Futura-Medium",
             kRandomMonoFontFace];
}

- (void)randomizeSettingsWithWaveformStyles:(NSArray<NSString *> *)styles {
    NSArray *backgrounds = @[SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS, SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID,
                             SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR];
    NSArray *tints = @[SETTINGS_VALUE_WINDOW_TINT_MONO, SETTINGS_VALUE_WINDOW_TINT_ARTWORK];
    self.windowBackgroundStyle = RandomPick([backgrounds arrayByAddingObject:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED]);
    self.windowTint = RandomPick(tints);
    // Radius first: the switch's off is kept only beside a stored radius.
    self.windowCornerRadius = [RandomPick(@[@0, @8, @12, @16, @20, @28, @36]) doubleValue];
    self.customCornerRadius = RandomChance(50);
    if (styles.count) {
        self.waveformStyle = RandomPick(styles);
    }
    self.waveformTheme = RandomPick(@[SETTINGS_VALUE_WAVEFORM_THEME_MONO, SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
                                      SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART]);
    self.waveformShadeOverlaps = RandomChance(50);
    self.waveformSpectrumPalette = RandomPick(@[SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB,
                                                SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_BLUE,
                                                SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_GREEN]);
    self.waveformSpectrumColoring = RandomPick(VibeWaveformSpectrumColorings());
    self.waveformGradient = RandomChance(50);
    self.waveformCentered = RandomChance(75);
    self.buttonGradient = RandomPick(VibeButtonGradientModes());
    self.playlistButtonGlyph = RandomPick(VibePlaylistButtonGlyphs());
    NSArray<NSString *> *pair = RandomPick(VibePlayPauseGlyphPairs());
    self.playButtonGlyph = pair[0];
    self.pauseButtonGlyph = pair[1];
    self.nextButtonGlyph = RandomPick(VibeNextButtonGlyphs());
    self.playlistBackgroundStyle = RandomPick(backgrounds);
    self.playlistTint = RandomPick(tints);
    self.volumeBar = RandomPick([tints arrayByAddingObject:SETTINGS_VALUE_VOLUME_WAVEFORM]);
    self.volumeKnob = RandomPick([tints arrayByAddingObjectsFromArray:
            @[SETTINGS_VALUE_VOLUME_WAVEFORM, SETTINGS_VALUE_VOLUME_KNOB_BAR]]);
    NSString *face = RandomPick(AppTheme.randomizableFontFaces);
    NSString *numbers = RandomChance(50) ? kRandomMonoFontFace : face;
    [self setFontFace:face size:kVibeThemeTitleFontBaseSize forSlot:VibeFontSlotTitle];
    [self setFontFace:face size:kVibeThemeArtistFontBaseSize forSlot:VibeFontSlotArtist];
    [self setFontFace:face size:kVibeThemePlaylistFontBaseSize forSlot:VibeFontSlotPlaylist];
    [self setFontFace:numbers size:kVibeThemeInfoFontBaseSize forSlot:VibeFontSlotInfo];
    [self setFontFace:numbers size:kVibeThemePlaylistDurationFontBaseSize forSlot:VibeFontSlotPlaylistDuration];
}

// A pastel for dark, a deeper shade for light. The hue wraps, so a
// complement is plain addition.
static NSColor *HueColor(CGFloat hue, BOOL dark, CGFloat alpha) {
    hue = fmod(hue + 1, 1);
    return dark ? [NSColor colorWithHue:hue saturation:0.55 brightness:0.95 alpha:alpha]
                : [NSColor colorWithHue:hue saturation:0.75 brightness:0.55 alpha:alpha];
}

- (void)setHue:(CGFloat)hue alpha:(CGFloat)alpha forBase:(NSString *)base {
    [self setHue:hue darkAlpha:alpha lightAlpha:alpha forBase:base];
}

// Under single mode both sides share the dark slot, and the light write would
// overwrite the pastel the pinned-dark window draws.
- (void)setHue:(CGFloat)hue darkAlpha:(CGFloat)darkAlpha lightAlpha:(CGFloat)lightAlpha
       forBase:(NSString *)base {
    [self setColor:HueColor(hue, YES, darkAlpha) forBase:base dark:YES];
    if (![[self colorKeyForBase:base dark:NO] isEqualToString:[self colorKeyForBase:base dark:YES]]) {
        [self setColor:HueColor(hue, NO, lightAlpha) forBase:base dark:NO];
    }
}

- (void)randomizeColors {
    for (NSDictionary *spec in VibeThemeFieldSpecs()) {
        if (spec[kSpecColorBase]) {
            [_fields removeObjectForKey:spec[kSpecKey]];
        }
    }
    for (NSString *base in VibeThemePlaylistColorFallbackBases()) {
        [self setPlaylistColorEnabled:NO forBase:base];
    }
    if ([self.waveformTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    }
    // Custom draws the band wells cleared above.
    if ([self.waveformSpectrumPalette isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM]) {
        self.waveformSpectrumPalette = SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB;
    }
    if ([self.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.windowTint = SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
    }
    if ([self.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_CUSTOM]) {
        self.defaultArtwork = SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK;
    }
    if ([self.playlistTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.playlistTint = SETTINGS_VALUE_WINDOW_TINT_MONO;
    }
    if ([self.volumeBar isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.volumeBar = SETTINGS_VALUE_VOLUME_WAVEFORM;
    }
    if ([self.volumeKnob isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        self.volumeKnob = SETTINGS_VALUE_VOLUME_KNOB_BAR;
    }

    CGFloat hue = RandomIndex(360) / 360.0;
    switch (RandomIndex(5)) {
        case 0: // The header labels in the hue, the artist line lighter.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorArtist];
            break;
        case 1: // The same, carried into the playlist's rows and fills.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorArtist];
            [self setHue:hue alpha:0.95 forBase:kVibeThemeColorPlaylistTitle];
            [self setHue:hue alpha:0.6 forBase:kVibeThemeColorPlaylistArtist];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistArtist];
            [self setHue:hue alpha:0.18 forBase:kVibeThemeColorPlaylistPlayingRow];
            [self setHue:hue alpha:0.12 forBase:kVibeThemeColorPlaylistSelectedRow];
            break;
        case 2: // A complementary pair: titles in the hue, artists opposite it.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue + 0.5 alpha:0.75 forBase:kVibeThemeColorArtist];
            [self setHue:hue alpha:0.95 forBase:kVibeThemeColorPlaylistTitle];
            [self setHue:hue + 0.5 alpha:0.65 forBase:kVibeThemeColorPlaylistArtist];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistTitle];
            [self setPlaylistColorEnabled:YES forBase:kVibeThemeColorPlaylistArtist];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.85 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue + 0.5 alpha:0.35 forBase:kVibeThemeColorWaveformUnplayed];
            break;
        case 3: // An analogous pair, reaching the info card and the buttons.
            [self setHue:hue alpha:1 forBase:kVibeThemeColorTitle];
            [self setHue:hue + 0.08 alpha:0.7 forBase:kVibeThemeColorArtist];
            [self setHue:hue + 0.08 alpha:0.55 forBase:kVibeThemeColorInfo];
            [self setHue:hue alpha:0.65 forBase:kVibeThemeColorTime];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorPlaylistButton];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorPlayButton];
            [self setHue:hue alpha:0.7 forBase:kVibeThemeColorNextButton];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.8 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue + 0.08 alpha:0.3 forBase:kVibeThemeColorWaveformUnplayed];
            break;
        default: // A wash of the hue over the window and the playlist, labels left plain.
            self.windowTint = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
            [self setHue:hue darkAlpha:0.35 lightAlpha:0.45 forBase:kVibeThemeColorWindowTint];
            self.playlistTint = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
            [self setHue:hue darkAlpha:0.25 lightAlpha:0.35 forBase:kVibeThemeColorPlaylistTint];
            [self setHue:hue alpha:0.2 forBase:kVibeThemeColorPlaylistPlayingRow];
            self.waveformTheme = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
            [self setHue:hue alpha:0.8 forBase:kVibeThemeColorWaveformPlayed];
            [self setHue:hue alpha:0.3 forBase:kVibeThemeColorWaveformUnplayed];
            break;
    }
}

@end
