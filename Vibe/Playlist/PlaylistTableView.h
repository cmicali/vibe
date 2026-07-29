//
// Created by Christopher Micali on 7/25/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import <AppKit/AppKit.h>

@class AudioTrack;
@class EqualizerIndicatorView;

NS_ASSUME_NONNULL_BEGIN

// Everything structural about the playlist table in one place: the column
// set, row metrics, table/scroll-view configuration, the code-built cell
// views, and their text styling. The data source (PlaylistController)
// decides WHAT each cell shows and populates it via cellViewForColumn: and
// the formatting helpers below; nothing outside this file defines a column,
// a cell layout, or a cell font.
@interface PlaylistTableView : NSTableView

// Builds the table inside its enclosing scroll view (the table is the
// documentView). MainPlayerContentView only places the frame.
+ (NSScrollView *)scrollViewWithFrame:(NSRect)frame;

// Dequeue-or-build for the data source. The cell prototypes are created in
// code, so makeViewWithIdentifier: returns nil until one of each has been
// minted; cells reuse the column's identifier.
- (NSTableCellView *)cellViewForColumn:(NSTableColumn *)column;

// Cell text content in the owning column's styling — fonts, kerning, and
// colors live with the cell construction, not the data source.
+ (NSAttributedString *)numberCellString:(NSUInteger)number;
// Title + dimmed artist, or the single-line fallback when the tags are
// missing. Styling does not vary with the playing state — the playing row is
// marked by its equalizer indicator (and the row's neutral wash), not by
// recolored text.
+ (NSAttributedString *)titleCellStringForTrack:(AudioTrack *)track;
+ (NSAttributedString *)durationCellString:(NSString *)duration;

// NSTableCellView.imageView is typed NSImageView, so the equalizer view
// can't ride the built-in outlet; fetch it by class instead.
+ (nullable EqualizerIndicatorView *)equalizerViewInCell:(NSTableCellView *)view;

@end

NS_ASSUME_NONNULL_END
