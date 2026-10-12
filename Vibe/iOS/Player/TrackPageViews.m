//
//  TrackPageViews.m
//  Vibe (iOS)
//

#import "TrackPageViews.h"

#import "VibeStrings.h"

void VibeConfigureTimeLabel(UILabel *label) {
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:16
                                                               weight:UIFontWeightRegular]];
    label.adjustsFontForContentSizeCategory = YES;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisVertical];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = STR_LABEL_TIME_UNKNOWN;
    label.translatesAutoresizingMaskIntoConstraints = NO;
}

@implementation TrackPageTimeControl {
    UILabel *_label;
    NSString *_text;
    NSTextAlignment _textAlignment;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _label = [[UILabel alloc] init];
        VibeConfigureTimeLabel(_label);
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_label.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
        ]];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = STR_SETTINGS_SECTION_TIME;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.text = STR_LABEL_TIME_UNKNOWN;
        __weak TrackPageTimeControl *weakSelf = self;
        [self registerForTraitChanges:@[UITraitPreferredContentSizeCategory.class]
                          withHandler:^(id<UITraitEnvironment> environment,
                                        UITraitCollection *previous) {
            [weakSelf invalidateIntrinsicContentSize];
        }];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    CGSize labelSize = _label.intrinsicContentSize;
    return CGSizeMake(MAX(44, labelSize.width), MAX(44, labelSize.height));
}

- (NSString *)text {
    return _text;
}

// The tick writes it three times a second, and an unchanged write would still
// invalidate the layout.
- (void)setText:(NSString *)text {
    if (text == _text || [text isEqualToString:_text]) {
        return;
    }
    _text = [text copy];
    _label.text = text;
    self.accessibilityValue = text;
    [self invalidateIntrinsicContentSize];
}

- (NSTextAlignment)textAlignment {
    return _textAlignment;
}

- (void)setTextAlignment:(NSTextAlignment)textAlignment {
    _textAlignment = textAlignment;
    _label.textAlignment = textAlignment;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _label.alpha = highlighted ? 0.55 : 1;
}
@end

@implementation TrackPageActionBarView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}
@end

// TRAP: the shadow path is restated from the card's OWN layout pass. The
// contentView's constraints size the card, so a label-band change resizes it
// without the cell's layoutSubviews running, and a path set there leaves a
// stale halo until a swipe recycles the cell.
@implementation TrackPageArtCardView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:kArtCornerRadius].CGPath;
}
@end
