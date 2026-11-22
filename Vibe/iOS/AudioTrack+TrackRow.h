//
//  AudioTrack+TrackRow.h
//  Vibe (iOS)
//

#import "AudioTrack.h"

@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrack (TrackRow)

// What the Playlist tab's rows and the mini player draw of this track: the
// display title and artist, the row thumbnail and the duration. The caller
// sets the number and the playing marker.
- (VibeTrackRow *)trackRow;

@end

NS_ASSUME_NONNULL_END
