//
// AudioTrackArtwork.m
// Vibe
//
// Locking discipline: the monitor is never held across file I/O or an ImageIO
// decode. Either can block for minutes on a cloud placeholder, or hitch for
// 10-100ms, and the main thread takes this monitor on every updateUI pass,
// through albumArtIfLoaded. Loads therefore run outside the lock, and at worst
// two callers do the same work and the first store wins.
//

#import "AudioTrackArtwork.h"
#import <ImageIO/ImageIO.h>

// The pixel size for the playlist-cell thumbnail. It is generous for Retina at
// typical row heights, and original art is usually 1000x1000 or larger.
static const CGFloat kThumbnailDimension = 128.0;

// The cap for the full-resolution display image. Nothing renders art larger
// than the roughly 300px artwork panel or the 512px dock icon, and decoding
// straight to this size means the original-resolution bitmap, over 50MB
// decoded, is never allocated.
static const CGFloat kDisplayArtMaxDimension = 1024.0;

// Decodes image data directly at a bounded pixel size through ImageIO. Unlike
// NSImage initWithData: followed by a resize, this never materializes the
// full-size bitmap.
static VibeImage *VibeDecodeImageData(NSData *data, CGFloat maxPixelSize) {
    if (!data) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return nil;
    }
    NSDictionary *options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (id)kCGImageSourceShouldCacheImmediately: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) {
        return nil;
    }
#if TARGET_OS_OSX
    VibeImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
#else
    VibeImage *image = [UIImage imageWithCGImage:cgImage];
#endif
    CGImageRelease(cgImage);
    return image;
}

@implementation AudioTrackArtwork {
    VibeImage *_thumbnailAlbumArt;
    VibeImage *_albumArt;
    NSData *_albumArtData;
    AudioTrackArtworkExtractor _extractor;
    BOOL _albumArtExtractionAttempted;
    // The file's art bytes cannot be decoded, from a truncated or corrupt tag
    // frame. This is permanent for the file's content, so it is set regardless
    // of generation and never cleared by the discard paths. Otherwise
    // albumArtNeedsLoad would re-dispatch the same doomed decode on every
    // updateUI pass.
    BOOL _albumArtUndecodable;
    // Bumped only by discardDecodedAlbumArt, which runs when the track changes
    // and drops everything. An albumArt load in flight when that ran must not
    // store its result back, or a skip during a load re-pins the demoted
    // track's art for the playlist's lifetime. discardAlbumArtData
    // deliberately does not bump it; see there.
    NSUInteger _artGeneration;
}

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
    }
    return self;
}

- (void)adoptParsedArtData:(NSData *)artData {
    @synchronized (self) {
        _albumArtData = artData;
        _albumArtExtractionAttempted = YES;
    }
}

- (void)adoptArchivedThumbnailJPEG:(NSData *)jpegData {
    // Decode outside the monitor, per the file's discipline, though in
    // practice this runs during unarchiving, before the object is shared.
    VibeImage *thumbnail = jpegData ? VibeDecodeImageData(jpegData, kThumbnailDimension) : nil;
    @synchronized (self) {
        _thumbnailAlbumArt = thumbnail;
        // A track with embedded art always produced a thumbnail, so an entry
        // without one was artless. Mark it attempted, rather than re-reading
        // the file for art that is not there. Art-bearing entries stay NO, so
        // the full-resolution image can be re-read on demand.
        _albumArtExtractionAttempted = (jpegData == nil);
    }
}

// Full-resolution art decodes lazily, so only the tracks actually displayed
// pay the decode and memory cost. Cache-hit instances carry no art bytes,
// which are not archived, and re-extract from the audio file on demand. Only
// the current track ever takes that path.
- (VibeImage *)albumArt {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
        if (_albumArt) {
            return _albumArt;
        }
        if (_albumArtData) {
            dataToDecode = _albumArtData;
            dataWasInMemory = YES;
        }
        // Re-read the file at most once: an artless or moved file must not pay
        // for a synchronous TagLib parse on every access. Claim the attempt
        // under the lock so that concurrent callers do not double-extract.
        else if (!_sourceFilePath || _albumArtExtractionAttempted || _albumArtUndecodable) {
            return nil;
        }
        else {
            _albumArtExtractionAttempted = YES;
            pathToExtract = _sourceFilePath;
        }
    }
    // File I/O and the decode run outside the lock; see the discipline above.
    if (!dataToDecode && pathToExtract) {
        dataToDecode = _extractor ? _extractor(pathToExtract) : nil;
    }
    VibeImage *decoded = dataToDecode ? VibeDecodeImageData(dataToDecode, kDisplayArtMaxDimension) : nil;
    @synchronized (self) {
        if (dataToDecode && !decoded) {
            // The bytes exist but cannot be decoded, which is permanent for
            // this file. Mark it and drop the bytes rather than pinning them.
            _albumArtUndecodable = YES;
            _albumArtData = nil;
            return _albumArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard ran mid-load. Otherwise
        // return the result transiently, without re-pinning a demoted track's
        // art. A racing discardAlbumArtData is fine, since it only wants the
        // raw bytes gone.
        if (generation == _artGeneration) {
            // Cache the bytes only when they were freshly read from the file.
            // Bytes that have gone from _albumArtData by now were dropped by
            // discardAlbumArtData mid-decode, and restoring them would undo
            // its memory release.
            if (dataToDecode && !_albumArtData && !dataWasInMemory) {
                _albumArtData = dataToDecode;
            }
            if (!_albumArt && decoded) {
                _albumArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Nothing is stored, but the file demonstrably has art, so re-arm
            // the on-demand re-read. This load claimed the attempt flag on
            // entry, and the discard's early return left that claim in place.
            _albumArtExtractionAttempted = NO;
        }
        return _albumArt ?: decoded;
    }
}

- (VibeImage *)albumArtIfLoaded {
    // No decode here: this is the main thread's updateUI accessor, and
    // decoding happens on the background albumArt path, via albumArtNeedsLoad.
    @synchronized (self) {
        return _albumArt;
    }
}

- (BOOL)albumArtNeedsLoad {
    @synchronized (self) {
        if (_albumArt || _albumArtUndecodable) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching.
        return _albumArtData != nil || (!_albumArtExtractionAttempted && _sourceFilePath != nil);
    }
}

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the whole session.
// Afterwards the instance behaves like a cache hit: albumArt re-reads the
// audio file on demand for the one track shown at full resolution.
- (void)discardAlbumArtData {
    @synchronized (self) {
        // There is deliberately no generation bump. This only wants the raw
        // bytes released, not an in-flight decode of those same bytes thrown
        // away: the loader calls it right after publishing metadata, racing
        // the current track's first full-resolution decode.
        if (!_albumArtData) {
            // There is nothing to drop. Keep the attempted flag: an artless
            // track has it set to YES from the parse, and resetting it would
            // trigger a full TagLib re-parse merely to rediscover that there
            // is no art.
            return;
        }
        _albumArtData = nil;
        if (!_albumArt) {
            // Art exists but is not yet decoded, so re-arm the on-demand
            // re-read.
            _albumArtExtractionAttempted = NO;
        }
    }
}

// Called by the UI, on the main thread, when this track stops being current.
- (void)discardDecodedAlbumArt {
    @synchronized (self) {
        // Bump before the early return. The demotion race this guards against
        // is precisely the case where nothing is stored yet because the load
        // is still in flight.
        _artGeneration++;
        if (!_albumArt && !_albumArtData) {
            return; // artless or never loaded — keep the attempted flag
        }
        _albumArt = nil;
        _albumArtData = nil;
        // The file has art, so re-arm the on-demand re-read for the next time
        // this track is shown at full resolution.
        _albumArtExtractionAttempted = NO;
    }
}

- (VibeImage *)thumbnailAlbumArt {
    NSData *dataToDecode = nil;
    @synchronized (self) {
        if (_thumbnailAlbumArt) return _thumbnailAlbumArt;
        if (!_albumArtData) {
            return nil;
        }
        dataToDecode = _albumArtData;
    }
    // Decode outside the lock; see the file's discipline above.
    VibeImage *thumbnail = VibeDecodeImageData(dataToDecode, kThumbnailDimension);
    @synchronized (self) {
        if (!thumbnail) {
            // The same undecodable marking as the full-resolution path.
            // Otherwise every playlist cell redraw retries the doomed decode.
            _albumArtUndecodable = YES;
            _albumArtData = nil;
        }
        if (!_thumbnailAlbumArt && thumbnail) {
            _thumbnailAlbumArt = thumbnail;
        }
        return _thumbnailAlbumArt;
    }
}

@end
