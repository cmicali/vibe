//
// Created by Christopher Micali on 7/25/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "PlaylistTableView.h"
#import "AudioTrack.h"
#import "Fonts.h"
#import "PlaylistCoverImageView.h"
#import "PlaylistTextCell.h"
#import "EqualizerIndicatorView.h"

// Also the scroll view's line scroll and the cell prototypes' height.
static const CGFloat kPlaylistRowHeight = 28;

@implementation PlaylistTableView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.rowHeight = kPlaylistRowHeight;
        self.headerView = nil;
        self.allowsMultipleSelection = NO;
        self.allowsColumnReordering = NO;
        self.allowsColumnResizing = NO;
        self.allowsExpansionToolTips = YES;
        self.backgroundColor = [NSColor clearColor];
        self.focusRingType = NSFocusRingTypeNone;
        self.intercellSpacing = NSMakeSize(0, 0);
        self.columnAutoresizingStyle = NSTableViewSequentialColumnAutoresizingStyle;
        // Type-select would swallow plain keystrokes (jump to the first row
        // starting with that letter) before the menu sees them, breaking the
        // unmodified transport key equivalents (Space/B/N) whenever the table
        // has focus.
        self.allowsTypeSelect = NO;
        // Opt out of the macOS 11+ inset look; we want the selection highlight
        // and row content flush with the scroll view's left/right edges.
        self.style = NSTableViewStyleFullWidth;

        // The column set. Cell construction (makeCellViewWithIdentifier:)
        // keys off these same identifiers — the cells reuse them.
        struct {
            NSString *identifier;
            CGFloat width, minWidth, maxWidth;
        } columns[] = {
                {@"numColumn",     32,  32,  32},
                {@"artColumn",     48,  48,  48},
                {@"titleColumn",  552, 100, 10000},
                {@"lengthColumn",  48,  48,  48},
        };
        for (size_t i = 0; i < sizeof(columns) / sizeof(columns[0]); i++) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columns[i].identifier];
            column.width = columns[i].width;
            column.minWidth = columns[i].minWidth;
            column.maxWidth = columns[i].maxWidth;
            column.resizingMask = NSTableColumnAutoresizingMask;
            [self addTableColumn:column];
        }
    }
    return self;
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

static void ensureCellAttributes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableParagraphStyle *right = [[NSParagraphStyle new] mutableCopy];
        right.alignment = NSTextAlignmentRight;
        numColumnAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-1.5),
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        lengthColumnAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-1.0),
                NSFontAttributeName: [Fonts fontForNumbers:12],
                NSParagraphStyleAttributeName: right,
        };
        titleAttributes = @{
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts font:14],
        };
        artistAttributes = @{
                NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
                NSKernAttributeName: @(-0.3),
                NSFontAttributeName: [Fonts font:14],
        };
    });
}

// Static text field for a table cell, backed by the vertically-centering
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

// Builds the table's cell prototypes in code. makeViewWithIdentifier returns
// nil until a view of that identifier has been created once; setting the
// identifier here puts these into the table's normal reuse queue.
- (NSTableCellView *)makeCellViewWithIdentifier:(NSString *)identifier width:(CGFloat)width {
    CGFloat rowHeight = self.rowHeight;
    NSTableCellView *view = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, rowHeight)];
    view.identifier = identifier;
    if ([identifier isEqualToString:@"numColumn"]) {
        EqualizerIndicatorView *eqView = [[EqualizerIndicatorView alloc] initWithFrame:NSMakeRect(8, (rowHeight - 14) / 2, 16, 14)];
        eqView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [view addSubview:eqView];
        NSTextField *field = makeCellTextField(NSMakeRect(-2, 0, 24, rowHeight));
        field.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        [view addSubview:field];
        view.textField = field;
    }
    else if ([identifier isEqualToString:@"artColumn"]) {
        // Bleeds past the cell on every side so artwork rows tile seamlessly.
        PlaylistCoverImageView *imageView = [[PlaylistCoverImageView alloc] initWithFrame:NSInsetRect(view.bounds, -4, -4)];
        imageView.imageScaling = NSImageScaleAxesIndependently;
        imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [view addSubview:imageView];
        view.imageView = imageView;
    }
    else if ([identifier isEqualToString:@"titleColumn"]) {
        NSTextField *field = makeCellTextField(NSMakeRect(6, 0, width - 10, rowHeight));
        [view addSubview:field];
        view.textField = field;
    }
    else if ([identifier isEqualToString:@"lengthColumn"]) {
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

#pragma mark - Cell content

+ (NSAttributedString *)numberCellString:(NSUInteger)number {
    ensureCellAttributes();
    return [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%lu", (unsigned long)number]
                                           attributes:numColumnAttributes];
}

+ (NSAttributedString *)titleCellStringForTrack:(AudioTrack *)track {
    ensureCellAttributes();
    if (track.hasArtistAndTitle) {
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:[track.title stringByAppendingString:@" "]
                                                                              attributes:titleAttributes];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:track.artist
                                                                  attributes:artistAttributes]];
        return s;
    }
    return [[NSAttributedString alloc] initWithString:track.singleLineTitle
                                           attributes:artistAttributes];
}

+ (NSAttributedString *)durationCellString:(NSString *)duration {
    ensureCellAttributes();
    return [[NSAttributedString alloc] initWithString:duration
                                           attributes:lengthColumnAttributes];
}

@end
