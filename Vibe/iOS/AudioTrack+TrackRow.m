//
//  AudioTrack+TrackRow.m
//  Vibe (iOS)
//

#import "AudioTrack+TrackRow.h"

#import "FileRow.h"

@implementation AudioTrack (TrackRow)

- (VibeTrackRow *)trackRow {
    VibeTrackRow *row = [[VibeTrackRow alloc] init];
    row.title = self.displayTitle;
    row.subtitle = self.displayArtist;
    // A non-blocking cache lookup. A miss decodes off main and posts.
    row.thumbnail = self.cachedThumbnail;
    row.durationText = self.durationString;
    return row;
}

@end
