//
//  VolumeControlView.m
//  Vibe
//

#import "VolumeControlView.h"
#import "MainPlayerController+Transport.h" // volumeChanged:
#import "DrawnControls.h"
#import "NSTextField+Label.h"
#import "WaveformTheme.h"
#import "WaveformTheme+Settings.h"
#import "Fonts+Theme.h"
#import "Formatters.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "VibeStrings.h"

// The slider, and the gap either side of it; the side columns are measured
// (layoutColumns).
static const CGFloat kVolumeSliderWidth = 100;
static const CGFloat kVolumeGap = 6;

// The corner readouts' kerning, in the artist's color.
static NSDictionary *VolumeTextAttributes(NSTextAlignment alignment, NSColor *color) {
    NSMutableDictionary *attributes = [[Fonts infoTextAttributesAligned:alignment] mutableCopy];
    attributes[NSForegroundColorAttributeName] = color;
    return attributes;
}

// A column's width for a string as the label's own cell lays it out, which
// the bare string's size is not: the readouts' negative kern leaves that
// short, and a centered cell drops a last glyph it cannot fit.
static CGFloat LabelCellWidth(NSTextField *label, NSString *string, NSTextAlignment alignment) {
    NSTextFieldCell *cell = [label.cell copy];
    cell.attributedStringValue = [[NSAttributedString alloc] initWithString:string
            attributes:[Fonts infoTextAttributesAligned:alignment]];
    return ceil(cell.cellSize.width);
}

@implementation VolumeControlView {
    NSDictionary *_percentAttributes; // rebuilt with the theme's colors
}

+ (BOOL)atTopRight {
    AppSettings *settings = AppSettings.sharedInstance;
    return settings.volumeControl && [settings.volumeLocation isEqualToString:SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT];
}

- (instancetype)initWithFrame:(NSRect)frame target:(id)target {
    self = [super initWithFrame:frame];
    if (self) {
        _label = [NSTextField labelWithFrame:NSZeroRect];
        [self addSubview:_label];

        _percentLabel = [NSTextField labelWithFrame:NSZeroRect];
        [self addSubview:_percentLabel];

        _slider = [[VibeSlider alloc] initWithFrame:NSZeroRect];
        _slider.doubleValue = AppSettings.sharedInstance.volume;
        _slider.accessibilityLabel = STR_A11Y_VOLUME;
        _slider.accessibilityValueFormatter = ^NSString *(double value) {
            return [Formatters.sharedInstance percentString:value];
        };
        _slider.target = target;
        _slider.action = @selector(volumeChanged:);
        [self addSubview:_slider];
    }
    return self;
}

- (void)applyThemedLabelFonts {
    _label.font = [Fonts infoFontBold:NO];
    _percentLabel.font = [Fonts infoFontBold:NO];
}

- (void)applyThemedLabelColors {
    _label.attributedStringValue = [[NSAttributedString alloc] initWithString:STR_LABEL_VOLUME
            attributes:VolumeTextAttributes(NSTextAlignmentRight,
                    AppSettings.sharedInstance.currentTheme.resolvedArtistColor)];
    [self applyPercentStyle];
}

// Both side columns are the wider of "Vol" and "100%" in the current face, so
// neither clips and the slider sits at the control's center.
- (void)layoutColumns {
    BOOL labels = AppSettings.sharedInstance.showVolumeLabels;
    CGFloat side = 0, gap = 0;
    [self applyPercentStyle];
    if (labels) {
        NSString *full = [[Formatters sharedInstance] percentString:1.0];
        side = MAX(LabelCellWidth(_label, STR_LABEL_VOLUME, NSTextAlignmentRight),
                   LabelCellWidth(_percentLabel, full, self.percentAlignment));
        gap = kVolumeGap;
    }
    CGFloat width = 2 * side + 2 * gap + kVolumeSliderWidth;
    NSRect frame = self.frame;
    frame.size.width = width;
    self.frame = frame;
    CGFloat height = NSHeight(frame);
    _label.hidden = !labels;
    _percentLabel.hidden = !labels;
    _label.frame = NSMakeRect(0, 0, side, height);
    _slider.frame = NSMakeRect(side + gap, 0, kVolumeSliderWidth, height);
    _percentLabel.frame = NSMakeRect(width - side, 0, side, height);
}

// In the time row the percentage hugs the slider; in the corner it is
// right-aligned on the total time's edge, like the time, so the two stack.
- (NSTextAlignment)percentAlignment {
    return VolumeControlView.atTopRight ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

- (void)applyPercentStyle {
    _percentAttributes = VolumeTextAttributes(self.percentAlignment,
            AppSettings.sharedInstance.currentTheme.resolvedArtistColor);
    [self renderPercent];
}

- (void)renderPercent {
    NSString *percent = [[Formatters sharedInstance] percentString:AppSettings.sharedInstance.volume];
    _percentLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:percent
                                                                          attributes:_percentAttributes];
}

// None (nil) is the system slider's. Waveform is the played color the
// waveform draws; Artwork is the album_art clamp of the art color, Mono's
// played color for no art or too gray a one; Custom is used exactly as picked.
static NSColor *VolumeColorForChoice(NSString *choice, NSString *base, AppTheme *theme,
                                     BOOL dark, NSColor *art) {
    if ([choice isEqualToString:SETTINGS_VALUE_VOLUME_WAVEFORM]) {
        return [[WaveformTheme themeForAppTheme:theme isDark:dark artworkColor:art].playedColor
                colorWithAlphaComponent:1.0];
    }
    if ([choice isEqualToString:SETTINGS_VALUE_WINDOW_TINT_ARTWORK]) {
        return [WaveformTheme legibleArtworkColor:art isDark:dark]
                ?: [[WaveformTheme monochromeThemeIsDark:dark].playedColor colorWithAlphaComponent:1.0];
    }
    if ([choice isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return [theme displayColorForBase:base dark:dark];
    }
    return nil;
}

// None's knob is the system's white pill. Same as bar, the knob's default, is
// the color the bar draws: under None that is the system accent, not the nil
// that means a white knob.
- (void)applyColorsDark:(BOOL)dark artworkColor:(NSColor *)artworkColor {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSColor *fill = VolumeColorForChoice(theme.volumeBar, kVibeThemeColorVolumeBar, theme, dark, artworkColor);
    _slider.trackFillColor = fill;
    _slider.knobColor = [theme.volumeKnob isEqualToString:SETTINGS_VALUE_VOLUME_KNOB_BAR]
            ? (fill ?: NSColor.controlAccentColor)
            : VolumeColorForChoice(theme.volumeKnob, kVibeThemeColorVolumeKnob, theme, dark, artworkColor);
}

@end
