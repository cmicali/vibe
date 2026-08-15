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
#import "FolderArtRules.h"
#import "FolderArtwork.h"
#import "NSImage+Util.h"

@implementation AudioTrackArtwork {
    NSImage *_thumbnailAlbumArt;
    NSImage *_albumArt;
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

// The folder cover is deliberately not state of this class: FolderArtwork holds
// one per *folder*, shared by every track in it, and the accessors below simply
// fall back to it. So there is nothing here to demote on a track change, nothing
// to keep coherent with the setting, and nothing that could reach the disk cache
// — the archive takes archivableThumbnail, the file's own art alone.

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
        _folderArtwork = FolderArtwork.sharedInstance;
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
    NSImage *thumbnail = [NSImage decodedImageWithData:jpegData maxPixelSize:kVibeThumbnailArtDimension];
    @synchronized (self) {
        _thumbnailAlbumArt = thumbnail;
        // A track with embedded art always produced a thumbnail, so an entry
        // without one was artless. Mark it attempted, rather than re-reading
        // the file for art that is not there. Art-bearing entries stay NO, so
        // the full-resolution image can be re-read on demand.
        _albumArtExtractionAttempted = (jpegData == nil);
    }
}

- (NSImage *)archivableThumbnail {
    return [self embeddedThumbnailAlbumArt];
}

- (void)prewarmEmbeddedThumbnailAlbumArt {
    (void)[self embeddedThumbnailAlbumArt];
}

// The file's own art, or the folder's cover when it has none. Blocking on both
// paths; the folder side resolves its directory the first time any track in it
// asks — see FolderArtwork, which owns the cost rules.
- (NSImage *)albumArt {
    NSImage *embedded = [self embeddedAlbumArt];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        // embeddedAlbumArt just settled the question by reading the file, so
        // this is the artless answer, not the unknown one.
        path = [self folderFallbackPathLocked];
    }
    return [self.folderArtwork displayImageForAudioFilePath:path];
}

// Full-resolution art decodes lazily, so only the tracks actually displayed
// pay the decode and memory cost. Cache-hit instances carry no art bytes,
// which are not archived, and re-extract from the audio file on demand. Only
// the current track ever takes that path.
- (NSImage *)embeddedAlbumArt {
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
    NSImage *decoded = [NSImage decodedImageWithData:dataToDecode maxPixelSize:kVibeDisplayArtDimension];
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

// The gate on every folder-art fallback below; the rule itself lives in
// FolderArtRules.h. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    BOOL hasArtOfItsOwn = _albumArt != nil || _albumArtData != nil || _thumbnailAlbumArt != nil;
    return VibeFileIsKnownToCarryNoArt(hasArtOfItsOwn, _albumArtExtractionAttempted,
                                       _albumArtUndecodable);
}

// The file to ask the folder about, or nil when the folder must not be asked.
// Every fallback below goes through this one line, so the invariant that a
// cover can never stand in front of a track's own art has exactly one home.
// Call with the monitor held. nil is a contractual argument to every
// FolderArtwork accessor, so callers pass the result straight on.
- (NSString *)folderFallbackPathLocked {
    return [self knownToCarryNoArtLocked] ? _sourceFilePath : nil;
}

- (NSImage *)albumArtIfLoaded {
    NSString *path;
    @synchronized (self) {
        if (_albumArt) {
            return _albumArt;
        }
        path = [self folderFallbackPathLocked];
    }
    // No decode and no file access: this is the main thread's updateUI
    // accessor, and both happen on the background albumArt path that
    // albumArtNeedsLoad asks for. The folder's cover comes back only if it is
    // already decoded.
    return [self.folderArtwork cachedDisplayImageForAudioFilePath:path];
}

- (BOOL)albumArtNeedsLoad {
    NSString *path;
    @synchronized (self) {
        if (_albumArt) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching.
        if (!_albumArtUndecodable &&
                (_albumArtData != nil || (!_albumArtExtractionAttempted && _sourceFilePath != nil))) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // The file has no art of its own, or none that decodes. A load is still
    // worth dispatching while the folder's cover is unsettled or undecoded, and
    // FolderArtwork answers NO for good once a folder is known to have none, so
    // this cannot spin.
    return [self.folderArtwork needsBackgroundLoadForAudioFilePath:path];
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
        // Nothing to do for the folder's cover: FolderArtwork owns it, bounded
        // to the few folders in play, and dropping it here would only make the
        // next track in the same folder decode it again.
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

- (NSImage *)thumbnailAlbumArt {
    NSImage *embedded = [self embeddedThumbnailAlbumArt];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        // A track with its own art never asks the folder anything, so a fully
        // tagged playlist never opens a cover file at all.
        path = [self folderFallbackPathLocked];
    }
    // Non-blocking, so a playlist cell may call this while drawing: an
    // unresolved folder resolves in the background, and the notification brings
    // the row back to be redrawn.
    return [self.folderArtwork cachedThumbnailForAudioFilePath:path resolveIfUnknown:YES];
}

- (NSImage *)embeddedThumbnailAlbumArt {
    NSData *dataToDecode = nil;
    @synchronized (self) {
        if (_thumbnailAlbumArt) return _thumbnailAlbumArt;
        if (!_albumArtData) {
            return nil;
        }
        dataToDecode = _albumArtData;
    }
    // Decode outside the lock; see the file's discipline above.
    NSImage *thumbnail = [NSImage decodedImageWithData:dataToDecode maxPixelSize:kVibeThumbnailArtDimension];
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
