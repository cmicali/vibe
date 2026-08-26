//
//  SettingsFormViews.m
//  Vibe
//

#import "SettingsFormViews.h"
#import "NSString+FormLabel.h"

static const CGFloat kRowPaddingH = 16;
static const CGFloat kRowPaddingV = 8;
static const CGFloat kRowMinHeight = 40;
static const CGFloat kRowTitleControlGap = 8;
static const CGFloat kCardCornerRadius = 10;
static const CGFloat kHeaderCardGap = 6;

// updateLayer resolves colors against the current appearance, and the
// appearance-change hook re-runs it, so both dynamic colors track a live
// light/dark flip.
@interface SettingsHairlineView : NSView
@end

@implementation SettingsHairlineView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.heightAnchor constraintEqualToConstant:1].active = YES;
    }
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = NSColor.separatorColor.CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

// The card: white in light mode with a hairline edge, a light wash over the
// window in dark — the System Settings pairing on each backdrop.
@interface SettingsCardView : NSView
@end

@implementation SettingsCardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return self;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.cornerRadius = kCardCornerRadius;
    BOOL dark = [[self.effectiveAppearance
            bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            isEqualToString:NSAppearanceNameDarkAqua];
    self.layer.backgroundColor = dark
            ? [NSColor colorWithWhite:1 alpha:0.06].CGColor
            : NSColor.whiteColor.CGColor;
    self.layer.borderWidth = dark ? 0 : 1;
    self.layer.borderColor = [NSColor colorWithWhite:0 alpha:0.07].CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

#pragma mark - Row

@implementation SettingsRowView {
    SettingsHairlineView *_separator;
}

+ (instancetype)rowWithTitle:(NSString *)title control:(NSView *)control {
    return [self rowWithTitle:title caption:nil controls:@[control]];
}

+ (instancetype)rowWithTitle:(NSString *)title caption:(NSString *)caption control:(NSView *)control {
    return [self rowWithTitle:title caption:caption controls:@[control]];
}

+ (instancetype)rowWithTitle:(NSString *)title controls:(NSArray<NSView *> *)controls {
    return [self rowWithTitle:title caption:nil controls:controls];
}

+ (instancetype)rowWithTitle:(nullable NSString *)title
                     caption:(nullable NSString *)caption
                    controls:(NSArray<NSView *> *)controls {
    SettingsRowView *row = [[self alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:kRowMinHeight].active = YES;

    NSStackView *cluster = [NSStackView stackViewWithViews:controls];
    cluster.spacing = kRowTitleControlGap;
    cluster.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:cluster];
    [NSLayoutConstraint activateConstraints:@[
        [cluster.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowPaddingH],
        [cluster.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        // A tall cluster (the color wells) grows the row past its minimum.
        [cluster.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:kRowPaddingV - 2],
    ]];

    if (title.length) {
        NSTextField *titleLabel = [NSTextField labelWithString:title.vibeFormLabel];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [row addSubview:titleLabel];
        row->_titleLabel = titleLabel;
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kRowPaddingH],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:cluster.leadingAnchor
                                                                constant:-kRowTitleControlGap],
        ]];
        if (caption.length) {
            NSTextField *captionLabel = [NSTextField wrappingLabelWithString:caption];
            captionLabel.selectable = NO;
            captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
            captionLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            captionLabel.textColor = NSColor.secondaryLabelColor;
            [row addSubview:captionLabel];
            row->_captionLabel = captionLabel;
            [NSLayoutConstraint activateConstraints:@[
                [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:kRowPaddingV],
                [captionLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
                [captionLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
                [captionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:cluster.leadingAnchor
                                                                      constant:-kRowTitleControlGap],
                [captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor
                                                                    constant:-kRowPaddingV],
            ]];
        }
        else {
            [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor].active = YES;
        }
    }
    return row;
}

+ (instancetype)rowWithContentView:(NSView *)contentView {
    SettingsRowView *row = [[self alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:contentView];
    [NSLayoutConstraint activateConstraints:@[
        [contentView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kRowPaddingH],
        [contentView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kRowPaddingH],
        [contentView.topAnchor constraintEqualToAnchor:row.topAnchor constant:kRowPaddingV + 2],
        [contentView.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-(kRowPaddingV + 2)],
    ]];
    return row;
}

- (void)setShowsTopSeparator:(BOOL)showsTopSeparator {
    if (showsTopSeparator == (_separator != nil)) {
        return;
    }
    if (!showsTopSeparator) {
        [_separator removeFromSuperview];
        _separator = nil;
        return;
    }
    _separator = [[SettingsHairlineView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_separator];
    [NSLayoutConstraint activateConstraints:@[
        [_separator.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kRowPaddingH],
        [_separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_separator.topAnchor constraintEqualToAnchor:self.topAnchor],
    ]];
}

- (BOOL)showsTopSeparator {
    return _separator != nil;
}

@end

#pragma mark - Section

@implementation SettingsSectionView

+ (instancetype)sectionWithRows:(NSArray<SettingsRowView *> *)rows {
    return [self sectionWithHeader:nil rows:rows];
}

+ (instancetype)sectionWithHeader:(NSString *)header rows:(NSArray<SettingsRowView *> *)rows {
    SettingsSectionView *section = [[self alloc] initWithFrame:NSZeroRect];
    section.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // The separator belongs to the row below it, so hiding a row (the custom
    // theme's color pairs) removes its separator with it and the stack closes
    // the gap.
    [rows enumerateObjectsUsingBlock:^(SettingsRowView *row, NSUInteger index, BOOL *stop) {
        row.showsTopSeparator = index > 0;
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }];

    SettingsCardView *card = [[SettingsCardView alloc] initWithFrame:NSZeroRect];
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
    [section addSubview:card];

    NSLayoutYAxisAnchor *cardTopAttachment = section.topAnchor;
    CGFloat cardTopGap = 0;
    if (header.length) {
        NSTextField *headerLabel = [NSTextField labelWithString:header.vibeFormLabel];
        headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        // Semibold primary at text size — the System Settings section heading.
        headerLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        headerLabel.textColor = NSColor.labelColor;
        [section addSubview:headerLabel];
        section->_headerLabel = headerLabel;
        [NSLayoutConstraint activateConstraints:@[
            [headerLabel.topAnchor constraintEqualToAnchor:section.topAnchor],
            [headerLabel.leadingAnchor constraintEqualToAnchor:section.leadingAnchor
                                                      constant:kRowPaddingH],
            [headerLabel.trailingAnchor constraintLessThanOrEqualToAnchor:section.trailingAnchor],
        ]];
        cardTopAttachment = headerLabel.bottomAnchor;
        cardTopGap = kHeaderCardGap;
    }
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cardTopAttachment constant:cardTopGap],
        [card.leadingAnchor constraintEqualToAnchor:section.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:section.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:section.bottomAnchor],
    ]];
    return section;
}

@end
