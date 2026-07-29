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
static void setKernedRightAlignedText(NSTextField *field, NSString *value) {
    if ([field.stringValue isEqualToString:value]) {
        return;
    }
    NSMutableParagraphStyle *paragraph = [[NSParagraphStyle new] mutableCopy];
    paragraph.alignment = NSTextAlignmentRight;
    field.attributedStringValue = [[NSAttributedString alloc] initWithString:value
                                                                  attributes:@{
                                       NSKernAttributeName:@(-1.2),
                                       NSParagraphStyleAttributeName:paragraph,
                                   }];
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
            setKernedRightAlignedText(self.fileMetadataTextField, fileMetadata);
        }
        else {
            setStringValueIfChanged(self.fileMetadataTextField, @"");
        }
        break;

    case TrackDisplayStateLaunchGrace:
        setStringValueIfChanged(self.artistTextField, @"");
        [self setTitleLabelText:@""];
        setStringValueIfChanged(self.totalTimeTextField, @"");
        setStringValueIfChanged(self.currentTimeTextField, @"");
        setStringValueIfChanged(self.fileMetadataTextField, @"");
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
        setStringValueIfChanged(self.fileMetadataTextField, @"");
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
