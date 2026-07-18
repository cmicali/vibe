//
// AudioTrackArtwork.m
// Vibe
//
// Locking discipline: the monitor is never held across file I/O or an ImageIO
// decode — either can block for minutes (cloud placeholder) or hitch for
// 10-100ms, and the main thread takes this monitor on every updateUI pass
// (albumArtIfLoaded). Loads therefore run outside the lock; worst case two
// callers do the same work and the first store wins.
//

#import "AudioTrackArtwork.h"
#import "NSImage+Util.h"
#import <ImageIO/ImageIO.h>

// Pixel size for the playlist-cell thumbnail. Generous for Retina at typical
// row heights; original art is usually 1000×1000+.
static const CGFloat kThumbnailDimension = 128.0;

// Cap for the "full-res" display image: nothing renders art larger than the
// ~300px artwork panel / 512px dock icon, and decoding straight to this size
// means the original-resolution bitmap (50MB+ decoded) is never allocated.
static const CGFloat kDisplayArtMaxDimension = 1024.0;

// Decode image data directly at a bounded pixel size via ImageIO — unlike
// NSImage initWithData: + resize, the full-size bitmap is never materialized.
static NSImage *VibeDecodeImageData(NSData *data, CGFloat maxPixelSize) {
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
    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
    CGImageRelease(cgImage);
    return image;
}

@implementation AudioTrackArtwork {
    NSImage *_thumbnailAlbumArt;
    NSImage *_albumArt;
    NSData *_albumArtData;
    AudioTrackArtworkExtractor _extractor;
    BOOL _albumArtExtractionAttempted;
    // The file's art bytes can't be decoded (truncated/corrupt tag frame).
    // Permanent for this file's content: set regardless of generation and
    // never cleared by the discard paths — otherwise albumArtNeedsLoad would
    // re-dispatch the same doomed decode on every updateUI pass.
    BOOL _albumArtUndecodable;
    // Bumped ONLY by discardDecodedAlbumArt (track changed — drop everything):
    // an albumArt load in flight when that ran must not store its result back,
    // or a skip-during-load re-pins the demoted track's art for the playlist's
    // lifetime. discardAlbumArtData deliberately does NOT bump it (see there).
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
    // Decode outside the monitor per the file discipline — though in practice
    // this runs during unarchiving, before the object is shared.
    NSImage *thumbnail = jpegData ? VibeDecodeImageData(jpegData, kThumbnailDimension) : nil;
    @synchronized (self) {
        _thumbnailAlbumArt = thumbnail;
        // A track with embedded art always produced a thumbnail, so a
        // thumbnail-less entry was artless: mark it attempted (don't re-read
        // the file for art that isn't there). Art-bearing entries stay NO so
        // the full-res image can be re-read on demand.
        _albumArtExtractionAttempted = (jpegData == nil);
    }
}

// Full-res art decodes lazily, so only tracks actually displayed pay the
// decode/memory cost. Cache-hit instances carry no art bytes (they're not
// archived) and re-extract from the audio file on demand — only the current
// track ever takes that path.
- (NSImage *)albumArt {
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
        // Re-read the file at most once: artless or moved files must not pay
        // a synchronous TagLib parse on every access. Claim the attempt under
        // the lock so concurrent callers don't double-extract.
        else if (!_sourceFilePath || _albumArtExtractionAttempted || _albumArtUndecodable) {
            return nil;
        }
        else {
            _albumArtExtractionAttempted = YES;
            pathToExtract = _sourceFilePath;
        }
    }
    // File I/O and decode outside the lock (see the file discipline above).
    if (!dataToDecode && pathToExtract) {
        dataToDecode = _extractor ? _extractor(pathToExtract) : nil;
    }
    NSImage *decoded = dataToDecode ? VibeDecodeImageData(dataToDecode, kDisplayArtMaxDimension) : nil;
    @synchronized (self) {
        if (dataToDecode && !decoded) {
            // Bytes exist but can't be decoded — permanent for this file:
            // mark it and drop the bytes rather than pinning them.
            _albumArtUndecodable = YES;
            _albumArtData = nil;
            return _albumArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard ran mid-load; otherwise
        // return the result transiently without re-pinning a demoted track's
        // art. A racing discardAlbumArtData is fine — it only wants the raw
        // bytes gone.
        if (generation == _artGeneration) {
            // Cache bytes only when freshly read from the file: bytes gone
            // from _albumArtData by now were dropped by discardAlbumArtData
            // mid-decode, and restoring them would undo its memory release.
            if (dataToDecode && !_albumArtData && !dataWasInMemory) {
                _albumArtData = dataToDecode;
            }
            if (!_albumArt && decoded) {
                _albumArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Not storing, but the file demonstrably has art: re-arm the
            // on-demand re-read (this load claimed the attempt flag on entry,
            // and the discard's early return left that claim in place).
            _albumArtExtractionAttempted = NO;
        }
        return _albumArt ?: decoded;
    }
}

- (void)setAlbumArt:(NSImage *)albumArt {
    @synchronized (self) {
        _albumArt = albumArt;
    }
}

- (NSImage *)albumArtIfLoaded {
    // No decode here — this is the main thread's updateUI accessor; decoding
    // happens on the background albumArt path (albumArtNeedsLoad).
    @synchronized (self) {
        return _albumArt;
    }
}

- (BOOL)albumArtNeedsLoad {
    @synchronized (self) {
        if (_albumArt || _albumArtUndecodable) {
            return NO;
        }
        // In-memory bytes still to decode, or a file not yet read — both
        // background work worth dispatching.
        return _albumArtData != nil || (!_albumArtExtractionAttempted && _sourceFilePath != nil);
    }
}

// Drop the full-size compressed art bytes once the thumbnail exists — freshly
// parsed instances otherwise pin 0.5-5MB per track for the session. Afterward
// the instance behaves like a cache hit: albumArt re-reads the audio file on
// demand for the one track shown full-res.
- (void)discardAlbumArtData {
    @synchronized (self) {
        // Deliberately NO generation bump: this only wants the raw bytes
        // released, not an in-flight decode of those same bytes thrown away —
        // the loader calls it right after publishing metadata, racing the
        // current track's first full-res decode.
        if (!_albumArtData) {
            // Nothing to drop. Keep the attempted flag: an artless track has
            // it YES from the parse, and resetting it would re-trigger a full
            // TagLib re-parse just to rediscover there is no art.
            return;
        }
        _albumArtData = nil;
        if (!_albumArt) {
            // Art exists but isn't decoded yet — re-arm the on-demand re-read.
            _albumArtExtractionAttempted = NO;
        }
    }
}

// Called by the UI (main thread) when this track stops being the current one.
- (void)discardDecodedAlbumArt {
    @synchronized (self) {
        // Bump before the early return: the demotion race this guards against
        // is precisely "nothing stored yet because the load is in flight".
        _artGeneration++;
        if (!_albumArt && !_albumArtData) {
            return; // artless or never loaded — keep the attempted flag
        }
        _albumArt = nil;
        _albumArtData = nil;
        // The file has art — re-arm the on-demand re-read for the next time
        // this track is shown full-res.
        _albumArtExtractionAttempted = NO;
    }
}

- (NSImage *)thumbnailAlbumArt {
    NSData *dataToDecode = nil;
    NSImage *imageToScale = nil;
    @synchronized (self) {
        if (_thumbnailAlbumArt) return _thumbnailAlbumArt;
        if (_albumArtData) {
            dataToDecode = _albumArtData;
        }
        else if (_albumArt) {
            // Rare fallback: an injected image with no backing data.
            imageToScale = _albumArt;
        }
        else {
            return nil;
        }
    }
    // Decode/scale outside the lock (see the file discipline above).
    NSImage *thumbnail = nil;
    if (dataToDecode) {
        thumbnail = VibeDecodeImageData(dataToDecode, kThumbnailDimension);
    }
    else {
        NSSize originalSize = imageToScale.size;
        if (originalSize.width <= kThumbnailDimension && originalSize.height <= kThumbnailDimension) {
            thumbnail = imageToScale;
        } else {
            CGFloat scale = MIN(kThumbnailDimension / originalSize.width,
                                kThumbnailDimension / originalSize.height);
            NSSize target = NSMakeSize(MAX(1.0, round(originalSize.width * scale)),
                                       MAX(1.0, round(originalSize.height * scale)));
            // nil on bitmap/context allocation failure: store nothing (never
            // the full-size image — pinning it defeats the thumbnail's memory
            // point); _albumArt is still set, so the next access retries.
            thumbnail = [imageToScale resizedImage:target];
        }
    }
    @synchronized (self) {
        if (dataToDecode && !thumbnail) {
            // Same undecodable marking as the full-res path — otherwise every
            // playlist cell redraw retries the doomed decode.
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
