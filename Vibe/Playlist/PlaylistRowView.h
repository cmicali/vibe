//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Row background drawing for the playlist. It replaces the system accent-blue
// selection fill with a quiet neutral wash, and gives the playing row the same
// wash as a persistent marker. The artwork-derived accent color lives only in
// the playing row's equalizer bars, in PlaylistController: the title text keeps
// its normal label color, and there is deliberately no full-width saturated
// fill anywhere.
@interface PlaylistRowView : NSTableRowView

// YES on the playlist's current row, which is drawn with the neutral wash even
// when it is not selected. PlaylistController sets it at row creation and
// refreshes the visible rows on every track change.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

@end

NS_ASSUME_NONNULL_END
