//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

@implementation AudioTrack {

}

- (instancetype)initWithUrl:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithUrl:url];
}

- (NSString *)title {
    if (self.metadata.title.length > 0) {
        return self.metadata.title;
    }
    else if (self.url) {
        return [[self.url standardizedURL] lastPathComponent];
    }
    return @"";
}

+ (AudioTrack *)empty {
    static AudioTrack *empty = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        empty = [[self alloc] init];
    });
    return empty;
}

- (NSString *)artist {
    if (self.metadata.artist.length > 0) {
        return self.metadata.artist;
    }
    else {
        return @"";
    }
}

- (NSImage *)albumArt {
    return self.metadata.albumArt;
}

- (NSString *)singleLineTitle {
    if (self.artist.length > 0 && self.metadata.title.length > 0) {
        return [NSString stringWithFormat:@"%@ - %@", self.artist, self.title];
    }
    else {
        return self.title;
    }
}

@end