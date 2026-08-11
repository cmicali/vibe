//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "NSURL+Hash.h"
#import "VibeStrings.h"

@interface AudioTrack ()
// cacheKey's memo. It is atomic so that the lock-free fast-path read below is
// race-free against the first store. A plain ivar read racing the
// @synchronized writer is formally a torn read, even though an aligned pointer
// store makes it benign in practice.
@property (atomic, copy, nullable) NSString *memoizedCacheKey;
@end

@implementation AudioTrack {
    NSTimeInterval _duration;
    NSString *_durationString;
    NSTimeInterval _durationStringDuration;
}

- (instancetype)initWithUrl:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        _duration = -1;
        _detectedKey = VibeMusicalKeyNone; // the zero-filled default is C major
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithUrl:url];
}

- (nullable NSString *)cacheKey {
    // Double-checked, so the fast path avoids the monitor once the key is
    // computed. The atomic property read makes it race-free; see the
    // declaration.
    NSString *key = self.memoizedCacheKey;
    if (!key) {
        // Compute outside the lock. The file-attribute stat can block
        // indefinitely on a hung network mount or a dataless cloud file, and
        // holding the monitor through it would wedge every other caller, since
        // the metadata and waveform loaders both key off this. Concurrent
        // callers may compute twice, but the results are identical and the
        // first store wins, because the monitor makes the check-then-store
        // atomic.
        key = [self.url cacheKey];
        if (!key) {
            // The stat failed; see NSURL+Hash. That is probably transient, so
            // do not memoize, and the next call retries.
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
    else if (self.url) {
        // A filename fallback until metadata loads. It strips and trims
        // exactly as AudioTrackMetadata's filename-derived title does, so the
        // row does not change when metadata arrives for a tagless file.
        NSString *name = [[[self.url standardizedURL] lastPathComponent] stringByDeletingPathExtension];
        return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    // Non-blocking on purpose, because the main thread reads it in updateUI
    // and for the dock icon. Extraction that needs a file read happens in the
    // background load MainPlayerController starts when albumArtNeedsLoad.
    return self.metadata.albumArtIfLoaded;
}

- (NSImage *)thumbnailAlbumArt {
    return self.metadata.thumbnailAlbumArt;
}

- (float)bpm {
    float tagged = self.metadata.bpm;
    return tagged > 0 ? tagged : self.detectedBPM;
}

- (VibeMusicalKey)key {
    // The nil check is load-bearing: messaging a nil metadata returns 0 for
    // NSInteger, and 0 is C major, not "no key".
    AudioTrackMetadata *metadata = self.metadata;
    VibeMusicalKey tagged = metadata ? metadata.key : VibeMusicalKeyNone;
    return tagged >= 0 ? tagged : self.detectedKey;
}

// _duration is written from the player queue, where finishPlayOnQueue
// publishes the decoded length, while the main thread reads it for cell
// rendering. That is the same cross-thread shape as the atomic metadata
// property, guarded here with the monitor the file already uses for cacheKey.
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
    // Memoized per duration value, since this is a hot path during table cell
    // rebuilds. Main thread only, unlike duration: Formatters has no
    // documented thread safety, and the monitor guards only the memo pair, not
    // the formatter.
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

- (NSString *)singleLineTitle {
    if (self.hasArtistAndTitle) {
        // Positional specifiers: a translation may want the title first.
        return [NSString stringWithFormat:STR_LABEL_TRACK_ARTIST_TITLE, self.artist, self.title];
    }
    else {
        // The title never carries an extension, since both fallbacks strip it,
        // and re-stripping a real tagged title would mangle names like
        // "Vol. 2".
        return [self.title stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    }
}

@end
