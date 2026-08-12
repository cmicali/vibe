//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

// The waveform's geometry against the safe-area bottom — the same values
// PlayerViewController uses to anchor the transport above it on the overlay.
static const CGFloat kCellWaveformHeight = 180;
static const CGFloat kCellWaveformBottomInset = 190;

@implementation TrackPageCell {
    UIImageView        *_artView;
    UIVisualEffectView *_blurView;
    UILabel            *_artistLabel;
    UILabel            *_titleLabel;
    UILabel            *_fileInfoLabel;
}

+ (NSString *)reuseIdentifier {
    return @"TrackPageCell";
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIView *content = self.contentView;

        _artView = [[UIImageView alloc] init];
        _artView.contentMode = UIViewContentModeScaleAspectFill;
        _artView.clipsToBounds = YES;
        _artView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artView];

        _blurView = [[UIVisualEffectView alloc] initWithEffect:
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_blurView];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artistLabel];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        _titleLabel.numberOfLines = 2;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_titleLabel];

        _fileInfoLabel = [[UILabel alloc] init];
        _fileInfoLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _fileInfoLabel.textColor = [UIColor secondaryLabelColor];
        _fileInfoLabel.textAlignment = NSTextAlignmentRight;
        _fileInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_fileInfoLabel];

        _waveformView = [[WaveformScrubberView alloc] initWithFrame:CGRectZero];
        _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_waveformView];

        _elapsedLabel = [self makeTimeLabel];
        [content addSubview:_elapsedLabel];
        _remainingLabel = [self makeTimeLabel];
        _remainingLabel.textAlignment = NSTextAlignmentRight;
        [content addSubview:_remainingLabel];

        // Cells span the full screen, so their safe area is the screen's.
        UILayoutGuide *safe = content.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_artView.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_artView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_artView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_artView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_blurView.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_blurView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_blurView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_blurView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

            // The mac header's arrangement: artist small over the title on
            // the left, the codec corner right-aligned on the artist line.
            [_artistLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
            [_artistLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
            [_fileInfoLabel.firstBaselineAnchor constraintEqualToAnchor:_artistLabel.firstBaselineAnchor],
            [_fileInfoLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
            [_fileInfoLabel.leadingAnchor
                    constraintGreaterThanOrEqualToAnchor:_artistLabel.trailingAnchor constant:12],
            [_titleLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:2],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],

            [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeight],
            [_waveformView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                       constant:-kCellWaveformBottomInset],
            [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor constant:6],
            [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
            [_remainingLabel.topAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor],
            [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        ]];
    }
    return self;
}

- (UILabel *)makeTimeLabel {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = STR_LABEL_TIME_UNKNOWN;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

// A recycled cell must never show the previous track's waveform or times —
// the new page's load repopulates both.
- (void)prepareForReuse {
    [super prepareForReuse];
    [_waveformView prepareForWaveformLoad];
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
}

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(NSString *)fileInfo
                       art:(UIImage *)art {
    _titleLabel.text = title;
    _titleLabel.textColor = titleColor;
    _artistLabel.text = artist;
    _artistLabel.textColor = artistColor;
    _fileInfoLabel.text = fileInfo;
    _artView.image = art;
}

@end
