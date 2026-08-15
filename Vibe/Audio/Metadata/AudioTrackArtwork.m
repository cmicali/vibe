//
// AudioTrackArtwork.m
// Vibe
//
// The five states, the transitions and the locking discipline are in the
// header. These are the fields the table is written in terms of.
//

#import "AudioTrackArtwork.h"
#import "FolderArtRules.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

@implementation AudioTrackArtwork {
    VibeImage *_embeddedThumbnail;
    VibeImage *_embeddedArt;
    NSData *_embeddedArtData;
    AudioTrackArtworkExtractor _extractor;
    BOOL _embeddedExtractionAttempted;
    BOOL _embeddedUndecodable;
    NSUInteger _artGeneration;
}

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
        _folderArt = FolderArtResolver.sharedInstance;
    }
    return self;
}

- (void)adoptParsedArtData:(NSData *)artData {
    @synchronized (self) {
        _embeddedArtData = artData;
        _embeddedExtractionAttempted = YES;
    }
}

- (void)adoptArchivedThumbnailJPEG:(NSData *)jpegData {
    // Decode outside the monitor, per the file's discipline, though in
    // practice this runs during unarchiving, before the object is shared.
    VibeImage *thumbnail = VibeDecodedImageWithData(jpegData, kVibeThumbnailArtDimension);
    @synchronized (self) {
        _embeddedThumbnail = thumbnail;
        // A track with embedded art always produced a thumbnail, so an entry
        // without one was artless. Mark it attempted, rather than re-reading
        // the file for art that is not there. Art-bearing entries stay NO, so
        // the full-resolution image can be re-read on demand.
        _embeddedExtractionAttempted = (jpegData == nil);
    }
}

- (void)prewarmEmbeddedThumbnail {
    (void)[self embeddedThumbnail];
}

// The file's own art, or the folder's cover when it has none. Blocking on both
// paths; the folder side resolves its directory the first time any track in it
// asks — see FolderArtResolver, which owns the cost rules.
- (VibeImage *)loadArtBlocking {
    VibeImage *embedded = [self embeddedArt];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        // embeddedArt just settled the question by reading the file, so
        // this is the artless answer, not the unknown one.
        path = [self folderFallbackPathLocked];
    }
    return [self.folderArt displayImageForAudioFilePath:path];
}

// Full-resolution art decodes lazily, so only the tracks actually displayed
// pay the decode and memory cost. Cache-hit instances carry no art bytes,
// which are not archived, and re-extract from the audio file on demand. Only
// the current track ever takes that path.
- (VibeImage *)embeddedArt {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
        if (_embeddedArt) {
            return _embeddedArt;
        }
        if (_embeddedArtData) {
            dataToDecode = _embeddedArtData;
            dataWasInMemory = YES;
        }
        // Re-read the file at most once: an artless or moved file must not pay
        // for a synchronous TagLib parse on every access. Claim the attempt
        // under the lock so that concurrent callers do not double-extract.
        else if (!_sourceFilePath || _embeddedExtractionAttempted || _embeddedUndecodable) {
            return nil;
        }
        else {
            _embeddedExtractionAttempted = YES;
            pathToExtract = _sourceFilePath;
        }
    }
    // File I/O and the decode run outside the lock; see the discipline above.
    if (!dataToDecode && pathToExtract) {
        dataToDecode = _extractor ? _extractor(pathToExtract) : nil;
    }
    VibeImage *decoded = VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension);
    @synchronized (self) {
        if (dataToDecode && !decoded) {
            // The bytes exist but cannot be decoded, which is permanent for
            // this file. Mark it and drop the bytes rather than pinning them.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
            return _embeddedArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard ran mid-load. Otherwise
        // return the result transiently, without re-pinning a demoted track's
        // art. A racing discardArtData is fine, since it only wants the
        // raw bytes gone.
        if (generation == _artGeneration) {
            // Cache the bytes only when they were freshly read from the file.
            // Bytes that have gone from _embeddedArtData by now were dropped by
            // discardArtData mid-decode, and restoring them would undo
            // its memory release.
            if (dataToDecode && !_embeddedArtData && !dataWasInMemory) {
                _embeddedArtData = dataToDecode;
            }
            if (!_embeddedArt && decoded) {
                _embeddedArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Nothing is stored, but the file demonstrably has art, so re-arm
            // the on-demand re-read. This load claimed the attempt flag on
            // entry, and the discard's early return left that claim in place.
            _embeddedExtractionAttempted = NO;
        }
        return _embeddedArt ?: decoded;
    }
}

// The gate on every folder-art fallback below; the rule itself lives in
// FolderArtRules.h. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    BOOL hasArtOfItsOwn = _embeddedArt != nil || _embeddedArtData != nil || _embeddedThumbnail != nil;
    return VibeFileIsKnownToCarryNoArt(hasArtOfItsOwn, _embeddedExtractionAttempted,
                                       _embeddedUndecodable);
}

// The file to ask the folder about, or nil when the folder must not be asked.
// Every fallback below goes through this one line, so the invariant that a
// cover can never stand in front of a track's own art has exactly one home.
// Call with the monitor held. nil is a contractual argument to every
// FolderArtResolver accessor, so callers pass the result straight on.
- (NSString *)folderFallbackPathLocked {
    return [self knownToCarryNoArtLocked] ? _sourceFilePath : nil;
}

- (VibeImage *)cachedArt {
    NSString *path;
    @synchronized (self) {
        if (_embeddedArt) {
            return _embeddedArt;
        }
        path = [self folderFallbackPathLocked];
    }
    // No decode and no file access: this is the main thread's updateUI
    // accessor, and both happen on the background loadArtBlocking path that
    // artNeedsLoad asks for. The folder's cover comes back only if it is
    // already decoded.
    return [self.folderArt cachedDisplayImageForAudioFilePath:path];
}

- (BOOL)artNeedsLoad {
    NSString *path;
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching.
        if (!_embeddedUndecodable &&
                (_embeddedArtData != nil || (!_embeddedExtractionAttempted && _sourceFilePath != nil))) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // The file has no art of its own, or none that decodes. A load is still
    // worth dispatching while the folder's cover is unsettled or undecoded, and
    // FolderArtResolver answers NO for good once a folder is known to have none, so
    // this cannot spin.
    return [self.folderArt needsBackgroundLoadForAudioFilePath:path];
}

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the whole session.
// Afterwards the instance behaves like a cache hit: loadArtBlocking re-reads the
// audio file on demand for the one track shown at full resolution.
- (void)discardArtData {
    @synchronized (self) {
        // There is deliberately no generation bump. This only wants the raw
        // bytes released, not an in-flight decode of those same bytes thrown
        // away: the loader calls it right after publishing metadata, racing
        // the current track's first full-resolution decode.
        if (!_embeddedArtData) {
            // There is nothing to drop. Keep the attempted flag: an artless
            // track has it set to YES from the parse, and resetting it would
            // trigger a full TagLib re-parse merely to rediscover that there
            // is no art.
            return;
        }
        _embeddedArtData = nil;
        if (!_embeddedArt) {
            // Art exists but is not yet decoded, so re-arm the on-demand
            // re-read.
            _embeddedExtractionAttempted = NO;
        }
    }
}

// Called by the UI, on the main thread, when this track stops being current.
- (void)discardDecodedArt {
    @synchronized (self) {
        // Bump before the early return. The demotion race this guards against
        // is precisely the case where nothing is stored yet because the load
        // is still in flight.
        _artGeneration++;
        // Nothing to do for the folder's cover: FolderArtResolver owns it, bounded
        // to the few folders in play, and dropping it here would only make the
        // next track in the same folder decode it again.
        if (!_embeddedArt && !_embeddedArtData) {
            return; // artless or never loaded — keep the attempted flag
        }
        _embeddedArt = nil;
        _embeddedArtData = nil;
        // The file has art, so re-arm the on-demand re-read for the next time
        // this track is shown at full resolution.
        _embeddedExtractionAttempted = NO;
    }
}

- (VibeImage *)cachedThumbnail {
    VibeImage *embedded = [self embeddedThumbnail];
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
    return [self.folderArt cachedThumbnailForAudioFilePath:path resolveIfUnknown:YES];
}

- (VibeImage *)embeddedThumbnail {
    NSData *dataToDecode = nil;
    @synchronized (self) {
        if (_embeddedThumbnail) return _embeddedThumbnail;
        if (!_embeddedArtData) {
            return nil;
        }
        dataToDecode = _embeddedArtData;
    }
    // Decode outside the lock; see the file's discipline above.
    VibeImage *thumbnail = VibeDecodedImageWithData(dataToDecode, kVibeThumbnailArtDimension);
    @synchronized (self) {
        if (!thumbnail) {
            // The same undecodable marking as the full-resolution path.
            // Otherwise every playlist cell redraw retries the doomed decode.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
        }
        if (!_embeddedThumbnail && thumbnail) {
            _embeddedThumbnail = thumbnail;
        }
        return _embeddedThumbnail;
    }
}

@end
