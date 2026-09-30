//
//  AudioTrack.m
//  Vibe
//

#import "AudioTrackInternal.h"
#import "AudioFileHandle.h"
#import "AudioFileOpenRules.h"
#import "AudioTrackMetadata.h"
#import "Formatters.h"
#import "NSURL+Hash.h"
#import "PlaybackIntent.h"
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
    // Both fixed with the window: a row is minted, never re-pointed.
    NSString *_sourceKey;
    // A cue row's own name — its TITLE, else "Track n" — or nil.
    NSString *_cueRowTitle;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        self.url = url;
        _duration = -1;
        _detectedKey = VibeMusicalKeyNone; // the zero-filled default is C major
        _sourceKey = url.path ?: @"";
    }
    return self;
}

+ (AudioTrack *)withURL:(NSURL *)url {
    return [[AudioTrack alloc] initWithURL:url];
}

- (instancetype)initWithURL:(NSURL *)url cueStart:(NSUInteger)start cueEnd:(NSUInteger)end
                      title:(NSString *)title performer:(NSString *)performer
                      sheet:(NSURL *)sheet trackNumber:(NSInteger)trackNumber {
    self = [self initWithURL:url];
    if (self) {
        _cueStart = start;
        _cueEnd = end;
        _cueTitle = [title copy];
        _cuePerformer = [performer copy];
        _cueSheetURL = [sheet copy];
        _cueTrackNumber = trackNumber;
        _sourceKey = [self keyByAppendingWindowTo:url.path] ?: @"";
        // Its number, never the file's tag, which names the whole image and
        // would title every row alike.
        _cueRowTitle = _cueTitle.length > 0 ? _cueTitle
                : (self.isWindowed && trackNumber > 0
                        ? [NSString stringWithFormat:STR_LABEL_CUE_TRACK, (long)trackNumber] : nil);
    }
    return self;
}

- (AudioTrack *)replacementAtURL:(NSURL *)url {
    AudioTrack *track = [[AudioTrack alloc] initWithURL:url cueStart:_cueStart cueEnd:_cueEnd
                                                  title:_cueTitle performer:_cuePerformer
                                                  sheet:_cueSheetURL trackNumber:_cueTrackNumber];
    track.duration = self.duration;
    track.detectedBPM = self.detectedBPM;
    track.detectedKey = self.detectedKey;
    return track;
}

- (NSRange)frameWindowInFile:(AudioFileHandle *)file {
    return VibeCueWindow(_cueStart, _cueEnd, file.processingFormat.sampleRate, file.length);
}

- (BOOL)isWindowed {
    return _cueStart > 0 || _cueEnd > 0;
}

- (BOOL)isFollowedContiguouslyBy:(AudioTrack *)track {
    return track && _cueEnd > 0 && track.cueStart == _cueEnd && [track.url isEqual:self.url];
}

- (NSString *)sourceKey {
    return _sourceKey;
}

- (NSString *)standardizedSourceKey {
    return [self keyByAppendingWindowTo:VibeStandardizedAudioOpenPath(self.url)];
}

- (NSString *)keyByAppendingWindowTo:(NSString *)key {
    return key && self.isWindowed ? [NSString stringWithFormat:@"%@#%lu-%lu", key,
                                            (unsigned long)_cueStart, (unsigned long)_cueEnd]
                                  : key;
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
    if (_cueRowTitle) {
        return _cueRowTitle;
    }
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
    if (_cuePerformer.length > 0) {
        return _cuePerformer;
    }
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

- (AudioTrackMetadata *)rowTagMetadata {
    return self.isWindowed ? nil : self.metadata;
}

- (float)bpm {
    float tagged = self.rowTagMetadata.bpm;
    return tagged > 0 ? tagged : self.detectedBPM;
}

- (VibeMusicalKey)key {
    // A message to nil metadata would answer 0, which is C major.
    AudioTrackMetadata *metadata = self.rowTagMetadata;
    VibeMusicalKey tagged = metadata ? metadata.key : VibeMusicalKeyNone;
    return tagged >= 0 ? tagged : self.detectedKey;
}

// Written on the player queue (finishPlayOnQueueWithFile:), read on main.
// Until then a windowed row answers its window, the last row the rest of its
// file.
- (NSTimeInterval)duration {
    NSTimeInterval duration;
    @synchronized (self) {
        duration = _duration;
    }
    if (duration >= 0) {
        return duration;
    }
    if (_cueEnd > _cueStart) {
        return (NSTimeInterval)(_cueEnd - _cueStart) / kVibeCDFramesPerSecond;
    }
    NSTimeInterval file = self.metadata.duration;
    return _cueStart > 0 && file > 0 ? MAX(0, file - (NSTimeInterval)_cueStart / kVibeCDFramesPerSecond) : file;
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
    return self.artist.length > 0 && (_cueRowTitle || self.metadata.title.length > 0);
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
