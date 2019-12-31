//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"

@implementation AudioTrack {
    NSTimeInterval _duration;
}

- (instancetype)initWithUrl:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        _duration = -1;
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

- (NSTimeInterval)duration {
    if (_duration >= 0) {
        return _duration;
    }
    return self.metadata.duration;
}

- (void)setDuration:(NSTimeInterval)len {
    _duration = len;
}

- (NSString *)durationString {
    if (self.duration > 0) {
        return [[Formatters sharedInstance] durationStringFromTimeInterval:self.duration];
    }
    else {
        return @"";
    }
}

- (BOOL)hasArtistAndTitle {
    return self.artist.length > 0 && self.metadata.title.length > 0;
}

- (NSString *)singleLineTitle {
    if (self.hasArtistAndTitle) {
        return [NSString stringWithFormat:@"%@ - %@", self.artist, self.title];
    }
    else {
        NSString *result = [self.title stringByDeletingPathExtension];
        result = [result stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        return result;
    }
}

@end
