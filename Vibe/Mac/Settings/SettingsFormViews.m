//
//  SettingsFormViews.m
//  Vibe
//

#import "SettingsFormViews.h"
#import "NSView+DarkMode.h"
#import "NSString+FormLabel.h"

static const CGFloat kRowPaddingV = 8;
static const CGFloat kRowMinHeight = 40;
static const CGFloat kRowTitleControlGap = 8;
static const CGFloat kCardCornerRadius = 10;
static const CGFloat kHeaderCardGap = 6;
// The System Settings list row: 24 points, measured off the Sound pane's
// device table.
static const CGFloat kListRowHeight = 24;

// updateLayer resolves the side's color against the current appearance, and
// the appearance-change hook re-runs it, so a dynamic color tracks a live
// light/dark flip.
@implementation SettingsFillView

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
    self.layer.cornerRadius = _cornerRadius;
    self.layer.backgroundColor = (self.isDark ? _darkColor : _lightColor).CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

// The one hairline — along a card row's top edge, along a list row's bottom
// — starting at the row inset and running to the trailing edge.
static SettingsFillView *Hairline(NSView *in, BOOL atTop) {
    SettingsFillView *line = [[SettingsFillView alloc] initWithFrame:NSZeroRect];
    line.darkColor = NSColor.separatorColor;
    line.lightColor = NSColor.separatorColor;
    [in addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.heightAnchor constraintEqualToConstant:1],
        [line.leadingAnchor constraintEqualToAnchor:in.leadingAnchor constant:kSettingsRowInset],
        [line.trailingAnchor constraintEqualToAnchor:in.trailingAnchor],
        atTop ? [line.topAnchor constraintEqualToAnchor:in.topAnchor]
              : [line.bottomAnchor constraintEqualToAnchor:in.bottomAnchor],
    ]];
    return line;
}

@implementation SettingsAccentRowView

- (BOOL)isEmphasized {
    return YES;
}

@end

#pragma mark - Row

@implementation SettingsRowView {
    SettingsFillView *_separator;
    // The caption's layout, built on first use by setCaption: — the control
    // cluster it must clear, the title-centered constraint that holds while
    // there is no caption, and the caption's own constraints while there is.
    NSStackView *_cluster;
    NSLayoutConstraint *_titleCenteredConstraint;
    NSArray<NSLayoutConstraint *> *_captionConstraints;
}

- (BOOL)setCaption:(NSString *)caption {
    NSString *text = caption ?: @"";
    if (!_titleLabel) {
        return NO;
    }
    if (text.length == 0) {
        if (!_captionLabel || _captionLabel.hidden) {
            return NO;
        }
        _captionLabel.hidden = YES;
        [NSLayoutConstraint deactivateConstraints:_captionConstraints];
        _titleCenteredConstraint.active = YES;
        return YES;
    }
    if (!_captionLabel) {
        NSTextField *captionLabel = [NSTextField wrappingLabelWithString:text];
        captionLabel.selectable = NO;
        captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        captionLabel.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        captionLabel.textColor = NSColor.secondaryLabelColor;
        captionLabel.hidden = YES;
        [self addSubview:captionLabel];
        _captionLabel = captionLabel;
        _captionConstraints = @[
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:kRowPaddingV],
            [captionLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [captionLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [captionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_cluster.leadingAnchor
                                                                  constant:-kRowTitleControlGap],
            [captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor
                                                                constant:-kRowPaddingV],
        ];
    }
    BOOL changed = _captionLabel.hidden || ![_captionLabel.stringValue isEqualToString:text];
    _captionLabel.stringValue = text;
    if (_captionLabel.hidden) {
        _captionLabel.hidden = NO;
        _titleCenteredConstraint.active = NO;
        [NSLayoutConstraint activateConstraints:_captionConstraints];
    }
    return changed;
}

+ (instancetype)rowWithTitle:(NSString *)title control:(NSView *)control {
    return [self rowWithTitle:title caption:nil controls:@[control]];
}

- (void)setRowTitle:(NSString *)title {
    _titleLabel.stringValue = title.vibeFormLabel;
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
        [cluster.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-kSettingsRowInset],
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
            [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:kSettingsRowInset],
            [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:cluster.leadingAnchor
                                                                constant:-kRowTitleControlGap],
        ]];
        row->_cluster = cluster;
        // The two layouts the caption switches between: title centered alone,
        // or title pinned to the top with the caption beneath it.
        row->_titleCenteredConstraint = [titleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor];
        row->_titleCenteredConstraint.active = YES;
        [row setCaption:caption];
    }
    return row;
}

+ (instancetype)rowWithContentView:(NSView *)contentView {
    return [self rowFilledWith:@[contentView]
                        insets:NSEdgeInsetsMake(kRowPaddingV + 2, kSettingsRowInset,
                                                kRowPaddingV + 2, kSettingsRowInset)];
}

+ (instancetype)rowWithTableView:(NSTableView *)table rowCount:(NSUInteger)rowCount {
    table.headerView = nil;
    table.style = NSTableViewStyleFullWidth;
    table.rowHeight = kListRowHeight;
    table.intercellSpacing = NSZeroSize;
    table.backgroundColor = NSColor.clearColor;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = table;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    [scrollView.heightAnchor constraintEqualToConstant:rowCount * kListRowHeight].active = YES;
    // Sunk to the pane background — the card's lift undone. Light is the
    // pane's own white; dark takes the card one step back down, which lands
    // within a 255th of the backdrop for any window background near the
    // measured one (0.102, the card over it 0.129).
    SettingsFillView *backdrop = [[SettingsFillView alloc] initWithFrame:NSZeroRect];
    backdrop.darkColor = [NSColor colorWithWhite:0 alpha:0.21];
    backdrop.lightColor = NSColor.whiteColor;
    return [self rowFilledWith:@[backdrop, scrollView] insets:NSEdgeInsetsZero];
}

+ (NSTableCellView *)listCellWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                inTableView:(NSTableView *)table {
    NSTableCellView *cell = [table makeViewWithIdentifier:identifier owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
        // Under the row rather than the table's grid, which would rule the
        // empty rows below the last one too.
        Hairline(cell, NO);
    }
    return cell;
}

// Every view pinned to the row's four edges at the insets, stacked in order.
+ (instancetype)rowFilledWith:(NSArray<NSView *> *)views insets:(NSEdgeInsets)insets {
    SettingsRowView *row = [[self alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:insets.left],
            [view.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-insets.right],
            [view.topAnchor constraintEqualToAnchor:row.topAnchor constant:insets.top],
            [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-insets.bottom],
        ]];
    }
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
    _separator = Hairline(self, YES);
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

    // The card: one lift-step off the pane background in each direction,
    // borderless — the System Settings pairing, measured off its pixels: dark
    // cards sit ~7/255 above the background, light cards ~8/255 below the
    // white one the pane paints (SettingsPaneViewController).
    SettingsFillView *card = [[SettingsFillView alloc] initWithFrame:NSZeroRect];
    card.darkColor = [NSColor colorWithWhite:1 alpha:0.032];
    card.lightColor = [NSColor colorWithWhite:0 alpha:0.032];
    card.cornerRadius = kCardCornerRadius;
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
                                                      constant:kSettingsRowInset],
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
