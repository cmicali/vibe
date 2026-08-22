//
//  PlaylistTableView.h
//  Vibe
//

#import <AppKit/AppKit.h>

@class AudioTrack;
@class EqualizerIndicatorView;
@class LoadingIndicatorView;

NS_ASSUME_NONNULL_BEGIN

// The column identifiers, shared with the data source: they key the column
// set, the cell prototypes and the cell reuse queue, so a literal misspelled
// on either side would compile and quietly render an empty cell.
extern NSString *const kPlaylistColumnNumber;
extern NSString *const kPlaylistColumnArt;
extern NSString *const kPlaylistColumnTitle;
extern NSString *const kPlaylistColumnLength;

// Everything structural about the playlist table in one place: the column set,
// the row metrics, the table and scroll-view configuration, the code-built cell
// views and their text styling. The data source, PlaylistController, decides
// what each cell shows and populates it through cellViewForColumn: and the
// formatting helpers below. Nothing outside this file defines a column, a cell
// layout or a cell font.
@interface PlaylistTableView : NSTableView

// Builds the table inside its enclosing scroll view, where the table is the
// documentView. MainPlayerContentView only places the frame.
+ (NSScrollView *)scrollViewWithFrame:(NSRect)frame;

// Dequeue or build, for the data source. The cell prototypes are created in
// code, so makeViewWithIdentifier: returns nil until one of each has been
// minted, and cells reuse the column's identifier.
- (NSTableCellView *)cellViewForColumn:(NSTableColumn *)column;

// Cell text content in the owning column's styling. The fonts, kerning and
// colors live with the cell construction, not with the data source.
+ (NSAttributedString *)numberCellString:(NSUInteger)number;
// The title plus a dimmed artist, or the single-line fallback when the tags
// are missing. The styling does not vary with the playing state: the playing
// row is marked by its equalizer indicator, and by the row's neutral wash, not
// by recolored text.
+ (NSAttributedString *)titleCellStringForTrack:(AudioTrack *)track;
+ (NSAttributedString *)durationCellString:(NSString *)duration;
// The art cell's image: the track's own thumbnail, or the placeholder record
// sleeve when it has none. Which image stands in for nothing is a styling
// choice, so it lives here with the rest of them.
+ (NSImage *)artworkCellImage:(nullable NSImage *)thumbnail;

// NSTableCellView.imageView is typed as NSImageView, so the equalizer view
// cannot ride the built-in outlet. Fetch it by class instead.
+ (nullable EqualizerIndicatorView *)equalizerViewInCell:(NSTableCellView *)view;
+ (nullable LoadingIndicatorView *)loadingViewInCell:(NSTableCellView *)view;

@end

NS_ASSUME_NONNULL_END
