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
    }
    return self;
}

- (BOOL)areAllTracksCached:(NSArray<AudioTrack*>*)tracks {
    for (AudioTrack *track in tracks) {
        if (![_metadataCache containsObjectForKey:track.url.path]) {
            return NO;
        }
    }
    return YES;
}
-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {

    NSUInteger numTracks = tracks.count;

    if ([self areAllTracksCached:tracks]) {
        for (AudioTrack *track in tracks) {
            track.metadata = [_metadataCache objectForKey:track.url.path];
            [self.delegate didLoadMetadata:track];
        }
        [self.delegate didFinishLoadingMetadata:numTracks];
        return;
    }

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
                dispatch_async(dispatch_get_main_queue(), ^(void) {
                    [self.delegate didLoadMetadata:track];
                });
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [self.delegate didFinishLoadingMetadata:numTracks];
        });
    });

}


@end
