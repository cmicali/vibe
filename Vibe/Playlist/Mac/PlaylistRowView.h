//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Replaces the system accent-blue selection fill with the theme's selected-row
// color, and marks the playing row with its playing-row color.
@interface PlaylistRowView : NSTableRowView

// YES on the current row. PlaylistController stamps it at row creation and
// re-stamps visible rows on every cursor change and structural edit.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

@end

NS_ASSUME_NONNULL_END
