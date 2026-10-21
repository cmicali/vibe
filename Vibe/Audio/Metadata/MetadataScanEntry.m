//
//  MetadataScanEntry.m
//  Vibe
//

#import "MetadataScanEntry.h"

@implementation MetadataScanEntry

- (instancetype)initWithTracks:(NSArray<id<AudioTrackMetadataHolder>> *)tracks
              standardizedPath:(NSString *)standardizedPath
                 playlistIndex:(NSUInteger)playlistIndex {
    self = [super init];
    if (self) {
        _tracks = [tracks copy];
        _url = [tracks.firstObject.url copy];
        _standardizedPath = [standardizedPath copy];
        _playlistIndex = playlistIndex;
    }
    return self;
}

- (BOOL)holdsTrack:(id<AudioTrackMetadataHolder>)track {
    return [_tracks indexOfObjectIdenticalTo:track] != NSNotFound;
}

@end

@implementation MetadataPriorityMark
@end
