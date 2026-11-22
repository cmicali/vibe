//
//  PlaylistTrackCell.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"

@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kEstimatedRowHeight = 64;
static const CGFloat kNumberColumnWidth = 26;
static const CGFloat kArtTextGap = 14;

// The mac playlist table's four columns in one row. It draws the values it is
// given and reads no model, setting or string.
@interface PlaylistTrackCell : UITableViewCell
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
