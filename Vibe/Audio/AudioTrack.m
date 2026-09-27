//
//  AudioTrack.m
//  Vibe
//

#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "NSURL+Hash.h"
#import "VibeStrings.h"

@interface AudioTrack ()
@property(copy, readwrite) NSURL *url;
@property(atomic, strong, nullable, readwrite) AudioTrackMetadata *metadata;
// Atomic, so cacheKey's lock-free fast-path read cannot race the first store.
@property (atomic, copy, nullable) NSString *memoizedCacheKey;
@end

@implementation AudioTrack {
    NSTimeInterval _duration;
    NSString *_durationString;
    NSTimeInterval _durationStringDuration;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        _duration = -1;
        _detectedKey = VibeMusicalKeyNone; // the zero-filled default is C major
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithURL:url];
}

- (BOOL)installMetadataIfUnresolved:(AudioTrackMetadata *)metadata {
    @synchronized (self) {
        if (self.metadata.parsedOK) {
            return NO;
        }
        self.metadata = metadata;
        return YES;
    }
}

- (BOOL)deliverIfMetadataStillInstalled:(AudioTrackMetadata *)metadata
                              usingBlock:(NS_NOESCAPE dispatch_block_t)delivery {
    NSParameterAssert(delivery);
    @synchronized (self) {
        if (self.metadata != metadata) {
            return NO;
        }
        delivery();
        return YES;
    }
}

- (nullable NSString *)cacheKey {
    NSString *key = self.memoizedCacheKey;
    if (!key) {
        // Outside the monitor: the stat can block indefinitely on a hung
        // mount or a dataless file, and would wedge every caller with it.
        // Concurrent callers may compute twice; the first store wins.
        key = [self.url cacheKey];
        if (!key) {
            // Probably transient: not memoized, so the next call retries.
            return nil;
        }
        @synchronized (self) {
            if (!self.memoizedCacheKey) {
                self.memoizedCacheKey = key;
            }
            key = self.memoizedCacheKey;
        }
    }
    return key;
}

- (NSString *)title {
    if (self.metadata.title.length > 0) {
        return self.metadata.title;
    }
    return self.url ? [AudioTrack filenameTitleForURL:self.url] : @"";
}

+ (NSString *)filenameTitleForURL:(NSURL *)url {
    NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (NSString *)artist {
    if (self.metadata.artist.length > 0) {
        return self.metadata.artist;
    }
    else {
        return @"";
    }
}

- (VibeImage *)cachedArt {
    return self.metadata.cachedArt;
}

- (VibeImage *)cachedThumbnail {
    return self.metadata.cachedThumbnail;
}

- (float)bpm {
    float tagged = self.metadata.bpm;
    return tagged > 0 ? tagged : self.detectedBPM;
}

- (VibeMusicalKey)key {
    // A message to nil metadata would answer 0, which is C major.
    AudioTrackMetadata *metadata = self.metadata;
    VibeMusicalKey tagged = metadata ? metadata.key : VibeMusicalKeyNone;
    return tagged >= 0 ? tagged : self.detectedKey;
}

// Written on the player queue (finishPlayOnQueueWithFile:), read on main.
- (NSTimeInterval)duration {
    NSTimeInterval duration;
    @synchronized (self) {
        duration = _duration;
    }
    if (duration >= 0) {
        return duration;
    }
    return self.metadata.duration;
}

- (void)setDuration:(NSTimeInterval)len {
    @synchronized (self) {
        _duration = len;
    }
}

- (NSString *)durationString {
    NSTimeInterval duration = self.duration;
    if (duration <= 0) {
        return @"";
    }
    // Main thread only: the monitor guards the memo pair, not Formatters,
    // which is not documented thread-safe.
    @synchronized (self) {
        if (!_durationString || _durationStringDuration != duration) {
            _durationString = [[Formatters sharedInstance] durationStringFromTimeInterval:duration];
            _durationStringDuration = duration;
        }
        return _durationString;
    }
}

- (BOOL)hasArtistAndTitle {
    return self.artist.length > 0 && self.metadata.title.length > 0;
}

- (NSString *)displayTitle {
    return self.hasArtistAndTitle ? self.title : self.singleLineTitle;
}

- (NSString *)displayArtist {
    return self.hasArtistAndTitle ? self.artist : nil;
}

- (NSString *)singleLineTitle {
    if (self.hasArtistAndTitle) {
        // Positional specifiers: a translation may want the title first.
        return [NSString stringWithFormat:STR_LABEL_TRACK_ARTIST_TITLE, self.artist, self.title];
    }
    else {
        // No extension to strip: both fallbacks already did, and stripping a
        // tagged title would mangle "Vol. 2".
        return [self.title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    }
}

@end
