//
//  PlaylistTrackCell.m
//  Vibe (iOS)
//

#import "PlaylistTrackCell.h"

#import "EqualizerIndicatorView.h"
#import "FileRow.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"
#import "VibeTrackRow.h"

static const CGFloat kGutterLeading = 12;
static const CGFloat kNumberColumnWidth = 26;
static const CGFloat kGutterArtGap = 8;
static const CGFloat kArtTextGap = 14;

@implementation PlaylistTrackCell {
    UILabel                 *_numberLabel;
    EqualizerIndicatorView  *_indicatorView;
    LoadingIndicatorView    *_loadingView;
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_subtitleLabel;
    UILabel     *_durationLabel;
    UIStackView *_textStack;
    // What renderRow: last drew, a copy, so the caller's later edits to its
    // row cannot match it. Holding the thumbnail strongly keeps its identity
    // from being reused by another image.
    VibeTrackRow *_renderedRow;
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

    // The subtitle's text style, so the columns scale together.
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

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _subtitleLabel.adjustsFontForContentSizeCategory = YES;
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;
    _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    // Negative: a label's height carries its font's leading.
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _subtitleLabel]];
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

        [_numberLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kGutterLeading],
        [_numberLabel.widthAnchor constraintEqualToConstant:kNumberColumnWidth],
        [_numberLabel.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_numberLabel.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:8],
        [_numberLabel.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-8],

        [_indicatorView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_indicatorView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_indicatorView.widthAnchor constraintEqualToConstant:16],
        [_indicatorView.heightAnchor constraintEqualToConstant:14],

        [_loadingView.centerXAnchor constraintEqualToAnchor:_numberLabel.centerXAnchor],
        [_loadingView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_loadingView.widthAnchor constraintEqualToConstant:16],
        [_loadingView.heightAnchor constraintEqualToConstant:
                VibeLoadingIndicatorMetricsForStyle(VibeLoadingIndicatorStyleRow, 16).height],

        [_artView.leadingAnchor constraintEqualToAnchor:_numberLabel.trailingAnchor
                                                constant:kGutterArtGap],
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

+ (CGFloat)separatorLeadingInset {
    return kGutterLeading + kNumberColumnWidth + kGutterArtGap + kFileTileSide + kArtTextGap;
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
    _numberLabel.hidden = _loading || _renderedRow.playing;
    _indicatorView.hidden = _loading || !_renderedRow.playing;
}

- (BOOL)renderRow:(VibeTrackRow *)row {
    // Every appearance renders twice, since willDisplayCell: re-renders a
    // prepared cell, and the second usually finds nothing changed.
    if ([row isEqual:_renderedRow]) {
        return NO;
    }
    _renderedRow = [row copy];
    _numberLabel.text = row.numberText;
    [self resolveGutter];
    _artView.image = row.thumbnail ?: VibeFileTileImage(NO);
    _durationLabel.text = row.durationText;
    _titleLabel.text = row.title ?: @"";
    // Hidden rather than blank, so the title centres on its own.
    NSString *subtitle = row.subtitle;
    BOOL hidden = subtitle.length == 0;
    BOOL heightMoved = hidden != _subtitleLabel.isHidden;
    _subtitleLabel.text = subtitle ?: @"";
    _subtitleLabel.hidden = hidden;
    return heightMoved;
}

@end
