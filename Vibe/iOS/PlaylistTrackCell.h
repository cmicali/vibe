//
//  PlaylistTrackCell.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

#import "EqualizerLevelSource.h"

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

// Apple Music's proportions.
static const CGFloat kEstimatedRowHeight = 64;
static const CGFloat kNumberColumnWidth = 26;
static const CGFloat kArtTextGap = 14;

// The mac playlist table's four columns in one row.
@interface PlaylistTrackCell : UITableViewCell
// Set at dequeue: the table mints the cell and it never sees the model.
@property (nonatomic, weak, nullable) id<EqualizerLevelSource> levelSource;
@property (nonatomic) BOOL equalizerAudioOutputActive;
@property (nonatomic) BOOL equalizerPresentationVisible;
// YES while a provider transfer is running for this row's file. Outranks
// playing: mid-open there is no output audio for the equalizer to show.
@property (nonatomic, getter=isLoading) BOOL loading;
@property (nonatomic) float loadingProgress;
// YES when the row's height can have moved; a caller rendering in place then
// owes the table a height pass (refreshVisibleRowAtIndex:).
- (BOOL)renderTrack:(AudioTrack *)track
             number:(NSUInteger)number
            playing:(BOOL)playing;
@end

NS_ASSUME_NONNULL_END
