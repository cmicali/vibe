//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadataCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

@implementation AudioTrackMetadataCache {
    PINCache*                   _metadataCache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _metadataCache = [[PINCache alloc] initWithName:@"Audio Track Metadata"];
        _metadataCache.memoryCache.costLimit = 1 * 1024 * 1024;
        _metadataCache.diskCache.byteLimit = 128 * 1024 * 1024;
        _metadataCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
//        [self invalidate];
    }
    return self;
}

-(void) invalidate {
    [_metadataCache removeAllObjects];
}

- (void)metadataForTrack:(AudioTrack *)track block:(void (^)(AudioTrackMetadata *))block {
    NSURL *url = track.url;
    NSString *cacheKey = track.url.path;
    __weak AudioTrackMetadataCache *weakSelf = self;
    [_metadataCache objectForKey:cacheKey block:^(PINCache *cache, NSString *key, AudioTrackMetadata* metadata) {
        AudioTrackMetadataCache *strongSelf = weakSelf;
        if (strongSelf) {
            if (metadata) {
                run_on_main_thread({
                    [self setTrackMetadata:track metadata:metadata];
                    block(metadata);
                });
            }
            else {
                metadata = [AudioTrackMetadata metadataWithURL:url];
                [self->_metadataCache.memoryCache setObject:metadata forKey:cacheKey withCost:metadata.size];
                [self->_metadataCache.diskCache setObject:metadata forKey:cacheKey];
                run_on_main_thread({
                    [self setTrackMetadata:track metadata:metadata];
                    block(metadata);
                });
            }
        }
    }];
}

- (void)setTrackMetadata:(AudioTrack *)track metadata:(AudioTrackMetadata *)metadata {
    if (!track.metadataLoaded) {
        track.artist = metadata.artist;
        track.title = metadata.title;
        if (track.duration == -1) track.duration = metadata.duration;
    }
}

- (AudioTrackMetadata *)metadataForTrack:(AudioTrack *)track orLoad:(void (^)(AudioTrackMetadata *))block {
    AudioTrackMetadata *metadata = [_metadataCache.memoryCache objectForKey:track.url.path];
    if (metadata) {
        [self setTrackMetadata:track metadata:metadata];
        return metadata;
    }
    [self metadataForTrack:track block:block];
    return nil;
}

@end
