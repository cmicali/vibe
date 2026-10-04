//
//  MiniPlayerView.m
//  Vibe (iOS)
//

#import "MiniPlayerView.h"

#import "AudioTrack.h"
#import "VibeStrings.h"

// TRAP: the strip is 48pt, not negotiable. UITabAccessory frames its content
// at a fixed system height and ignores intrinsicContentSize and height
// constraints, without logging a conflict. A taller strip means giving up the
// accessory: Liquid Glass, inline collapse and the automatic safe-area inset.
// No playhead bar: one fits 48pt only by crowding the art and labels.
static const CGFloat kArtSide = 38;
// A big target with a small glyph.
static const CGFloat kControlSide = 44;
static const CGFloat kGlyphPointSize = 19;

@interface MiniPlayerView () <UIGestureRecognizerDelegate>
@end

@implementation MiniPlayerView {
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UIButton    *_expandButton;
    UIButton    *_playPauseButton;
    UIButton    *_nextButton;
    BOOL        _playing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self build];
    }
    return self;
}

- (void)build {
    self.backgroundColor = UIColor.clearColor;

    _expandButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _expandButton.accessibilityLabel = STR_SETTINGS_NOW_PLAYING_SECTION;
    [_expandButton addTarget:self action:@selector(expandTapped)
            forControlEvents:UIControlEventTouchUpInside];
    _expandButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_expandButton];

    _artView = [[UIImageView alloc] init];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.isAccessibilityElement = NO;
    _artView.layer.cornerRadius = 6;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_artView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.isAccessibilityElement = NO;
    _titleLabel.maximumContentSizeCategory = UIContentSizeCategoryExtraExtraExtraLarge;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _artistLabel.adjustsFontForContentSizeCategory = YES;
    _artistLabel.isAccessibilityElement = NO;
    _artistLabel.maximumContentSizeCategory = UIContentSizeCategoryExtraExtraExtraLarge;
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentLeading;
    // Negative: a UILabel's height carries its font's leading.
    labels.spacing = -3;
    labels.userInteractionEnabled = NO;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:labels];

    // Must match _playing's initial NO: setPlaying: skips an unchanged value.
    _playPauseButton = [self controlWithSymbol:@"play.fill" action:@selector(playPauseTapped)];
    _playPauseButton.accessibilityLabel = STR_TRANSPORT_PLAY;
    // The mac's glyph.
    _nextButton = [self controlWithSymbol:@"forward.end.fill" action:@selector(nextTapped)];
    _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;

    UISwipeGestureRecognizer *swipe =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(expandTapped)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    swipe.delegate = self;
    [self addGestureRecognizer:swipe];

    // TRAP: the row's designated give. On device (never the simulator) the
    // accessory container reports width ZERO on at least one pass; the rest of
    // the row is required and needs 162pt, so without a give UIKit breaks a
    // constraint and logs it. Any new required constraint across the row
    // reopens this.
    NSLayoutConstraint *artLeading =
            [_artView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12];
    artLeading.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        artLeading,
        [_artView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_artView.widthAnchor constraintEqualToConstant:kArtSide],
        [_artView.heightAnchor constraintEqualToConstant:kArtSide],

        [_expandButton.leadingAnchor constraintEqualToAnchor:_artView.leadingAnchor],
        [_expandButton.trailingAnchor constraintEqualToAnchor:_playPauseButton.leadingAnchor],
        [_expandButton.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_expandButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [labels.leadingAnchor constraintEqualToAnchor:_artView.trailingAnchor constant:10],
        [labels.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],

        [_nextButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_nextButton.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [_nextButton.widthAnchor constraintEqualToConstant:kControlSide],
        [_nextButton.heightAnchor constraintEqualToConstant:kControlSide],

        [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor],
        [_playPauseButton.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [_playPauseButton.widthAnchor constraintEqualToConstant:kControlSide],
        [_playPauseButton.heightAnchor constraintEqualToConstant:kControlSide],
    ]];

    // Inline beside the tab bar there is no room for two lines.
    __weak MiniPlayerView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitTabAccessoryEnvironment.class,
                                    UITraitPreferredContentSizeCategory.class]
                      withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
        [weakSelf applyAccessoryEnvironment];
    }];
    [self applyAccessoryEnvironment];
}

- (UIButton *)controlWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.image = [UIImage systemImageNamed:symbol
                            withConfiguration:[UIImageSymbolConfiguration
                                    configurationWithPointSize:kGlyphPointSize]];
    config.baseForegroundColor = UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:button];
    return button;
}

- (void)applyAccessoryEnvironment {
    BOOL inline_ = self.traitCollection.tabAccessoryEnvironment == UITabAccessoryEnvironmentInline;
    BOOL accessibilitySize = UIContentSizeCategoryIsAccessibilityCategory(
            self.traitCollection.preferredContentSizeCategory);
    _artistLabel.hidden = inline_ || accessibilitySize || _artistLabel.text.length == 0;
}

#pragma mark - Rendering

- (void)renderTrack:(AudioTrack *)track {
    _titleLabel.text = track.displayTitle ?: @"";
    NSString *artist = track.displayArtist;
    _artistLabel.text = artist ?: @"";
    _artView.image = track.cachedThumbnail ?: [UIImage imageNamed:@"record-bg"];
    _expandButton.accessibilityValue = track.displayTitle;
    [self applyAccessoryEnvironment];
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) {
        return;
    }
    _playing = playing;
    UIButtonConfiguration *config = _playPauseButton.configuration;
    config.image = [UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")
                           withConfiguration:[UIImageSymbolConfiguration
                                   configurationWithPointSize:kGlyphPointSize]];
    _playPauseButton.configuration = config;
    _playPauseButton.accessibilityLabel = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
}

#pragma mark - Actions

- (void)expandTapped {
    [self.delegate miniPlayerViewDidRequestExpand:self];
}

- (void)playPauseTapped {
    [self.delegate miniPlayerViewDidTapPlayPause:self];
}

- (void)nextTapped {
    [self.delegate miniPlayerViewDidTapNext:self];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != self; view = view.superview) {
        if (view == _expandButton) {
            return YES;
        }
        if ([view isKindOfClass:UIControl.class]) {
            return NO;
        }
    }
    return YES;
}

@end
