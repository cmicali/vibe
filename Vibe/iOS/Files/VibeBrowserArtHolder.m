//
//  VibeBrowserArtHolder.m
//  Vibe (iOS)
//

#import "VibeBrowserArtHolder.h"

#import "AudioTrackMetadata.h"
#import "NSURL+Hash.h"

@implementation VibeBrowserArtHolder {
    NSString *_sourceKey;
    // The file's key and the NSURL.cacheKeyGeneration it was read under,
    // under the monitor. The loader compares this key, never a fresh stat.
    NSString *_cacheKey;
    uint64_t _cacheKeyGeneration;
}

@synthesize url = _url;
@synthesize metadata = _metadata;

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _url = [url copy];
        _sourceKey = url.path ?: @"";
    }
    return self;
}

- (NSUInteger)cueStart {
    return 0;
}

- (NSUInteger)cueEnd {
    return 0;
}

- (NSString *)sourceKey {
    return _sourceKey;
}

- (NSString *)cacheKey {
    // Read before the stat, so a replacement landing during it stamps this
    // key stale.
    uint64_t generation = NSURL.cacheKeyGeneration;
    @synchronized (self) {
        if (_cacheKey && _cacheKeyGeneration == generation) {
            return _cacheKey;
        }
    }
    // Outside the monitor: the stat can block on a hung mount or a dataless
    // file. A nil key is probably transient and is not kept.
    NSString *key = [_url cacheKey];
    if (!key) {
        return nil;
    }
    @synchronized (self) {
        if (!_cacheKey || _cacheKeyGeneration < generation) {
            _cacheKey = key;
            _cacheKeyGeneration = generation;
        }
        return _cacheKey;
    }
}

- (AudioTrackMetadata *)metadata {
    @synchronized (self) {
        return _metadata;
    }
}

// The holder's monitor is @synchronized, which is recursive, as the protocol
// asks.
- (BOOL)installMetadataIfUnresolved:(AudioTrackMetadata *)metadata {
    @synchronized (self) {
        AudioTrackMetadata *installed = _metadata;
        if (installed.parsedOK && (installed.cacheKey == metadata.cacheKey
                || [installed.cacheKey isEqualToString:metadata.cacheKey])) {
            return NO;
        }
        _metadata = metadata;
        return YES;
    }
}

- (BOOL)deliverIfMetadataStillInstalled:(AudioTrackMetadata *)metadata
                             usingBlock:(NS_NOESCAPE dispatch_block_t)delivery {
    @synchronized (self) {
        if (_metadata != metadata) {
            return NO;
        }
        delivery();
        return YES;
    }
}

@end
