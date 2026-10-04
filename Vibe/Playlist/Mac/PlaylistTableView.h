//
//  PlaylistTableView.h
//  Vibe
//

#import <AppKit/AppKit.h>

@class AudioTrack;
@class EqualizerIndicatorView;
@class LoadingIndicatorView;

NS_ASSUME_NONNULL_BEGIN

// Shared with the data source: they key the column set, the prototypes and
// the reuse queue, so a misspelled literal compiles and renders an empty cell.
extern NSString *const kPlaylistColumnNumber;
extern NSString *const kPlaylistColumnArt;
extern NSString *const kPlaylistColumnTitle;
extern NSString *const kPlaylistColumnLength;

// Everything structural about the playlist table: columns, row metrics, the
// scroll view, the code-built cells and their styling. PlaylistController
// decides content alone. Nothing outside this file defines a column, a cell
// layout or a cell font.
@interface PlaylistTableView : NSTableView

// The PlaylistAppearance effect's hook; the caller reloads the table.
+ (void)invalidateCellAttributes;

// Applies the three optional columns (number, artwork, duration) from AppSettings.
- (void)applyColumnVisibility;

// The table inside its scroll view; MainPlayerContentView only places it.
+ (NSScrollView *)scrollViewWithFrame:(NSRect)frame;

// Dequeue or build: the prototypes are code-built, so makeViewWithIdentifier:
// answers nil until one of each is minted.
- (NSTableCellView *)cellViewForColumn:(NSTableColumn *)column;

+ (NSAttributedString *)numberCellString:(NSUInteger)number;
// The title plus a dimmed artist, or the single-line fallback. Never varies
// with the playing state: the equalizer and the row wash are the marking.
+ (NSAttributedString *)titleCellStringForTrack:(AudioTrack *)track;
+ (NSAttributedString *)durationCellString:(NSString *)duration;
// The thumbnail, or the theme's placeholder sleeve.
+ (NSImage *)artworkCellImage:(nullable NSImage *)thumbnail;

// By class: neither view fits NSTableCellView's typed outlets.
+ (nullable EqualizerIndicatorView *)equalizerViewInCell:(NSTableCellView *)view;
+ (nullable LoadingIndicatorView *)loadingViewInCell:(NSTableCellView *)view;

@end

NS_ASSUME_NONNULL_END
