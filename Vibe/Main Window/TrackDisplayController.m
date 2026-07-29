//
//  TrackDisplayController.m
//  Vibe
//

#import "TrackDisplayController.h"
#import "MainPlayerContentView.h"
#import "AudioWaveformView.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "Fonts.h"

@implementation TrackDisplayController {
    __weak AudioWaveformView *_waveformView;
    __weak NSTextField      *_bpmTextField;
    __weak NSTextField      *_dropHintTextField;
    // Change guard for the elapsed label (rounded wall-clock seconds); -1
    // poisons it so the next tick always writes, even from position 0.
    NSTimeInterval           _lastPosition;
    // The codec line's two independent inputs (see renderFXState:). Kept so
    // either can be re-rendered without the other, and as the change guard —
    // the composed string can't be compared by stringValue, since every
    // symbol attachment is the same object-replacement character.
    NSString                *_fileMetadataText;
    VibeFXDisplayState       _fxState;
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
        _lastPosition = -1;
        _fileMetadataText = @"";
        _fxState = (VibeFXDisplayState){0};
    }
    return self;
}

static void setStringValueIfChanged(NSTextField *field, NSString *value) {
    if (![field.stringValue isEqualToString:value]) {
        field.stringValue = value;
    }
}

// The codec-corner house style — right-aligned, tight kern — shared by the
// file-metadata and BPM labels. Change-guarded like setStringValueIfChanged:
// both labels re-run every render pass (BPM on every fader tick too), and
// reading the text back off the field keeps the guard here, in one place.
static NSDictionary *kernedRightAlignedAttributes(void) {
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    return @{
        NSKernAttributeName: @(-1.2),
        NSParagraphStyleAttributeName: paragraph,
    };
}

// The dimming for BOTH corner labels (codec line and the BPM line under it).
// It lives in the text color rather than the fields' alphaValue — which is
// now 1.0 on both, see MainPlayerContentView — because the codec field also
// carries the FX symbols, and a field-wide alpha would dim those too. The two
// labels are a matched pair, so they take the same treatment or they visibly
// drift apart. tertiaryLabelColor stands in for the old
// secondaryLabelColor-under-50%-field-alpha: reproducing that exactly isn't
// possible with a color (colorWithAlphaComponent: REPLACES alpha rather than
// scaling it, and layer-level alpha composites rasterized glyphs rather than
// changing how they rasterize), and a resolved color would go stale on a
// light↔dark flip since these strings are only rebuilt on content changes.
static NSDictionary *cornerTextAttributes(void) {
    NSMutableDictionary *attributes = [kernedRightAlignedAttributes() mutableCopy];
    attributes[NSForegroundColorAttributeName] = NSColor.tertiaryLabelColor;
    return attributes;
}

static void setKernedRightAlignedText(NSTextField *field, NSString *value) {
    if ([field.stringValue isEqualToString:value]) {
        return;
    }
    field.attributedStringValue = [[NSAttributedString alloc] initWithString:value
                                                                  attributes:cornerTextAttributes()];
}

// The FX indicator symbols, in menu order (Q, W, E, R, T). Low kill shows the
// filled dial while its boost is latched — the boost is a modifier of that
// filter, not an effect of its own, so it never gets a symbol of its own. The
// boost runs the filter even while lowKill itself is off, so it shows the
// filled dial alone too. Both delays can be latched at once, and then both
// symbols show.
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

// Shrink-to-fit for the title: long titles reduce the font size (down to a
// floor) so they fit the label's capped width instead of running under the
// codec/BPM labels; anything still too long at the floor truncates with an
// ellipsis. renderState re-runs on every transport event and metadata
// delivery (once per track during the sweep), so only re-fit when the text
// changes.
- (void)setTitleLabelText:(NSString *)text {
    static const CGFloat kTitleFontSize = 23;
    static const CGFloat kTitleMinFontSize = 15;
    if ([text isEqualToString:self.titleTextField.stringValue]) {
        return;
    }
    NSFont *font = [Fonts font:kTitleFontSize];
    CGFloat maxWidth = self.titleTextField.frame.size.width;
    CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
    if (width > maxWidth) {
        // Glyph advance scales linearly with point size, so one scale step
        // lands on the fitting size; the 2% margin covers rounding.
        CGFloat fitted = kTitleFontSize * (maxWidth / width) * 0.98;
        font = [Fonts font:MAX(kTitleMinFontSize, floor(fitted * 2) / 2)];
    }
    self.titleTextField.font = font;
    self.titleTextField.stringValue = text;
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
            // Open still in flight — duration/position are unknown, not zero,
            // so show placeholders rather than 0:00.
            setStringValueIfChanged(self.totalTimeTextField, @"--:--");
            setStringValueIfChanged(self.currentTimeTextField, @"--:--");
            _lastPosition = -1;
        }
        else {
            // -1 poisons the elapsed-label cache, not a position; render as 0.
            [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition)
                                                 duration:duration
                                                     rate:rate];
        }
        if (track.metadata.fileType) {
            // bitrate/sampleRate can be nil even with fileType set — TagLib
            // can return no audioProperties. Guard so the label never shows
            // "(null) kbps" / "0.0 kHz".
            NSString *bitrate = @"";
            if (!track.metadata.isLossless && track.metadata.bitrate) {
                bitrate = [NSString stringWithFormat:@"%@ kbps | ", track.metadata.bitrate];
            }
            NSString *sampleRate = @"";
            if (track.metadata.sampleRate) {
                sampleRate = [NSString stringWithFormat:@"%.1f kHz", [track.metadata.sampleRate doubleValue] / 1000];
            }
            NSString *fileMetadata = (bitrate.length || sampleRate.length)
                    ? [NSString stringWithFormat:@"%@ | %@%@", track.metadata.fileType, bitrate, sampleRate]
                    : track.metadata.fileType;
            [self setFileMetadataText:fileMetadata];
        }
        else {
            [self setFileMetadataText:@""];
        }
        break;

    case TrackDisplayStateLaunchGrace:
        setStringValueIfChanged(self.artistTextField, @"");
        [self setTitleLabelText:@""];
        setStringValueIfChanged(self.totalTimeTextField, @"");
        setStringValueIfChanged(self.currentTimeTextField, @"");
        // Text only — any latched FX symbols stay (they are deck state, not
        // track state, and apply to whatever plays next).
        [self setFileMetadataText:@""];
        _dropHintTextField.hidden = YES;
        _lastPosition = -1;
        break;

    case TrackDisplayStateEmpty:
    case TrackDisplayStateError: {
        // Empty state — also the play-error rendering: the error goes on the
        // artist line, over the failed track's title.
        BOOL playError = (state == TrackDisplayStateError);
        setStringValueIfChanged(self.artistTextField, playError ? (errorStatus ?: @"Playback error") : @"");
        [self setTitleLabelText:playError ? track.singleLineTitle : @""];
        // The whole empty state sits at half strength; the title matches the
        // waveform's placeholder line (0.275 = half the shimmer's 0.55 peak).
        self.artistTextField.alphaValue = 0.5;
        self.titleTextField.alphaValue = 0.275;
        self.currentTimeTextField.alphaValue = 0.5;
        self.totalTimeTextField.alphaValue = 0.5;
        _dropHintTextField.hidden = NO;
        setStringValueIfChanged(self.totalTimeTextField, @"--:--");
        setStringValueIfChanged(self.currentTimeTextField, @"--:--");
        // Poison the position cache so the first tick of the next track always
        // overwrites the placeholder, even from position 0.
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
    // Track/Loading only: in the empty and play-error states the position
    // readout must keep showing --:--.
    if (state != TrackDisplayStateTrack && state != TrackDisplayStateLoading) {
        return;
    }
    if (duration > 0) {
        _waveformView.progress = (float) position / (float) duration;
    }
    if (state == TrackDisplayStateLoading) {
        // Position reads 0 while the open is in flight — unknown, not zero.
        // renderState shows --:-- for this state; don't overwrite it.
        return;
    }
    NSTimeInterval displayPosition = position / rate;
    if (round(displayPosition) != round(_lastPosition)) {
        self.currentTimeTextField.stringValue = [[Formatters sharedInstance] durationStringFromTimeInterval:displayPosition];
        _lastPosition = displayPosition;
    }
    // In remaining mode the right label counts down with the tick; in total
    // mode this is a same-string no-op after the first render. Only with a
    // known duration: at the end-of-playlist park the caller's duration cache
    // is zeroed, and writing "-0:00" here would clobber the parked full-length
    // value from resetPlayheadToStartWithDuration:rate:/renderState.
    if (duration > 0) {
        [self renderRightTimeLabelWithDisplayPosition:displayPosition duration:duration rate:rate];
    }
}

// The right-hand time label: total duration, or — per the persisted setting —
// the minus-prefixed remaining time at the current position ("-1:50"). Both
// wall-clock: file time divided by the varispeed rate, like the elapsed
// label. displayPosition is already wall-clock (position / rate).
- (void)renderRightTimeLabelWithDisplayPosition:(NSTimeInterval)displayPosition
                                       duration:(NSTimeInterval)duration
                                           rate:(double)rate {
    NSString *text;
    if (Settings.showRemainingTime) {
        NSTimeInterval remaining = MAX(0, duration / rate - displayPosition);
        text = [@"-" stringByAppendingString:
                [[Formatters sharedInstance] durationStringFromTimeInterval:remaining]];
    }
    else {
        text = [[Formatters sharedInstance] durationStringFromTimeInterval:duration / rate];
    }
    setStringValueIfChanged(self.totalTimeTextField, text);
}

- (void)renderTotalDuration:(NSTimeInterval)duration rate:(double)rate {
    [self renderRightTimeLabelWithDisplayPosition:MAX(0, _lastPosition) duration:duration rate:rate];
}

- (void)renderBPM:(float)displayBPM {
    NSString *text = displayBPM > 0 ? [NSString stringWithFormat:@"%.1f BPM", displayBPM] : @"";
    setKernedRightAlignedText(_bpmTextField, text);
}

#pragma mark - Codec line (FX symbols + file metadata)

- (void)renderFXState:(VibeFXDisplayState)state {
    if (memcmp(&state, &_fxState, sizeof(VibeFXDisplayState)) == 0) {
        return;
    }
    _fxState = state;
    [self composeFileMetadataLabel];
}

- (void)setFileMetadataText:(NSString *)text {
    if ([_fileMetadataText isEqualToString:text]) {
        return;
    }
    _fileMetadataText = [text copy];
    [self composeFileMetadataLabel];
}

// The codec line is one right-aligned run: the active FX symbols, then the
// codec text. Inlining the symbols (rather than placing a separate view left
// of the label) is what keeps them glued to the text — the label is
// right-aligned in a fixed frame, so its text's left edge moves with the
// track's codec string — and it gets the label's color and 50% alpha for
// free.
- (void)composeFileMetadataLabel {
    NSArray<NSString *> *symbols = fxSymbolNames(_fxState);
    if (symbols.count == 0) {
        self.fileMetadataTextField.attributedStringValue =
                [[NSAttributedString alloc] initWithString:_fileMetadataText
                                                attributes:cornerTextAttributes()];
        return;
    }
    NSFont *font = self.fileMetadataTextField.font;
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    for (NSString *name in symbols) {
        [line appendAttributedString:symbolRun(name, font)];
        // Wider than the inter-symbol gap the glyphs carry themselves, so a
        // run of three still reads as three marks. Dimmed like the codec text
        // — the spacer is only ever whitespace, but a stray full-strength run
        // would widen differently under kerning.
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "
                                                                     attributes:@{NSFontAttributeName: font}]];
    }
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:_fileMetadataText
                                                                attributes:cornerTextAttributes()]];
    // Right-align the whole line, symbols included — kern and paragraph only,
    // so the per-run foreground colors set above survive.
    [line addAttributes:kernedRightAlignedAttributes() range:NSMakeRange(0, line.length)];
    self.fileMetadataTextField.attributedStringValue = line;
}

// One SF Symbol as an inline attachment, vertically centered on the text's
// cap height (an attachment's bounds are relative to the baseline, so without
// the offset the glyph sits ON the baseline and rides high).
// Per-symbol optical correction. The dial glyphs spend much of their bounding
// box on the tick marks ringing a small central dial, so at the row's shared
// box height they read visibly smaller than the solid-stroke symbols beside
// them; sizing their box up evens the row out. Optical, not geometric —
// there's no metric to derive it from.
static CGFloat fxSymbolSizeMultiplier(NSString *symbolName) {
    return [symbolName hasPrefix:@"dial."] ? 1.3 : 1.0;
}

static NSAttributedString *symbolRun(NSString *symbolName, NSFont *font) {
    CGFloat height = round(font.pointSize * 0.85 * fxSymbolSizeMultiplier(symbolName));
    // Bold weight: at this size the default stroke is a hairline that reads
    // as noise next to the text. The configuration's point size sets the
    // weight's proportions, so it tracks the height the attachment draws at
    // below (the drawn size itself stays the attachment's bounds).
    NSImageSymbolConfiguration *configuration =
            [NSImageSymbolConfiguration configurationWithPointSize:height
                                                            weight:NSFontWeightBold
                                                             scale:NSImageSymbolScaleMedium];
    NSImage *image = [[NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:symbolName]
            imageWithSymbolConfiguration:configuration];
    if (!image) {
        return [[NSAttributedString alloc] initWithString:@""];
    }
    // Template image: NSTextField tints the attachment with the run's
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
    // Full-strength secondaryLabelColor — exactly the time labels' color at
    // their full field alpha, and a step brighter than the codec text next to
    // it (see cornerTextAttributes).
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
    // In remaining mode the resting label is the full track ("-3:45"); the
    // caller passes the track's own duration — the player's is mid-teardown.
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

@end
