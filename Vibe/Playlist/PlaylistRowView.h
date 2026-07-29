//
//  PlaylistRowView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Row background drawing for the playlist: replaces the system accent-blue
// selection fill with a quiet neutral wash, and gives the playing row the
// same wash as a persistent marker. The artwork-derived accent color lives in
// the playing row's CONTENT (equalizer bars, title text — PlaylistController)
// — deliberately no full-width saturated fill anywhere.
@interface PlaylistRowView : NSTableRowView

// YES on the playlist's current row; drawn with the neutral wash even when
// not selected. PlaylistController sets it at row creation and refreshes the
// visible rows on every track change.
@property (nonatomic, getter=isPlayingRow) BOOL playingRow;

@end

NS_ASSUME_NONNULL_END
