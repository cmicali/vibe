//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Row background drawing for the playlist. It replaces the system accent-blue
// selection fill with a quiet neutral wash (the theme's playing/selected row
// pairs, defaulting through AppTheme's display accessors), and gives the
// playing row the same wash as a persistent marker. The fixed-white equalizer
// and that wash are the complete playing-row treatment; there is no saturated
// row fill.
@interface PlaylistRowView : NSTableRowView

// YES on the playlist's current row, which is drawn with the neutral wash even
// when it is not selected. PlaylistController sets it at row creation and
// refreshes the visible rows on every track change.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

@end

NS_ASSUME_NONNULL_END
