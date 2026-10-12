//
//  LibraryTrackCell.m
//  Vibe (iOS)
//

#import "LibraryTrackCell.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "EqualizerIndicatorView.h"
#import "FileRow.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"

@implementation LibraryTrackCell {
    UILabel                 *_numberLabel;
    EqualizerIndicatorView  *_indicatorView;
    LoadingIndicatorView    *_loadingView;
    // levelSource forwards to the indicator; no second copy.
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UILabel     *_durationLabel;
    UIStackView *_textStack;
    BOOL         _playing;
    // What renderTrack: last drew from, held strongly so an identity cannot
    // be reused by another object.
    AudioTrack         *_renderedTrack;
    AudioTrackMetadata *_renderedMetadata;
    UIImage            *_renderedThumbnail;
    NSString           *_renderedDuration;
    NSUInteger          _renderedNumber;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self build];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    _indicatorView.presentationVisible = NO;
    _indicatorView.audioOutputActive = NO;
    self.loading = NO;
}

- (void)build {
    UIView *content = self.contentView;

    // The artist line's text style, so the columns scale together.
    UIFont *numbers = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13
                                                               weight:UIFontWeightRegular]];

    _numberLabel = [[UILabel alloc] init];
    _numberLabel.font = numbers;
    _numberLabel.adjustsFontForContentSizeCategory = YES;
    _numberLabel.textColor = UIColor.secondaryLabelColor;
    _numberLabel.textAlignment = NSTextAlignmentRight;
    _numberLabel.adjustsFontSizeToFitWidth = YES;
    _numberLabel.minimumScaleFactor = 0.6;
    _numberLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_numberLabel];

    _indicatorView = [[EqualizerIndicatorView alloc] initWithFrame:CGRectZero];
    _indicatorView.hidden = YES;
    _indicatorView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_indicatorView];

    _loadingView = [[LoadingIndicatorView alloc] initWithFrame:CGRectZero];
    _loadingView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_loadingView];

    _artView = [[UIImageView alloc] init];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.layer.cornerRadius = kFileTileCornerRadius;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_artView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _artistLabel.adjustsFontForContentSizeCategory = YES;
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Negative: a label's height carries its font's leading.
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentLeading;
    text.spacing = -2;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:text];
    _textStack = text;

    _durationLabel = [[UILabel alloc] init];
    _durationLabel.font = numbers;
    _durationLabel.adjustsFontForContentSizeCategory = YES;
    _durationLabel.textColor = UIColor.secondaryLabelColor;
    _durationLabel.textAlignment = NSTextAlignmentRight;
    _durationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:_durationLabel];
    [_durationLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                    forAxis:UILayoutConstraintAxisHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [content.heightAnchor constraintGreaterThanOrEqualToConstant:kEstimatedRowHeight],

        [_numberLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:12],
        [_numberLabel.widthAnchor constraintEqualToConstant:kNumberColumnWidth],
        [_numberLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_numberLabel.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_numberLabel.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],

        [_indicatorView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_indicatorView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        // The mac's size.
        [_indicatorView.widthAnchor constraintEqualToConstant:16],
        [_indicatorView.heightAnchor constraintEqualToConstant:14],

        [_loadingView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_loadingView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_loadingView.widthAnchor constraintEqualToConstant:16],
        [_loadingView.heightAnchor constraintEqualToConstant:
                VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16).height],

        [_artView.leadingAnchor constraintEqualToAnchor:_numberLabel.trailingAnchor constant:8],
        [_artView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_artView.widthAnchor constraintEqualToConstant:kFileTileSide],
        [_artView.heightAnchor constraintEqualToConstant:kFileTileSide],
        [_artView.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:10],
        [_artView.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-10],

        [_textStack.leadingAnchor constraintEqualToAnchor:_artView.trailingAnchor
                                                 constant:kArtTextGap],
        [_textStack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_textStack.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_textStack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],
        [_textStack.trailingAnchor constraintLessThanOrEqualToAnchor:_durationLabel.leadingAnchor
                                                            constant:-8],

        [_durationLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [_durationLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_durationLabel.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_durationLabel.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],
    ]];
}

- (void)setLevelSource:(id<EqualizerLevelSource>)levelSource {
    _indicatorView.levelSource = levelSource;
}

- (id<EqualizerLevelSource>)levelSource {
    return _indicatorView.levelSource;
}

- (void)setEqualizerAudioOutputActive:(BOOL)equalizerAudioOutputActive {
    _indicatorView.audioOutputActive = equalizerAudioOutputActive;
}

- (BOOL)equalizerAudioOutputActive {
    return _indicatorView.audioOutputActive;
}

- (void)setEqualizerPresentationVisible:(BOOL)equalizerPresentationVisible {
    _indicatorView.presentationVisible = equalizerPresentationVisible;
}

- (BOOL)equalizerPresentationVisible {
    return _indicatorView.presentationVisible;
}

- (void)setLoading:(BOOL)loading {
    if (_loading == loading && _loadingView.isActive == loading) {
        return;
    }
    _loading = loading;
    [self resolveGutter];
}

- (void)setLoadingProgress:(float)loadingProgress {
    _loadingProgress = loadingProgress;
    _loadingView.progress = loadingProgress;
}

// Precedence: loading bar, equalizer, number.
- (void)resolveGutter {
    _loadingView.active = _loading;
    _numberLabel.hidden = _loading || _playing;
    _indicatorView.hidden = _loading || !_playing;
}

- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing {
    // Every appearance renders twice, since willDisplayCell: re-renders a
    // prepared cell, and the second usually finds nothing changed. These are
    // all the row draws from.
    AudioTrackMetadata *metadata = track.metadata;
    UIImage *thumbnail = track.cachedThumbnail;
    NSString *duration = track.durationString;
    if (track == _renderedTrack && metadata == _renderedMetadata && thumbnail == _renderedThumbnail
            && [duration isEqualToString:_renderedDuration] && number == _renderedNumber
            && playing == _playing) {
        return NO;
    }
    _renderedTrack = track;
    _renderedMetadata = metadata;
    _renderedThumbnail = thumbnail;
    _renderedDuration = duration;
    _renderedNumber = number;
    _numberLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)number];
    _playing = playing;
    [self resolveGutter];
    _artView.image = thumbnail ?: VibeFileTileImage(NO);
    _durationLabel.text = duration;
    _titleLabel.text = track.displayTitle ?: @"";
    // Hidden rather than blank, so the title centres on its own.
    NSString *artist = track.displayArtist;
    BOOL hidden = artist.length == 0;
    BOOL heightMoved = hidden != _artistLabel.isHidden;
    _artistLabel.text = artist ?: @"";
    _artistLabel.hidden = hidden;
    return heightMoved;
}

@end
