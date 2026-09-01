//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Row background drawing for the playlist. It replaces the system accent-blue
// selection fill with the theme's selected-row color, and marks the playing
// row with the theme's playing-row color — two separate pairs, each defaulting
// through AppTheme's display accessors to the quiet neutral wash the app drew
// before themes. A theme may make either of them fully saturated.
@interface PlaylistRowView : NSTableRowView

// YES on the playlist's current row, which is drawn with the neutral wash even
// when it is not selected. PlaylistController sets it at row creation and
// refreshes the visible rows on every track change.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

@end

NS_ASSUME_NONNULL_END
