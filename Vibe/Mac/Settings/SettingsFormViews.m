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
static const CGFloat kListHeaderHeight = 28;
// Full-width table cells supply the other six points of the Sound list inset.
static const CGFloat kListTextInset = 4;

// Sound settings reference, in its Display P3 color space: base, stripe, selection.
static NSColor *ListColor(NSUInteger shade) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        const CGFloat light[] = {247, 239, 223};
        const CGFloat dark[][3] = {{39, 41, 50}, {50, 52, 60}, {92, 94, 101}};
        return appearance.isDark
                ? [NSColor colorWithDisplayP3Red:dark[shade][0] / 255
                                          green:dark[shade][1] / 255 blue:dark[shade][2] / 255 alpha:1]
                : [NSColor colorWithSRGBRed:light[shade] / 255 green:light[shade] / 255
                                      blue:light[shade] / 255 alpha:1];
    }];
}

@interface SettingsAccentRowView ()
@property (nonatomic, strong) NSColor *listBackgroundColor;
@end

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

@implementation SettingsStackView
- (BOOL)isFlipped { return YES; }
@end

// Card-row divider, inset from the leading edge.
static SettingsFillView *Hairline(NSView *in) {
    SettingsFillView *line = [[SettingsFillView alloc] initWithFrame:NSZeroRect];
    line.darkColor = NSColor.separatorColor;
    line.lightColor = NSColor.separatorColor;
    [in addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [line.heightAnchor constraintEqualToConstant:1],
        [line.leadingAnchor constraintEqualToAnchor:in.leadingAnchor constant:kSettingsRowInset],
        [line.trailingAnchor constraintEqualToAnchor:in.trailingAnchor],
        [line.topAnchor constraintEqualToAnchor:in.topAnchor],
    ]];
    return line;
}

@implementation SettingsAccentRowView

- (BOOL)isEmphasized {
    return self.listBackgroundColor == nil;
}

- (NSBackgroundStyle)interiorBackgroundStyle {
    return self.listBackgroundColor ? NSBackgroundStyleNormal : [super interiorBackgroundStyle];
}

- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (!self.listBackgroundColor) {
        [super drawBackgroundInRect:dirtyRect];
        return;
    }
    [self.listBackgroundColor setFill];
    NSRectFill(self.bounds);
}

- (void)drawSelectionInRect:(NSRect)dirtyRect {
    if (!self.listBackgroundColor) {
        [super drawSelectionInRect:dirtyRect];
        return;
    }
    [ListColor(2) setFill];
    NSRectFill(self.bounds);
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}

@end

#pragma mark - Row

@implementation SettingsRowView {
    SettingsFillView *_separator;
    NSTableView *_listTable;
    SettingsFillView *_listHeader;
    // The caption's layout, built on first use by setCaption: — the control
    // cluster it must clear, the title-centered constraint that holds while
    // there is no caption, and the caption's own constraints while there is.
    NSStackView *_cluster;
    NSLayoutConstraint *_titleCenteredConstraint;
    NSArray<NSLayoutConstraint *> *_captionConstraints;
}

// AppKit owns a control's internal subviews, so the walk stops at a control.
static void CollectControls(NSView *view, NSMutableArray<NSControl *> *controls) {
    if ([view isKindOfClass:NSControl.class]) {
        [controls addObject:(NSControl *)view];
        return;
    }
    for (NSView *child in view.subviews) CollectControls(child, controls);
}

// A caption's height for text at width, through a copy of the label's own
// cell so the metrics are the label's and the label itself is left alone.
static CGFloat SettingsCaptionHeight(NSTextField *label, NSString *text, CGFloat width) {
    NSCell *cell = [label.cell copy];
    cell.stringValue = text;
    return [cell cellSizeForBounds:NSMakeRect(0, 0, width, CGFLOAT_MAX)].height;
}

+ (SettingsRowView *)rowContaining:(NSView *)view {
    for (NSView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:self]) return (SettingsRowView *)ancestor;
    }
    return nil;
}

+ (void)setControl:(NSControl *)control enabled:(BOOL)enabled {
    control.enabled = enabled;
    SettingsRowView *row = [self rowContaining:control];
    if (row) [row refreshControlAppearance];
    else control.alphaValue = enabled ? 1 : 0.5;
}

+ (void)setControlsInView:(NSView *)view enabled:(BOOL)enabled {
    NSMutableArray<NSControl *> *controls = [NSMutableArray array];
    CollectControls(view, controls);
    NSMutableSet<SettingsRowView *> *rows = [NSMutableSet set];
    for (NSControl *control in controls) {
        control.enabled = enabled;
        if (!enabled && [control isKindOfClass:NSColorWell.class]) [(NSColorWell *)control deactivate];
        SettingsRowView *row = [self rowContaining:control];
        if (row) [rows addObject:row];
        else control.alphaValue = enabled ? 1 : 0.5;
    }
    for (SettingsRowView *row in rows) [row refreshControlAppearance];
}

- (void)refreshControlAppearance {
    NSMutableArray<NSControl *> *controls = [NSMutableArray array];
    CollectControls(self, controls);
    BOOL hasControl = NO, enabled = NO;
    for (NSControl *control in controls) {
        if ([control isKindOfClass:NSTextField.class] && ![(NSTextField *)control isEditable]) continue;
        control.alphaValue = control.enabled ? 1 : 0.5;
        if (!control.hidden) {
            hasControl = YES;
            enabled |= control.enabled;
        }
    }
    for (NSControl *control in controls) {
        if ([control isKindOfClass:NSTextField.class] && ![(NSTextField *)control isEditable]) {
            control.alphaValue = !hasControl || enabled ? 1 : 0.5;
        }
    }
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
    BOOL changed = _captionLabel.hidden
            || (![_captionLabel.stringValue isEqualToString:text]
                && [self captionHeightChangesFrom:_captionLabel.stringValue to:text]);
    _captionLabel.stringValue = text;
    if (_captionLabel.hidden) {
        _captionLabel.hidden = NO;
        _titleCenteredConstraint.active = NO;
        [NSLayoutConstraint activateConstraints:_captionConstraints];
    }
    [self refreshControlAppearance];
    return changed;
}

// Every caller remeasures the pane on YES, a full Auto Layout solve, and a
// status caption rewritten during playback keeps its line count. So the
// answer is measured on this one label at the width it wraps at, not assumed
// from the text. Before the first layout there is no width, and any change
// counts.
- (BOOL)captionHeightChangesFrom:(NSString *)previous to:(NSString *)text {
    CGFloat width = NSMinX(_cluster.frame) - kRowTitleControlGap - NSMinX(_titleLabel.frame);
    if (width <= 0 || NSIsEmptyRect(_captionLabel.frame)) {
        return YES;
    }
    return SettingsCaptionHeight(_captionLabel, previous, width)
            != SettingsCaptionHeight(_captionLabel, text, width);
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
    [row refreshControlAppearance];
    return row;
}

+ (instancetype)rowWithContentView:(NSView *)contentView {
    return [self rowFilledWith:@[contentView]
                        insets:NSEdgeInsetsMake(kRowPaddingV + 2, kSettingsRowInset,
                                                kRowPaddingV + 2, kSettingsRowInset)];
}

+ (NSTableView *)listTableWithColumnIdentifiers:(NSArray<NSUserInterfaceItemIdentifier> *)identifiers
                                     delegate:(id<NSTableViewDelegate, NSTableViewDataSource>)delegate {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = delegate;
    table.delegate = delegate;
    table.allowsColumnReordering = NO;
    table.allowsColumnResizing = NO;
    for (NSUserInterfaceItemIdentifier identifier in identifiers) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
        if ([identifier isEqualToString:@"icon"]) {
            column.title = @"";
            column.width = column.minWidth = column.maxWidth = 36;
            column.resizingMask = NSTableColumnNoResizing;
        }
        [table addTableColumn:column];
    }
    return table;
}

+ (instancetype)rowWithTableView:(NSTableView *)table rowCount:(NSUInteger)rowCount {
    BOOL hasHeader = table.tableColumns.count > 1;
    table.headerView = nil;
    table.style = NSTableViewStyleFullWidth;
    table.rowHeight = kListRowHeight;
    table.intercellSpacing = NSZeroSize;
    table.gridStyleMask = NSTableViewGridNone;
    table.backgroundColor = ListColor(0);
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = table;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.backgroundColor = ListColor(0);
    [scrollView.heightAnchor constraintEqualToConstant:rowCount * kListRowHeight].active = YES;
    SettingsRowView *row = [self rowFilledWith:@[scrollView]
                                      insets:NSEdgeInsetsMake(hasHeader ? kListHeaderHeight : 0, 0, 0, 0)];
    row.wantsLayer = YES;
    row.layer.cornerRadius = kCardCornerRadius;
    row.layer.masksToBounds = YES;
    row->_listTable = table;
    if (hasHeader) {
        SettingsFillView *header = [[SettingsFillView alloc] initWithFrame:NSZeroRect];
        header.darkColor = header.lightColor = ListColor(1);
        for (NSTableColumn *column in table.tableColumns) {
            NSTextField *label = [NSTextField labelWithString:column.title];
            label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
            label.textColor = NSColor.labelColor;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            [header addSubview:label];
        }
        [row addSubview:header];
        [NSLayoutConstraint activateConstraints:@[
            [header.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
            [header.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [header.topAnchor constraintEqualToAnchor:row.topAnchor],
            [header.heightAnchor constraintEqualToConstant:kListHeaderHeight],
        ]];
        row->_listHeader = header;
    }
    return row;
}

- (void)layout {
    [super layout];
    for (NSUInteger column = 0; column < _listHeader.subviews.count; column++) {
        NSTextField *label = (NSTextField *)_listHeader.subviews[column];
        NSRect cell = _listTable.numberOfRows
                ? [_listTable frameOfCellAtColumn:(NSInteger)column row:0]
                : [_listTable rectOfColumn:(NSInteger)column];
        cell = [_listTable convertRect:cell toView:_listHeader];
        CGFloat height = label.intrinsicContentSize.height;
        // A label frame includes two points before its text; Auto Layout uses
        // its alignment rect for row text, giving the reference's 8/10-point insets.
        label.frame = NSMakeRect(NSMinX(cell),
                (kListHeaderHeight - height) / 2, NSWidth(cell), height);
    }
}

+ (NSTableRowView *)listRowViewForRow:(NSInteger)row {
    SettingsAccentRowView *view = [SettingsAccentRowView new];
    view.listBackgroundColor = ListColor((NSUInteger)row % 2);
    return view;
}

+ (NSTableCellView *)listCellWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                inTableView:(NSTableView *)table
                              imagePosition:(NSCellImagePosition)imagePosition {
    NSTableCellView *cell = [table makeViewWithIdentifier:identifier owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
        NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
        CGFloat inset = kListTextInset;
        if (imagePosition != NSNoImage) {
            NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            if (imagePosition == NSImageOnly) {
                icon.symbolConfiguration =
                        [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightBold];
            }
            [cell addSubview:icon];
            cell.imageView = icon;
            [NSLayoutConstraint activateConstraints:@[
                imagePosition == NSImageOnly
                        ? [icon.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor]
                        : [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:kListTextInset],
                [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:16],
                [icon.heightAnchor constraintEqualToConstant:16],
            ]];
            leading = icon.trailingAnchor;
            inset = 6;
        }
        if (imagePosition != NSImageOnly) {
            NSTextField *label = [NSTextField labelWithString:@""];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.textColor = NSColor.labelColor;
            label.lineBreakMode = NSLineBreakByTruncatingTail;
            [cell addSubview:label];
            cell.textField = label;
            [NSLayoutConstraint activateConstraints:@[
                [label.leadingAnchor constraintEqualToAnchor:leading constant:inset],
                [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-kListTextInset],
                [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            ]];
        }
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
    [row refreshControlAppearance];
    return row;
}

- (void)setShowsTopSeparator:(BOOL)showsTopSeparator {
    if (_listTable) {
        return;
    }
    if (showsTopSeparator == (_separator != nil)) {
        return;
    }
    if (!showsTopSeparator) {
        [_separator removeFromSuperview];
        _separator = nil;
        return;
    }
    _separator = Hairline(self);
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
