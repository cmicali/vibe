//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Replaces the system accent-blue selection fill with the theme's selected-row
// color, and marks the playing row with its playing-row color. Pushes the
// matching row text color into its cells.
@interface PlaylistRowView : NSTableRowView

// YES on the current row. PlaylistController stamps it at row creation and
// re-stamps visible rows on every cursor change and structural edit.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

// Pushes the row text color into the row's cells. The row calls it on its own
// changes. The PlaylistRowColors effect calls it on a theme edit.
- (void)applyTextColor;

@end

NS_ASSUME_NONNULL_END
