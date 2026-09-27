//
//  TrackDisplayController.m
//  Vibe
//

#import "TrackDisplayController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainPlayerContentView.h"
#import "AudioWaveformView.h"
#import "AudioWaveformView+Loading.h" // the shimmer and empty-state pass-throughs
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "Fonts.h"
#import "MusicalKey.h"
#import "VibeStrings.h"
#import "NSView+DarkMode.h"

@implementation TrackDisplayController {
    __weak AudioWaveformView *_waveformView;
    __weak NSTextField      *_bpmTextField;
    __weak NSTextField      *_dropHintTextField;
    // The change guard for the elapsed label, in whole wall-clock seconds —
    // the formatter truncates, so that is when its text can change. A value
    // of -1 poisons it, so the next tick always writes, even from position 0.
    NSTimeInterval           _lastPosition;
    // The codec line's two independent inputs, kept so either re-renders
    // without the other, and as the change guard: every symbol attachment is
    // the same object-replacement character in stringValue.
    NSString                *_fileMetadataText;
    VibeFXDisplayState       _fxState;
    // Part of the BPM line's change guard (see renderBPM:). -1 is uncolored.
    NSInteger                _lastKeyColorKey;
    // The width the title's shrink-to-fit was computed against.
    CGFloat                  _titleFittedWidth;
    NSDictionary            *_cornerTextAttributes;
    // For the artist line's re-cap, which depends on the codec line's width.
    __weak MainPlayerContentView *_contentView;
}

- (instancetype)initWithContentView:(MainPlayerContentView *)contentView {
    self = [super init];
    if (self) {
        _artistTextField = contentView.artistTextField;
        _titleTextField = contentView.titleTextField;
        _totalTimeTextField = contentView.totalTimeTextField;
        _currentTimeTextField = contentView.currentTimeTextField;
        _fileMetadataTextField = contentView.fileMetadataTextField;
        _bpmTextField = contentView.bpmTextField;
        _dropHintTextField = contentView.dropHintTextField;
        _waveformView = contentView.waveformView;
        _contentView = contentView;
        _lastPosition = -1;
        _fileMetadataText = @"";
        _fxState = (VibeFXDisplayState){0};
        _lastKeyColorKey = -1;
    }
    return self;
}

// TRAP: setting NSTextField.stringValue to nil raises, and a message to a nil
// track returns nil — which the isEqualToString: early-out cannot catch, since
// a message to nil answers NO. Nil means empty here.
static void setStringValueIfChanged(NSTextField *field, NSString *value) {
    value = value ?: @"";
    if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
    }
}

// The codec corner's style, shared by the file-metadata and BPM labels.
static NSDictionary *kernedRightAlignedAttributes(void) {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    return @{
        NSKernAttributeName: @(-1.2),
        NSParagraphStyleAttributeName: paragraph,
    };
}

// Both corner labels dim in the text color, not the field alpha: the codec
// field also carries the FX symbols, which a field alpha would dim too. The
// color must stay dynamic, since these strings rebuild only on content change.
// Cached until resetRenderGuards; the fader recomposes the BPM line per tick.
- (NSDictionary *)cornerTextAttributes {
    if (!_cornerTextAttributes) {
        NSMutableDictionary *attributes = [kernedRightAlignedAttributes() mutableCopy];
        attributes[NSForegroundColorAttributeName] =
                AppSettings.sharedInstance.currentTheme.resolvedInfoColor;
        _cornerTextAttributes = attributes;
    }
    return _cornerTextAttributes;
}

// One hue per Camelot number, anchored so 1 is green, approximating the
// printed wheel: compatible keys land in neighboring hues and a relative
// major/minor pair shares one. Never full brightness, which reads as garish
// beside the dimmed corner text.
static const CGFloat kCamelotHueOfNumberOne = 1.0 / 3.0;

static NSColor *camelotColor(NSInteger key) {
    NSInteger number = VibeMusicalKeyCamelotNumber(key);
    if (number < 1 || number > 12) {
        return nil; // no key, or coloring switched off
    }
    static NSColor *palette[13];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSInteger i = 1; i <= 12; i++) {
            CGFloat hue = fmod(kCamelotHueOfNumberOne + (CGFloat)(i - 1) / 12.0, 1.0);
            palette[i] = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
                BOOL dark = appearance.isDark;
                return [NSColor colorWithHue:hue
                                  saturation:dark ? 0.62 : 0.90
                                  brightness:dark ? 0.82 : 0.60
                                       alpha:1.0];
            }];
        }
    });
    return palette[number];
}

// Menu order: Q, W, E, R, T. The boost modifies the low-kill filter, and runs
// it even with lowKill off, so it shows as the filled dial, never a symbol of
// its own.
static NSArray<NSString *> *fxSymbolNames(VibeFXDisplayState state) {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    if (state.lowKill || state.lowKillBoost) {
        [names addObject:(state.lowKillBoost ? @"dial.max.fill" : @"dial.min")];
    }
    if (state.reverb) {
        [names addObject:@"water.waves"];
    }
    if (state.delay) {
        [names addObject:@"repeat"];
    }
    if (state.shortDelay) {
        [names addObject:@"repeat.circle"];
    }
    // Last, against the codec text it qualifies.
    if (state.bitPerfect == 2) {
        [names addObject:@"lock.fill"];
    }
    else if (state.bitPerfect == 1) {
        [names addObject:@"lock.open"];
    }
    return names;
}

// Shrink-to-fit down to a floor, then truncate. Re-fit only on a text change:
// renderState runs on every transport event and metadata delivery.
- (void)setTitleLabelText:(NSString *)text {
    text = text ?: @""; // setStringValueIfChanged's nil trap
    if ([text isEqualToString:self.titleTextField.stringValue]) {
        return;
    }
    [self fitTitleFontForText:text];
    self.titleTextField.stringValue = text;
}

// Measured from the unshrunk font, so a widened label restores the size.
- (void)fitTitleFontForText:(NSString *)text {
    // The shrink floor, as a fraction of the themed size.
    static const CGFloat kTitleMinRatio = 15.0 / 23.0;
    NSFont *font = [Fonts titleFont];
    CGFloat baseSize = font.pointSize;
    CGFloat maxWidth = self.titleTextField.frame.size.width;
    _titleFittedWidth = maxWidth;
    CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
    if (width > maxWidth) {
        // Advance scales linearly with point size, so one step fits; 2%
        // covers rounding. The descriptor keeps any themed face.
        CGFloat fitted = baseSize * (maxWidth / width) * 0.98;
        CGFloat size = MAX(baseSize * kTitleMinRatio, floor(fitted * 2) / 2);
        font = [NSFont fontWithDescriptor:font.fontDescriptor size:size] ?: font;
    }
    self.titleTextField.font = font;
}

- (void)refitTitle {
    [self fitTitleFontForText:self.titleTextField.stringValue];
}

// The composed-line guards compare content, never color, so a theme color
// change must reset them before the next updateUI.
- (void)resetRenderGuards {
    _fileMetadataText = nil;
    _cornerTextAttributes = nil;
    // NSIntegerMin, not -1: -1 is the legitimate "no color" key, and a reset
    // to it would still satisfy the equality guard and skip the repaint.
    _lastKeyColorKey = NSIntegerMin;
}

- (void)refitTitleIfWidthChanged {
    if (self.titleTextField.frame.size.width != _titleFittedWidth) {
        [self fitTitleFontForText:self.titleTextField.stringValue];
    }
}

- (void)renderState:(TrackDisplayState)state
              track:(AudioTrack *)track
           duration:(NSTimeInterval)duration
               rate:(double)rate
        errorStatus:(NSString *)errorStatus {
    BOOL showTime = AppSettings.sharedInstance.currentTheme.showTimeLabels;
    self.currentTimeTextField.hidden = !showTime;
    self.totalTimeTextField.hidden = !showTime;
    switch (state) {
    case TrackDisplayStateTrack:
    case TrackDisplayStateLoading:
        self.artistTextField.alphaValue = 1.0;
        self.titleTextField.alphaValue = 1.0;
        self.currentTimeTextField.alphaValue = 1.0;
        self.totalTimeTextField.alphaValue = 1.0;
        _dropHintTextField.hidden = YES;
        setStringValueIfChanged(self.artistTextField, track.displayArtist);
        [self setTitleLabelText:track.displayTitle];
        if (state == TrackDisplayStateLoading) {
            // Unknown, not zero, while the open is in flight.
            setStringValueIfChanged(self.totalTimeTextField, STR_LABEL_TIME_UNKNOWN);
            setStringValueIfChanged(self.currentTimeTextField, STR_LABEL_TIME_UNKNOWN);
            _lastPosition = -1;
        }
        else {
            // -1 is the poisoned cache, not a position.
            [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition)
                                                 duration:duration
                                                     rate:rate];
        }
        if (state == TrackDisplayStateTrack && errorStatus) {
            [self setFileMetadataText:errorStatus];
        }
        else {
            [self setFileMetadataText:(AppSettings.sharedInstance.currentTheme.showFileInfo ? track.metadata.fileInfoLine : @"")];
        }
        break;

    case TrackDisplayStateLaunchGrace:
        setStringValueIfChanged(self.artistTextField, @"");
        [self setTitleLabelText:@""];
        setStringValueIfChanged(self.totalTimeTextField, @"");
        setStringValueIfChanged(self.currentTimeTextField, @"");
        // Text only: latched FX symbols are deck state and stay.
        [self setFileMetadataText:@""];
        _dropHintTextField.hidden = YES;
        _lastPosition = -1;
        break;

    case TrackDisplayStateEmpty:
    case TrackDisplayStateError: {
        // The error goes on the artist line, over the failed track's title.
        BOOL playError = (state == TrackDisplayStateError);
        setStringValueIfChanged(self.artistTextField,
                playError ? (errorStatus ?: STR_ERROR_PLAYBACK_GENERIC) : @"");
        [self setTitleLabelText:playError ? track.singleLineTitle : @""];
        // Half strength; the title matches the waveform placeholder, half the
        // shimmer's 0.55 peak.
        self.artistTextField.alphaValue = 0.5;
        self.titleTextField.alphaValue = 0.275;
        self.currentTimeTextField.alphaValue = 0.5;
        self.totalTimeTextField.alphaValue = 0.5;
        _dropHintTextField.hidden = NO;
        setStringValueIfChanged(self.totalTimeTextField, STR_LABEL_TIME_UNKNOWN);
        setStringValueIfChanged(self.currentTimeTextField, STR_LABEL_TIME_UNKNOWN);
        _lastPosition = -1;
        [_waveformView showEmptyPlaceholder];
        [self setFileMetadataText:@""]; // see LaunchGrace: FX symbols persist
        break;
    }
    }
}

- (void)renderPosition:(NSTimeInterval)position
              duration:(NSTimeInterval)duration
                  rate:(double)rate
                 state:(TrackDisplayState)state {
    if (state != TrackDisplayStateTrack && state != TrackDisplayStateLoading) {
        return;
    }
    if (duration > 0) {
        _waveformView.progress = (float) position / (float) duration;
    }
    if (!VibeTrackTimeMayUpdate(state, duration, NO)) {
        return; // keep renderState's --:--
    }
    NSTimeInterval displayPosition = position / rate;
    if (floor(displayPosition) != floor(_lastPosition)) {
        self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:displayPosition];
        _lastPosition = displayPosition;
    }
    // Only with a known duration: the end-of-playlist park zeroes the caller's
    // cache, and "-0:00" would clobber the parked full-length value.
    if (duration > 0) {
        [self renderRightTimeLabelWithDisplayPosition:displayPosition duration:duration rate:rate];
    }
}

// Total or minus-prefixed remaining, both wall-clock; displayPosition already
// is.
- (void)renderRightTimeLabelWithDisplayPosition:(NSTimeInterval)displayPosition
                                       duration:(NSTimeInterval)duration
                                           rate:(double)rate {
    NSString *text = [[Formatters sharedInstance] durationStringForFileDuration:duration rate:rate
            elapsedDisplayTime:displayPosition remaining:AppSettings.sharedInstance.currentTheme.showRemainingTime];
    setStringValueIfChanged(self.totalTimeTextField, text);
}

- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate state:(TrackDisplayState)state {
    // Track only, with a known duration; other states keep --:--.
    if (!VibeTrackTimeMayUpdate(state, duration, YES)) {
        return;
    }
    [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition) duration:duration rate:rate];
}

- (void)renderBPM:(float)displayBPM keyText:(NSString *)keyText colorKey:(NSInteger)colorKey {
    if (!AppSettings.sharedInstance.currentTheme.showFileInfo) {
        // The FX symbols are deck state, not file info, and keep rendering.
        displayBPM = 0;
        keyText = @"";
        colorKey = -1;
    }
    NSString *bpmText = displayBPM > 0 ? [[Formatters sharedInstance] bpmString:displayBPM] : @"";
    NSString *text;
    if (bpmText.length > 0 && keyText.length > 0) {
        // Layout punctuation, as on the codec line; not prose.
        text = [NSString stringWithFormat:VibeNotLocalized(@"%@ | %@"), bpmText, keyText];
    }
    else {
        text = bpmText.length > 0 ? bpmText : keyText;
    }
    // TRAP: not the text alone — toggling key colors leaves it identical while
    // the attributes change.
    if ([_bpmTextField.stringValue isEqualToString:text] && colorKey == _lastKeyColorKey) {
        return;
    }
    _lastKeyColorKey = colorKey;

    NSMutableAttributedString *line =
            [[NSMutableAttributedString alloc] initWithString:text
                                                  attributes:self.cornerTextAttributes];
    NSColor *keyColor = camelotColor(colorKey);
    if (keyColor && keyText.length > 0) {
        NSRange range = NSMakeRange(text.length - keyText.length, keyText.length);
        [line addAttribute:NSForegroundColorAttributeName value:keyColor range:range];
        [line addAttribute:NSFontAttributeName value:[Fonts infoFontBold:YES] range:range];
    }
    _bpmTextField.attributedStringValue = line;
}

#pragma mark - Codec line (FX symbols + file metadata)

- (void)renderFXState:(VibeFXDisplayState)state {
    if (memcmp(&state, &_fxState, sizeof(VibeFXDisplayState)) == 0) {
        return;
    }
    _fxState = state;
    [self composeFileMetadataLabel];
}

- (void)renderBitPerfectToolTip:(NSString *)toolTip {
    if (!AppSettings.sharedInstance.currentTheme.showStatusIcons) {
        toolTip = nil;
    }
    NSString *current = self.fileMetadataTextField.toolTip;
    if (current == toolTip || (toolTip && [current isEqualToString:toolTip])) {
        return;
    }
    self.fileMetadataTextField.toolTip = toolTip;
}

// TRAP: nil is a live input: an unscanned or unparseable track has nil
// metadata, so the caller's fileInfoLine is nil, and
// -[NSAttributedString initWithString:] raises on nil.
- (void)setFileMetadataText:(NSString *)text {
    text = text ?: @"";
    if ([_fileMetadataText isEqualToString:text]) {
        return;
    }
    _fileMetadataText = [text copy];
    [self composeFileMetadataLabel];
}

// One right-aligned run, FX symbols then codec text: inline symbols stay glued
// to text whose left edge moves with the codec string.
- (void)composeFileMetadataLabel {
    NSArray<NSString *> *symbols = AppSettings.sharedInstance.currentTheme.showStatusIcons
            ? fxSymbolNames(_fxState) : @[];
    if (symbols.count == 0) {
        self.fileMetadataTextField.attributedStringValue =
                [[NSAttributedString alloc] initWithString:_fileMetadataText
                                                attributes:self.cornerTextAttributes];
        // The artist line ends where this text begins, so every write moves it.
        [_contentView layoutArtistLineClearOfCodecLine];
        return;
    }
    NSFont *font = self.fileMetadataTextField.font;
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    for (NSString *name in symbols) {
        [line appendAttributedString:symbolRun(name, font)];
        // The font is required: on the default font the gap widens differently.
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "
                                                                     attributes:@{NSFontAttributeName: font}]];
    }
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:_fileMetadataText
                                                                attributes:self.cornerTextAttributes]];
    // Kern and paragraph style only, so the per-run colors survive.
    [line addAttributes:kernedRightAlignedAttributes() range:NSMakeRange(0, line.length)];
    self.fileMetadataTextField.attributedStringValue = line;
    [_contentView layoutArtistLineClearOfCodecLine];
}

// Optical, not metric: the dial glyphs spend their box on tick marks and read
// small beside solid symbols at the same height.
static CGFloat fxSymbolSizeMultiplier(NSString *symbolName) {
    return [symbolName hasPrefix:@"dial."] ? 1.3 : 1.0;
}

static NSAttributedString *symbolRun(NSString *symbolName, NSFont *font) {
    CGFloat height = round(font.pointSize * 0.85 * fxSymbolSizeMultiplier(symbolName));
    // Bold: the default stroke is a hairline at this size.
    NSImageSymbolConfiguration *configuration =
            [NSImageSymbolConfiguration configurationWithPointSize:height
                                                            weight:NSFontWeightBold
                                                             scale:NSImageSymbolScaleMedium];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:symbolName]
            imageWithSymbolConfiguration:configuration];
    if (!image) {
        return [[NSAttributedString alloc] initWithString:@""];
    }
    image.template = YES; // tinted with the run's foreground color
    NSSize size = image.size;
    CGFloat width = size.height > 0 ? round(height * size.width / size.height) : height;
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    // Bounds are baseline-relative; center on the cap height.
    attachment.bounds = CGRectMake(0, font.capHeight / 2 - height / 2, width, height);
    NSMutableAttributedString *run =
            [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    // A step brighter than the codec text, matching the time labels.
    [run addAttribute:NSForegroundColorAttributeName
                value:NSColor.secondaryLabelColor
                range:NSMakeRange(0, run.length)];
    return run;
}

- (void)resetPlayheadToStartWithDuration:(NSTimeInterval)duration rate:(double)rate {
    _waveformView.progress = 0;
    _lastPosition = 0;
    setStringValueIfChanged(self.currentTimeTextField,
            [[Formatters sharedInstance] durationStringFromTimeInterval:0]);
    // The caller passes the track's own duration: the player's is mid-teardown.
    [self renderRightTimeLabelWithDisplayPosition:0 duration:duration rate:rate];
}

#pragma mark - Waveform rendering states

- (void)prepareForWaveformLoad {
    [_waveformView prepareForWaveformLoad];
}

- (void)showWaveform:(CodableAudioWaveform *)waveform {
    [_waveformView showWaveform:waveform];
}

- (void)showWaveformLoadingIndicator {
    [_waveformView showLoadingIndicator];
}

- (void)hideWaveformLoadingIndicator {
    [_waveformView hideLoadingIndicator];
}

- (void)setWaveformLoadingProgress:(float)fraction {
    [_waveformView setLoadingProgress:fraction];
}

- (void)setConvertSweepFraction:(double)fraction {
    _waveformView.convertSweepFraction = fraction;
}

- (double)convertSweepFraction {
    return _waveformView.convertSweepFraction;
}

@end
