//
//  PlaylistTableView.m
//  Vibe
//

#import "PlaylistTableView.h"
#import "AppSettings.h"
#import "AudioTrack.h"
#import "Fonts.h"
#import "PlaylistCoverImageView.h"
#import "PlaylistTextCell.h"
#import "EqualizerIndicatorView.h"
#import "LoadingIndicatorMath.h"
#import "LoadingIndicatorView.h"

// This is also the scroll view's line scroll and the cell prototypes' height.
static const CGFloat kPlaylistRowHeight = 28;
static const CGFloat kArtworkCellBleed = 4;
static const CGFloat kEqualizerWidth = 16;
static const CGFloat kEqualizerHeight = 14;

NSString *const kPlaylistColumnNumber = @"numColumn";
NSString *const kPlaylistColumnArt = @"artColumn";
NSString *const kPlaylistColumnTitle = @"titleColumn";
NSString *const kPlaylistColumnLength = @"lengthColumn";

// The conformance is what makes validateMenuItem: below the protocol's method
// rather than NSObject's deprecated informal one. It is declared here, not in
// the header, because nothing outside this file calls it — the same pattern as
// PlaylistController and MainPlayerController+Menus.
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
        // Type-select would swallow plain keystrokes, jumping to the first row
        // starting with that letter, before the menu saw them. That would
        // break the unmodified transport key equivalents — Space, B and N —
        // whenever the table had focus.
        self.allowsTypeSelect = NO;
        // Opt out of the macOS 11 inset look: the selection highlight and the
        // row content should run flush with the scroll view's left and right
        // edges.
        self.style = NSTableViewStyleFullWidth;

        // The column set. Cell construction, in makeCellViewWithIdentifier:,
        // keys off these same identifiers, and the cells reuse them.
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
        [self applyThemedColumnVisibility];
    }
    return self;
}

// The theme's two optional columns. The title column absorbs the freed width
// through the sequential autoresizing the table already uses.
- (void)applyThemedColumnVisibility {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    [self tableColumnWithIdentifier:kPlaylistColumnArt].hidden = !theme.showPlaylistArtwork;
    [self tableColumnWithIdentifier:kPlaylistColumnLength].hidden = !theme.showPlaylistDuration;
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
// Not dispatch_once: the attributes carry the theme's fonts and label
// colors, so the PlaylistAppearance effect invalidates and the next cell
// rebuilds — the invalidate-on-effect idiom, in place of cached-forever.
static BOOL cellAttributesBuilt;

static void ensureCellAttributes(void) {
    if (!cellAttributesBuilt) {
        cellAttributesBuilt = YES;
        // Every column's paragraph style truncates. These strings are set as
        // attributed values, and an attributed string's paragraph style beats
        // the cell's own line break mode, so leaving the style out left the
        // default, which is wrapping, and a long title broke the row's layout.
        NSMutableParagraphStyle *left = [[NSParagraphStyle new] mutableCopy];
        left.lineBreakMode = NSLineBreakByTruncatingTail;
        NSMutableParagraphStyle *right = [left mutableCopy];
        right.alignment = NSTextAlignmentRight;
        // One label-color set spans the header and the playlist: titleColor
        // is every title, artistColor every secondary line — here the artist
        // run and both numeric columns, which already share its fallback.
        AppTheme *theme = AppSettings.sharedInstance.currentTheme;
        NSColor *titleColor = theme.resolvedTitleColor;
        NSColor *artistColor = theme.resolvedArtistColor;
        numColumnAttributes = @{
                NSForegroundColorAttributeName: artistColor,
                NSKernAttributeName: @(-1.5),
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        lengthColumnAttributes = @{
                NSForegroundColorAttributeName: artistColor,
                NSKernAttributeName: @(-1.0),
                NSFontAttributeName:
                        [Fonts playlistDurationFont:kVibeThemePlaylistDurationFontBaseSize],
                NSParagraphStyleAttributeName: right,
        };
        titleAttributes = @{
                NSForegroundColorAttributeName: titleColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts playlistFont:kVibeThemePlaylistFontBaseSize],
                NSParagraphStyleAttributeName: left,
        };
        artistAttributes = @{
                NSForegroundColorAttributeName: artistColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts playlistFont:kVibeThemePlaylistFontBaseSize],
                NSParagraphStyleAttributeName: left,
        };
    }
}

+ (void)invalidateCellAttributes {
    cellAttributesBuilt = NO;
}

// A static text field for a table cell, backed by the vertically centering
// PlaylistTextCell.
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

// Edit > Select All is nil-targeted, so the responder chain hands it to
// whichever table has focus, and NSTableView answers to selectAll: whether or
// not it can act on it. Tied to the capability rather than hardcoded YES, so
// the item enables exactly while the table can honor it — it could not when
// the table was single-selection, and an enabled item that does nothing when
// clicked is worse than a disabled one.
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(selectAll:)) {
        return self.allowsMultipleSelection;
    }
    return [super validateMenuItem:menuItem];
}

// Builds the table's cell prototypes in code. makeViewWithIdentifier returns
// nil until a view of that identifier has been created once, and setting the
// identifier here puts these into the table's normal reuse queue.
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
        // The loading bar shares the equalizer's slot: same width and X, a
        // small round-ended pill, vertically centred. White for the same
        // reason the bars are — this gutter never inherits artwork colour.
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
        // It bleeds past the cell on every side, so artwork rows tile
        // seamlessly.
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
    // No pair: displayTitle already carries everything known about the name,
    // so it is still the TITLE and draws in the title's colour. It used to
    // draw in artistAttributes, which is the same font a step dimmer: a file
    // tagged with a title but no artist then read as an untagged filename row,
    // and the mac disagreed with iOS, which draws this same value in
    // labelColor.
    return [[NSAttributedString alloc] initWithString:track.displayTitle
                                           attributes:titleAttributes];
}

+ (NSAttributedString *)durationCellString:(NSString *)duration {
    ensureCellAttributes();
    return [[NSAttributedString alloc] initWithString:duration
                                           attributes:lengthColumnAttributes];
}

+ (NSImage *)artworkCellImage:(NSImage *)thumbnail {
    return thumbnail ?: [NSImage imageNamed:@"record-bg"];
}

@end
