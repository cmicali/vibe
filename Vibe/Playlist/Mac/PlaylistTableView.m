//
//  PlaylistTableView.m
//  Vibe
//

#import "PlaylistTableView.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioTrack.h"
#import "Fonts.h"
#import "PlaylistCoverImageView.h"
#import "PlaylistTextCell.h"
#import "EqualizerIndicatorView.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"

// Also the scroll view's line scroll and the prototypes' height.
static const CGFloat kPlaylistRowHeight = 28;
static const CGFloat kArtworkCellBleed = 4;
static const CGFloat kEqualizerWidth = 16;
static const CGFloat kEqualizerHeight = 14;

NSString *const kPlaylistColumnNumber = @"numColumn";
NSString *const kPlaylistColumnArt = @"artColumn";
NSString *const kPlaylistColumnTitle = @"titleColumn";
NSString *const kPlaylistColumnLength = @"lengthColumn";

// Makes validateMenuItem: the protocol's method, not NSObject's deprecated
// informal one.
@interface PlaylistTableView () <NSMenuItemValidation>
@end

@implementation PlaylistTableView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.rowHeight = kPlaylistRowHeight;
        self.headerView = nil;
        self.allowsMultipleSelection = YES;
        self.allowsColumnReordering = NO;
        self.allowsColumnResizing = NO;
        self.allowsExpansionToolTips = YES;
        self.backgroundColor = [NSColor clearColor];
        self.focusRingType = NSFocusRingTypeNone;
        self.intercellSpacing = NSMakeSize(0, 0);
        self.columnAutoresizingStyle = NSTableViewSequentialColumnAutoresizingStyle;
        // Type-select would swallow the unmodified transport key equivalents
        // (Space, B, N) whenever the table had focus.
        self.allowsTypeSelect = NO;
        // Flush with the scroll view's edges, not the macOS 11 inset look.
        self.style = NSTableViewStyleFullWidth;

        struct {
            NSString *identifier;
            CGFloat width, minWidth, maxWidth;
        } columns[] = {
                {kPlaylistColumnNumber,  32,  32,  32},
                {kPlaylistColumnArt,     48,  48,  48},
                {kPlaylistColumnTitle,  552, 100, 10000},
                {kPlaylistColumnLength,  48,  48,  48},
        };
        for (size_t i = 0; i < sizeof(columns) / sizeof(columns[0]); i++) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columns[i].identifier];
            column.width = columns[i].width;
            column.minWidth = columns[i].minWidth;
            column.maxWidth = columns[i].maxWidth;
            column.resizingMask = NSTableColumnAutoresizingMask;
            [self addTableColumn:column];
        }
        [self applyColumnVisibility];
    }
    return self;
}

// The title column absorbs freed width through sequential autoresizing.
- (void)applyColumnVisibility {
    AppSettings *settings = AppSettings.sharedInstance;
    [self tableColumnWithIdentifier:kPlaylistColumnNumber].hidden = !settings.showPlaylistNumberColumn;
    [self tableColumnWithIdentifier:kPlaylistColumnArt].hidden = !settings.showPlaylistArtworkColumn;
    [self tableColumnWithIdentifier:kPlaylistColumnLength].hidden = !settings.showPlaylistDurationColumn;
}

+ (NSScrollView *)scrollViewWithFrame:(NSRect)frame {
    PlaylistTableView *table = [[PlaylistTableView alloc]
            initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.usesPredominantAxisScrolling = NO;
    scrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    scrollView.verticalLineScroll = kPlaylistRowHeight;
    scrollView.horizontalLineScroll = kPlaylistRowHeight;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.contentInsets = NSEdgeInsetsZero;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = table;
    [table sizeToFit];
    return scrollView;
}

#pragma mark - Cell construction

static NSDictionary *numColumnAttributes;
static NSDictionary *lengthColumnAttributes;
static NSDictionary *titleAttributes;
static NSDictionary *artistAttributes;
// Not dispatch_once: they carry the theme's fonts and colors, so the
// PlaylistAppearance effect invalidates them.
static BOOL cellAttributesBuilt;
static NSImage *defaultArtImage;

static void ensureCellAttributes(void) {
    if (!cellAttributesBuilt) {
        cellAttributesBuilt = YES;
        // TRAP: every column's paragraph style must truncate. An attributed
        // string's paragraph style beats the cell's lineBreakMode, and the
        // default wraps a long title into a clipped second line.
        NSMutableParagraphStyle *left = [[NSParagraphStyle new] mutableCopy];
        left.lineBreakMode = NSLineBreakByTruncatingTail;
        NSMutableParagraphStyle *right = [left mutableCopy];
        right.alignment = NSTextAlignmentRight;
        // The header's label colors, until the theme switches on a column's
        // own pair.
        AppTheme *theme = AppSettings.sharedInstance.currentTheme;
        defaultArtImage = theme.resolvedDefaultArtworkImage;
        NSColor *titleColor = [theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistTitle];
        NSColor *artistColor = [theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistArtist];
        numColumnAttributes = @{
                NSForegroundColorAttributeName:
                        [theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistNumber],
                NSKernAttributeName: @(-1.5),
                // Not the duration slot: the # column is row chrome, so it keeps
                // the built-in numbers font whatever face the theme picks.
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        lengthColumnAttributes = @{
                NSForegroundColorAttributeName:
                        [theme resolvedPlaylistColorForBase:kVibeThemeColorPlaylistDuration],
                NSKernAttributeName: @(-1.0),
                NSFontAttributeName:
                        [Fonts playlistDurationFont],
                NSParagraphStyleAttributeName: right,
        };
        titleAttributes = @{
                NSForegroundColorAttributeName: titleColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts playlistFont],
                NSParagraphStyleAttributeName: left,
        };
        artistAttributes = @{
                NSForegroundColorAttributeName: artistColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts playlistFont],
                NSParagraphStyleAttributeName: left,
        };
    }
}

+ (void)invalidateCellAttributes {
    cellAttributesBuilt = NO;
}

static NSTextField *makeCellTextField(NSRect frame) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    PlaylistTextCell *cell = [[PlaylistTextCell alloc] initTextCell:@""];
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
    field.cell = cell;
    field.editable = NO;
    field.selectable = NO;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    return field;
}

// Select All enables exactly while the table can honor it.
//
// TRAP: there is no super validateMenuItem:. It is a protocol method none of
// NSTableView, NSView or NSResponder implements, so calling it throws for any
// other nil-targeted action the table answers to (print:, deselectAll:).
// NSTableView does implement validateUserInterfaceItem:, so the rest goes
// there.
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(selectAll:)) {
        return self.allowsMultipleSelection;
    }
    return [super validateUserInterfaceItem:menuItem];
}

// Setting the identifier enters the prototype in the table's reuse queue.
- (NSTableCellView *)makeCellViewWithIdentifier:(NSString *)identifier width:(CGFloat)width {
    CGFloat rowHeight = self.rowHeight;
    NSTableCellView *view = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, rowHeight)];
    view.identifier = identifier;
    if ([identifier isEqualToString:kPlaylistColumnNumber]) {
        // A full-width table includes its leading row padding in the first
        // column rect, outside this cell. Center from the row edge to the
        // artwork bleed, then translate that position into cell coordinates.
        NSInteger column = [self columnWithIdentifier:kPlaylistColumnNumber];
        CGFloat columnWidth = NSWidth([self rectOfColumn:column]);
        CGFloat cellLeadingInset = columnWidth - width;
        CGFloat visibleGutterWidth = columnWidth - kArtworkCellBleed;
        CGFloat equalizerX = (visibleGutterWidth - kEqualizerWidth) / 2
                - cellLeadingInset;
        EqualizerIndicatorView *eqView = [[EqualizerIndicatorView alloc]
                initWithFrame:NSMakeRect(equalizerX,
                                         (rowHeight - kEqualizerHeight) / 2,
                                         kEqualizerWidth,
                                         kEqualizerHeight)];
        eqView.barColor = NSColor.whiteColor;
        eqView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [view addSubview:eqView];
        // The loading bar shares the equalizer's slot and its white.
        CGFloat loadingHeight = VibeLoadingIndicatorMetricsForStyle(
                VibeLoadingIndicatorStyleRow, kEqualizerWidth).height;
        LoadingIndicatorView *loadingView = [[LoadingIndicatorView alloc]
                initWithFrame:NSMakeRect(equalizerX,
                                         (rowHeight - loadingHeight) / 2,
                                         kEqualizerWidth,
                                         loadingHeight)];
        loadingView.barColor = NSColor.whiteColor;
        loadingView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [view addSubview:loadingView];
        NSTextField *field = makeCellTextField(NSMakeRect(-2, 0, 24, rowHeight));
        field.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [view addSubview:field];
        view.textField = field;
    }
    else if ([identifier isEqualToString:kPlaylistColumnArt]) {
        // Bleeds past the cell on every side, so artwork rows tile seamlessly.
        PlaylistCoverImageView *imageView = [[PlaylistCoverImageView alloc]
                initWithFrame:NSInsetRect(view.bounds, -kArtworkCellBleed,
                                          -kArtworkCellBleed)];
        imageView.imageScaling = NSImageScaleAxesIndependently;
        imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [view addSubview:imageView];
        view.imageView = imageView;
    }
    else if ([identifier isEqualToString:kPlaylistColumnTitle]) {
        NSTextField *field = makeCellTextField(NSMakeRect(6, 0, width - 10, rowHeight));
        [view addSubview:field];
        view.textField = field;
    }
    else if ([identifier isEqualToString:kPlaylistColumnLength]) {
        NSTextField *field = makeCellTextField(NSMakeRect(2, 0, width - 6, rowHeight));
        [view addSubview:field];
        view.textField = field;
    }
    return view;
}

- (NSTableCellView *)cellViewForColumn:(NSTableColumn *)column {
    NSTableCellView *view = [self makeViewWithIdentifier:column.identifier owner:self];
    if (!view) {
        view = [self makeCellViewWithIdentifier:column.identifier width:column.width];
    }
    if ([column.identifier isEqualToString:kPlaylistColumnArt]) {
        // With the number column hidden the art column leads the row, and its
        // rect gains the full-width leading padding outside the cell: bleed
        // across it so the cover stays flush with the row edge. Set on every
        // fetch because a reused cell outlives a visibility toggle.
        NSInteger index = [self columnWithIdentifier:kPlaylistColumnArt];
        CGFloat leadingBleed = MAX(kArtworkCellBleed, NSWidth([self rectOfColumn:index]) - column.width);
        view.imageView.frame = NSMakeRect(-leadingBleed, -kArtworkCellBleed,
                                          column.width + leadingBleed + kArtworkCellBleed,
                                          self.rowHeight + 2 * kArtworkCellBleed);
    }
    return view;
}

+ (EqualizerIndicatorView *)equalizerViewInCell:(NSTableCellView *)view {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[EqualizerIndicatorView class]]) {
            return (EqualizerIndicatorView *)subview;
        }
    }
    return nil;
}

+ (LoadingIndicatorView *)loadingViewInCell:(NSTableCellView *)view {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[LoadingIndicatorView class]]) {
            return (LoadingIndicatorView *)subview;
        }
    }
    return nil;
}

#pragma mark - Cell content

// A row index, not a quantity — a locale group separator past 1,000 tracks
// would widen the tabular-figure column.
+ (NSAttributedString *)numberCellString:(NSUInteger)number {
    ensureCellAttributes();
    return [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:VibeNotLocalized(@"%lu"), (unsigned long)number]
                                           attributes:numColumnAttributes];
}

+ (NSAttributedString *)titleCellStringForTrack:(AudioTrack *)track {
    ensureCellAttributes();
    NSString *artist = track.displayArtist;
    if (artist) {
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
                initWithString:[track.displayTitle stringByAppendingString:@" "]
                    attributes:titleAttributes];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:artist
                                                                  attributes:artistAttributes]];
        return s;
    }
    // The single line is still the TITLE, so it takes the title's colour.
    return [[NSAttributedString alloc] initWithString:track.displayTitle
                                           attributes:titleAttributes];
}

+ (NSAttributedString *)durationCellString:(NSString *)duration {
    ensureCellAttributes();
    return [[NSAttributedString alloc] initWithString:duration
                                           attributes:lengthColumnAttributes];
}

+ (NSImage *)artworkCellImage:(NSImage *)thumbnail {
    // Cached with the attributes: one pointer read per artless row on the
    // scroll path.
    ensureCellAttributes();
    return thumbnail ?: defaultArtImage;
}

@end
