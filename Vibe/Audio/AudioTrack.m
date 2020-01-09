//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrack.h"
#import "Formatters.h"
#import "NSURL+Hash.h"

@implementation AudioTrack {
    NSTimeInterval _duration;
    NSString *_fileHash;
    NSString *_title;
    NSString *_artist;
}

- (instancetype)initWithUrl:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        self.metadataLoaded = NO;
        _duration = -1;
        _fileHash = nil;
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithUrl:url];
}

- (NSString *)title {
    if (_title.length > 0) {
        return _title;
    }
    else if (self.url) {
        return [[self.url standardizedURL] lastPathComponent];
    }
    return @"";
}

- (void)setTitle:(NSString *)title {
    _title = title;
}

- (NSString *)artist {
    return _artist;
}

- (void)setArtist:(NSString *)artist {
    _artist = artist;
}

- (NSString *)fileHash {
    return _fileHash;
}

- (NSString *)calculateFileHash {
    if (!_fileHash) {
        _fileHash = [self.url sha1HashOfFile];
    }
    return _fileHash;
}
- (NSTimeInterval)duration {
    return _duration;
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
    return self.artist.length > 0 && self.title.length > 0;
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
