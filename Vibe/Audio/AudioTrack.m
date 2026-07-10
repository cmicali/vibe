//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "NSURL+Hash.h"

@implementation AudioTrack {
    NSTimeInterval _duration;
    NSString *_cacheKey;
    NSString *_durationString;
    NSTimeInterval _durationStringDuration;
}

- (instancetype)initWithUrl:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        _duration = -1;
        _cacheKey = nil;
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithUrl:url];
}

- (NSString *)cacheKey {
    // Double-checked: fast path avoids the lock once the key is computed
    NSString *key = _cacheKey;
    if (!key) {
        // Compute OUTSIDE the lock: the file-attribute stat can block
        // indefinitely on a hung network mount or dataless cloud file, and
        // holding the monitor through it would wedge every other caller
        // (metadata and waveform loaders both key off this). Concurrent
        // callers may compute twice; results are identical, first store wins.
        key = [self.url cacheKey];
        @synchronized (self) {
            if (!_cacheKey) {
                _cacheKey = key;
            }
            key = _cacheKey;
        }
    }
    return key;
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
    // Non-blocking on purpose: this is read from the main thread (updateUI,
    // dock icon). Extraction that needs a file read happens via the
    // background load MainPlayerController kicks off when albumArtNeedsLoad.
    return self.metadata.albumArtIfLoaded;
}

- (NSImage *)thumbnailAlbumArt {
    return self.metadata.thumbnailAlbumArt;
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
    NSTimeInterval duration = self.duration;
    if (duration <= 0) {
        return @"";
    }
    // Memoized per duration value; hot path during table cell rebuilds
    if (!_durationString || _durationStringDuration != duration) {
        _durationString = [[Formatters sharedInstance] durationStringFromTimeInterval:duration];
        _durationStringDuration = duration;
    }
    return _durationString;
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
