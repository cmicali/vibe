//
//  PlaylistTrackCell.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"

@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kEstimatedRowHeight = 64;

// The mac playlist table's four columns in one row. It draws the values it is
// given and reads no model, setting or string.
@interface PlaylistTrackCell : UITableViewCell
// Where the separator starts: under the text, past the gutter and the art.
@property (class, nonatomic, readonly) CGFloat separatorLeadingInset;
// Set at dequeue: the table mints the cell.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerPresentationVisible;
// A transfer outranks the playing marker, including during streamed playback.
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) float loadingProgress;
// YES when the row's height can have moved; a caller rendering in place then
// owes the table a height pass (refreshVisibleRowAtIndex:).
- (BOOL)renderRow:(VibeTrackRow *)row;
@end

NS_ASSUME_NONNULL_END
