//
//  TrackDisplayController.m
//  Vibe
//

#import "TrackDisplayController.h"
#import "AppSettings.h"
#import "MainPlayerContentView.h"
#import "AudioWaveformView.h"
#import "AudioWaveformView+Loading.h" // the shimmer and empty-state pass-throughs
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "Fonts.h"
#import "MusicalKey.h"
#import "VibeStrings.h"

@implementation TrackDisplayController {
    __weak AudioWaveformView *_waveformView;
    __weak NSTextField      *_bpmTextField;
    __weak NSTextField      *_dropHintTextField;
    // The change guard for the elapsed label, in rounded wall-clock seconds.
    // A value of -1 poisons it, so the next tick always writes, even from
    // position 0.
    NSTimeInterval           _lastPosition;
    // The codec line's two independent inputs; see renderFXState:. They are
    // kept so that either can be re-rendered without the other, and as the
    // change guard: the composed string cannot be compared through
    // stringValue, since every symbol attachment is the same
    // object-replacement character.
    NSString                *_fileMetadataText;
    VibeFXDisplayState       _fxState;
    // The key the BPM line was last colored for, part of that line's change
    // guard: the text alone is not enough, since toggling the color setting
    // leaves it identical while the attributes must change. -1 is "uncolored".
    NSInteger                _lastKeyColorKey;
    // The label width the title's shrink-to-fit was computed against. The
    // label is width-flexible, so a window resize invalidates the fit; see
    // refitTitleIfWidthChanged.
    CGFloat                  _titleFittedWidth;
    // Held only for the artist line's re-cap: the width it may occupy depends
    // on how wide the codec line renders, which is this class's own output.
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

// TRAP: NSTextField.stringValue raises on nil, and a nil here has crashed:
// a message to a nil track returns a nil string that no isEqualToString:
// early-out can catch, because a message to nil answers NO and falls through
// to the assignment. Empty is what every nil string means on this header.
static void setStringValueIfChanged(NSTextField *field, NSString *value) {
    value = value ?: @"";
    if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
    }
}

// The codec corner's house style — right-aligned, with a tight kern — shared
// by the file-metadata and BPM labels. It is change-guarded like
// setStringValueIfChanged:, because both labels re-run on every render pass,
// and the BPM label on every fader tick besides. Reading the text back off the
// field keeps the guard here, in one place.
static NSDictionary *kernedRightAlignedAttributes(void) {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    return @{
        NSKernAttributeName: @(-1.2),
        NSParagraphStyleAttributeName: paragraph,
    };
}

// The dimming for both corner labels, the codec line and the BPM line beneath
// it. It lives in the text color rather than the fields' alphaValue, which is
// 1.0 on both — see MainPlayerContentView — because the codec field also
// carries the FX symbols, and a field-wide alpha would dim those too. The two
// labels are a matched pair, so they take the same treatment or they visibly
// drift apart.
//
// tertiaryLabelColor stands in for the old secondaryLabelColor under 50% field
// alpha. Reproducing that exactly with a color is impossible:
// colorWithAlphaComponent: replaces the alpha rather than scaling it, and
// layer-level alpha composites rasterized glyphs rather than changing how they
// rasterize. A resolved color would also go stale on a light-dark flip, since
// these strings are rebuilt only on content changes.
static NSDictionary *cornerTextAttributes(void) {
    NSMutableDictionary *attributes = [kernedRightAlignedAttributes() mutableCopy];
    attributes[NSForegroundColorAttributeName] = NSColor.tertiaryLabelColor;
    return attributes;
}

// The Camelot wheel's own colors: one hue per wheel number, stepping once
// around the color wheel as the number steps around the Camelot wheel, and
// anchored so that 1 is green — which is what puts 3 in teal, 5 in blue, 7 in
// violet, 9 in red and 11 in yellow, close to the printed wheel. Keys one
// step apart, the harmonically compatible ones, therefore land in neighboring
// hues, and a relative major/minor pair (8A and 8B) shares a hue because it
// shares a number. The hues approximate the published wheel rather than
// sampling it. Saturation and brightness differ per appearance so the label
// stays legible on both the light and the dark chrome; neither is taken to
// full brightness, which reads as garish next to the dimmed corner text.
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
                NSAppearanceName matched = [appearance bestMatchFromAppearancesWithNames:@[
                    NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
                ]];
                BOOL dark = [matched isEqualToString:NSAppearanceNameDarkAqua];
                return [NSColor colorWithHue:hue
                                  saturation:dark ? 0.62 : 0.90
                                  brightness:dark ? 0.82 : 0.60
                                       alpha:1.0];
            }];
        }
    });
    return palette[number];
}

// The FX indicator symbols, in menu order: Q, W, E, R and T. Low kill shows
// the filled dial while its boost is latched, because the boost modifies that
// filter rather than being an effect of its own, and so never gets a symbol of
// its own. The boost runs the filter even while lowKill itself is off, so it
// shows the filled dial alone too. Both delays can be latched at once, and
// then both symbols show.
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
    return names;
}

// Shrink-to-fit for the title. A long title reduces the font size, down to a
// floor, so that it fits the label's capped width rather than running under
// the codec and BPM labels, and anything still too long at the floor truncates
// with an ellipsis. renderState re-runs on every transport event and metadata
// delivery, once per track during the sweep, so re-fit only when the text has
// changed.
- (void)setTitleLabelText:(NSString *)text {
    // Same nil trap as setStringValueIfChanged: a nil text falls through the
    // early-out (message to nil answers NO) into a raising assignment.
    text = text ?: @"";
    if ([text isEqualToString:self.titleTextField.stringValue]) {
        return;
    }
    [self fitTitleFontForText:text];
    self.titleTextField.stringValue = text;
}

// The fit itself, always measured at the base font size, so that re-running it
// on a widened label restores the font a narrower fit shrank.
- (void)fitTitleFontForText:(NSString *)text {
    static const CGFloat kTitleFontSize = 23;
    static const CGFloat kTitleMinFontSize = 15;
    NSFont *font = [Fonts font:kTitleFontSize];
    CGFloat maxWidth = self.titleTextField.frame.size.width;
    _titleFittedWidth = maxWidth;
    CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
    if (width > maxWidth) {
        // Glyph advance scales linearly with point size, so one scale step
        // lands on the fitting size. The 2% margin covers the rounding.
        CGFloat fitted = kTitleFontSize * (maxWidth / width) * 0.98;
        font = [Fonts font:MAX(kTitleMinFontSize, floor(fitted * 2) / 2)];
    }
    self.titleTextField.font = font;
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
    switch (state) {
    case TrackDisplayStateTrack:
    case TrackDisplayStateLoading:
        self.artistTextField.alphaValue = 1.0;
        self.titleTextField.alphaValue = 1.0;
        self.currentTimeTextField.alphaValue = 1.0;
        self.totalTimeTextField.alphaValue = 1.0;
        _dropHintTextField.hidden = YES;
        if (track.hasArtistAndTitle) {
            setStringValueIfChanged(self.artistTextField, track.artist);
            [self setTitleLabelText:track.title];
        }
        else {
            setStringValueIfChanged(self.artistTextField, @"");
            [self setTitleLabelText:track.singleLineTitle];
        }
        if (state == TrackDisplayStateLoading) {
            // The open is still in flight, so the duration and position are
            // unknown rather than zero. Show placeholders, not 0:00.
            setStringValueIfChanged(self.totalTimeTextField, STR_LABEL_TIME_UNKNOWN);
            setStringValueIfChanged(self.currentTimeTextField, STR_LABEL_TIME_UNKNOWN);
            _lastPosition = -1;
        }
        else {
            // -1 poisons the elapsed-label cache rather than naming a
            // position, so render it as 0.
            [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition)
                                                 duration:duration
                                                     rate:rate];
        }
        // The line itself is AudioTrackMetadata's, shared with the iOS page
        // header; the setting decides only whether it is shown.
        [self setFileMetadataText:(AppSettings.sharedInstance.showFileInfo ? track.metadata.fileInfoLine : @"")];
        break;

    case TrackDisplayStateLaunchGrace:
        setStringValueIfChanged(self.artistTextField, @"");
        [self setTitleLabelText:@""];
        setStringValueIfChanged(self.totalTimeTextField, @"");
        setStringValueIfChanged(self.currentTimeTextField, @"");
        // Text only. Any latched FX symbols stay, because they are deck state
        // rather than track state and apply to whatever plays next.
        [self setFileMetadataText:@""];
        _dropHintTextField.hidden = YES;
        _lastPosition = -1;
        break;

    case TrackDisplayStateEmpty:
    case TrackDisplayStateError: {
        // The empty state, which also serves the play-error rendering: the
        // error goes on the artist line, over the failed track's title.
        BOOL playError = (state == TrackDisplayStateError);
        setStringValueIfChanged(self.artistTextField,
                playError ? (errorStatus ?: STR_ERROR_PLAYBACK_GENERIC) : @"");
        [self setTitleLabelText:playError ? track.singleLineTitle : @""];
        // The whole empty state sits at half strength, and the title matches
        // the waveform's placeholder line: 0.275 is half the shimmer's 0.55
        // peak.
        self.artistTextField.alphaValue = 0.5;
        self.titleTextField.alphaValue = 0.275;
        self.currentTimeTextField.alphaValue = 0.5;
        self.totalTimeTextField.alphaValue = 0.5;
        _dropHintTextField.hidden = NO;
        setStringValueIfChanged(self.totalTimeTextField, STR_LABEL_TIME_UNKNOWN);
        setStringValueIfChanged(self.currentTimeTextField, STR_LABEL_TIME_UNKNOWN);
        // Poison the position cache, so that the first tick of the next track
        // always overwrites the placeholder, even from position 0.
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
    // Track and Loading only. In the empty and play-error states the position
    // readout must keep showing --:--.
    if (state != TrackDisplayStateTrack && state != TrackDisplayStateLoading) {
        return;
    }
    if (duration > 0) {
        _waveformView.progress = (float) position / (float) duration;
    }
    if (state == TrackDisplayStateLoading) {
        // The position reads 0 while the open is in flight, meaning unknown
        // rather than zero. renderState shows --:-- for this state, so do not
        // overwrite it.
        return;
    }
    NSTimeInterval displayPosition = position / rate;
    if (round(displayPosition) != round(_lastPosition)) {
        self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:displayPosition];
        _lastPosition = displayPosition;
    }
    // In remaining mode the right label counts down with the tick; in total
    // mode this is a same-string no-op after the first render. It runs only
    // with a known duration: at the end-of-playlist park the caller's duration
    // cache is zeroed, and writing "-0:00" here would clobber the parked
    // full-length value from resetPlayheadToStartWithDuration:rate: and
    // renderState.
    if (duration > 0) {
        [self renderRightTimeLabelWithDisplayPosition:displayPosition duration:duration rate:rate];
    }
}

// The right-hand time label: either the total duration or, per the persisted
// setting, the minus-prefixed remaining time at the current position, such as
// "-1:50". Both are wall-clock — file time divided by the varispeed rate, like
// the elapsed label. displayPosition is already wall-clock, being position
// divided by the rate.
- (void)renderRightTimeLabelWithDisplayPosition:(NSTimeInterval)displayPosition
                                       duration:(NSTimeInterval)duration
                                           rate:(double)rate {
    NSString *text;
    if (AppSettings.sharedInstance.showRemainingTime) {
        NSTimeInterval remaining = MAX(0, duration / rate - displayPosition);
        text = [VibeNotLocalized(@"-") stringByAppendingString:
                [[Formatters sharedInstance] durationStringFromTimeInterval:remaining]];
    }
    else {
        text = [[Formatters sharedInstance] durationStringFromTimeInterval:duration / rate];
    }
    setStringValueIfChanged(self.totalTimeTextField, text);
}

- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate state:(TrackDisplayState)state {
    // Track only, like renderPosition:'s label writes. In the Loading, empty
    // and error states the right label must keep showing --:--, and the
    // duration guard stops a 0 rendering as 0:00 — the same clobber
    // renderPosition: guards against.
    if (state != TrackDisplayStateTrack || duration <= 0) {
        return;
    }
    [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition) duration:duration rate:rate];
}

- (void)renderBPM:(float)displayBPM keyText:(NSString *)keyText colorKey:(NSInteger)colorKey {
    if (!AppSettings.sharedInstance.showFileInfo) {
        // Hidden along with the codec text above it; the FX symbols are deck
        // state, not file info, and keep rendering.
        displayBPM = 0;
        keyText = @"";
        colorKey = -1;
    }
    NSString *bpmText = displayBPM > 0
            ? [NSString stringWithFormat:STR_LABEL_BPM,
                    [[Formatters sharedInstance] decimalString:displayBPM fractionDigits:1]]
            : @"";
    NSString *text;
    if (bpmText.length > 0 && keyText.length > 0) {
        // Layout punctuation between two readouts, not prose — and the same
        // rule the codec line above uses to separate its two fields.
        text = [NSString stringWithFormat:VibeNotLocalized(@"%@ | %@"), bpmText, keyText];
    }
    else {
        text = bpmText.length > 0 ? bpmText : keyText;
    }
    // The text alone cannot gate the redraw here: toggling the color setting
    // leaves it identical while the attributes must change.
    if ([_bpmTextField.stringValue isEqualToString:text] && colorKey == _lastKeyColorKey) {
        return;
    }
    _lastKeyColorKey = colorKey;

    NSMutableAttributedString *line =
            [[NSMutableAttributedString alloc] initWithString:text
                                                  attributes:cornerTextAttributes()];
    NSColor *keyColor = camelotColor(colorKey);
    if (keyColor && keyText.length > 0) {
        // The key sits at the tail, after the separator when both are shown.
        NSRange range = NSMakeRange(text.length - keyText.length, keyText.length);
        [line addAttribute:NSForegroundColorAttributeName value:keyColor range:range];
        [line addAttribute:NSFontAttributeName
                     value:[Fonts fontForNumbers:_bpmTextField.font.pointSize bold:YES]
                     range:range];
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

// TRAP: nil is a live input, not a programmer error. A track whose metadata
// scan has not landed — or failed outright, as on an unparseable file — has a
// nil `metadata`, so the caller's `track.metadata.fileInfoLine` is a message to
// nil. composeFileMetadataLabel feeds this straight to
// -[NSAttributedString initWithString:], which raises on nil.
- (void)setFileMetadataText:(NSString *)text {
    text = text ?: @"";
    if ([_fileMetadataText isEqualToString:text]) {
        return;
    }
    _fileMetadataText = [text copy];
    [self composeFileMetadataLabel];
}

// The codec line is one right-aligned run: the active FX symbols, then the
// codec text. Inlining the symbols, rather than placing a separate view left
// of the label, is what keeps them glued to the text, because the label is
// right-aligned in a fixed frame and so its text's left edge moves with the
// track's codec string. It also gets the label's color and 50% alpha for free.
- (void)composeFileMetadataLabel {
    NSArray<NSString *> *symbols = fxSymbolNames(_fxState);
    if (symbols.count == 0) {
        self.fileMetadataTextField.attributedStringValue =
                [[NSAttributedString alloc] initWithString:_fileMetadataText
                                                attributes:cornerTextAttributes()];
        // The artist line ends where this text begins, so every write moves it.
        [_contentView layoutArtistLineClearOfCodecLine];
        return;
    }
    NSFont *font = self.fileMetadataTextField.font;
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    for (NSString *name in symbols) {
        [line appendAttributedString:symbolRun(name, font)];
        // Wider than the gap the glyphs carry between themselves, so that a
        // run of three still reads as three marks. It is dimmed like the codec
        // text: the spacer is only ever whitespace, but a stray full-strength
        // run would widen differently under kerning.
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "
                                                                     attributes:@{NSFontAttributeName: font}]];
    }
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:_fileMetadataText
                                                                attributes:cornerTextAttributes()]];
    // Right-align the whole line, symbols included. Only the kern and the
    // paragraph style are set, so the per-run foreground colors above survive.
    [line addAttributes:kernedRightAlignedAttributes() range:NSMakeRange(0, line.length)];
    self.fileMetadataTextField.attributedStringValue = line;
    [_contentView layoutArtistLineClearOfCodecLine];
}

// One SF Symbol as an inline attachment, centered vertically on the text's cap
// height. An attachment's bounds are relative to the baseline, so without the
// offset the glyph sits on the baseline and rides high.
//
// The per-symbol correction is optical, not geometric, and no metric yields
// it. The dial glyphs spend much of their bounding box on the tick marks
// ringing a small central dial, so at the row's shared box height they read
// visibly smaller than the solid-stroke symbols beside them. Sizing their box
// up evens the row out.
static CGFloat fxSymbolSizeMultiplier(NSString *symbolName) {
    return [symbolName hasPrefix:@"dial."] ? 1.3 : 1.0;
}

static NSAttributedString *symbolRun(NSString *symbolName, NSFont *font) {
    CGFloat height = round(font.pointSize * 0.85 * fxSymbolSizeMultiplier(symbolName));
    // Bold weight, because at this size the default stroke is a hairline that
    // reads as noise next to the text. The configuration's point size sets the
    // weight's proportions, so it tracks the height the attachment draws at
    // below; the drawn size itself stays the attachment's bounds.
    NSImageSymbolConfiguration *configuration =
            [NSImageSymbolConfiguration configurationWithPointSize:height
                                                            weight:NSFontWeightBold
                                                             scale:NSImageSymbolScaleMedium];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:symbolName]
            imageWithSymbolConfiguration:configuration];
    if (!image) {
        return [[NSAttributedString alloc] initWithString:@""];
    }
    // A template image. NSTextField tints the attachment with the run's
    // foreground color, so the symbols follow secondaryLabelColor through
    // appearance changes with no explicit color to keep in sync.
    image.template = YES;
    NSSize size = image.size;
    CGFloat width = size.height > 0 ? round(height * size.width / size.height) : height;
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = image;
    attachment.bounds = CGRectMake(0, font.capHeight / 2 - height / 2, width, height);
    NSMutableAttributedString *run =
            [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    // Full-strength secondaryLabelColor: exactly the time labels' color at
    // their full field alpha, and a step brighter than the codec text beside
    // it; see cornerTextAttributes.
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
    // In remaining mode the resting label shows the full track, such as
    // "-3:45". The caller passes the track's own duration, because the
    // player's is mid-teardown.
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
