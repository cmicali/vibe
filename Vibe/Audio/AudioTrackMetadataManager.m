//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadataManager.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

@implementation AudioTrackMetadataManager {
    PINCache *_metadataCache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _metadataCache = [[PINCache alloc] initWithName:@"Audio Track Metadata"];
        _metadataCache.diskCache.byteLimit = 64 * 1024 * 1024;
        _metadataCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
        [_metadataCache removeAllObjects];
    }
    return self;
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {

    NSUInteger numTracks = tracks.count;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        for (AudioTrack *track in tracks) {
            NSString *cacheKey = track.url.path;
            if (!track.metadata) {
                if ([self->_metadataCache objectForKey:cacheKey]) {
                    track.metadata = [self->_metadataCache objectForKey:cacheKey];
                }
                else {
                    track.metadata = [AudioTrackMetadata metadataWithURL:track.url];
                    [self->_metadataCache setObject:track.metadata forKey:cacheKey];
                }
            }
            if (track.metadata) {
                run_on_main_thread({
                    [self.delegate didLoadMetadata:track];
                });
            }
        }
    });

}


@end
