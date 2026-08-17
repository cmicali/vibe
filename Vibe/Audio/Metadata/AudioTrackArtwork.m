//
// AudioTrackArtwork.m
// Vibe
//
// The seven states, the transitions and the locking discipline are in the
// header. These are the fields the table is written in terms of.
//

#import "AudioTrackArtwork.h"
#import "FolderArtRules.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

// Three consecutive read failures end the current display attempt rather than
// letting updateUI dispatch forever. discardDecodedArt re-arms them when the
// track leaves the header, so a later visit can recover after the file or its
// provider becomes readable again.
static const NSUInteger kMaxEmbeddedArtExtractionFailures = 3;

// And how long after a failed read the next attempt may start. The count alone
// bounded how many reads a bad file cost but not how fast they were spent:
// updateUI runs several times in quick succession at a track start (begin
// loading, start playing, metadata, art), so all three attempts went back to
// back, each blocking a user-initiated worker for however long the failing read
// takes — and nothing about an unreachable provider changes between two calls
// milliseconds apart. The delay is what makes the second and third attempts
// worth making. It is not a poll: nothing schedules a retry, it only decides
// whether the next pass that asks is allowed to try.
static const NSTimeInterval kEmbeddedArtExtractionRetryBackoff = 2.0;

@implementation AudioTrackArtwork {
    VibeImage *_embeddedThumbnail;
    VibeImage *_embeddedArt;
    NSData *_embeddedArtData;
    AudioTrackArtworkExtractor _extractor;
    // The file carries art, in hand or not. Set by a parse that found bytes and
    // by an archive that recorded the fact, and never cleared by a discard —
    // the bytes go, the fact does not.
    BOOL _embeddedArtKnown;
    // YES only after extraction conclusively found art or found none. A read
    // failure leaves this NO, keeping the file unknown and the folder fallback
    // closed.
    BOOL _embeddedExtractionSettled;
    BOOL _embeddedExtractionInFlight;
    NSUInteger _embeddedExtractionFailures;
    // Monotonic seconds before which no further extraction may start, 0 for
    // none. Set by a failed read, cleared by anything that re-arms the budget.
    NSTimeInterval _embeddedExtractionRetryNotBefore;
    BOOL _embeddedUndecodable;
    NSUInteger _artGeneration;
}

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
#if TARGET_OS_OSX
        _folderArt = FolderArtResolver.sharedInstance;
#else
        // Folder art is a macOS feature. Left nil, every folder-art accessor
        // below is a message to nil: no cover image, and no background load
        // scheduled, so iOS shows a file's embedded art alone and the resolver
        // is never built.
        _folderArt = nil;
#endif
    }
    return self;
}

// Read before taking the monitor, never under it — it is cheap and never
// blocks, but the injected form is arbitrary caller code.
- (NSTimeInterval)nowSeconds {
    AudioTrackArtworkClock clock = self.clock;
    return clock ? clock() : NSProcessInfo.processInfo.systemUptime;
}

// _embeddedExtractionRetryNotBefore is 0 whenever no read has failed, so this
// is also the answer for a track that has never been read at all.
- (BOOL)retryBackoffHasElapsedLocked:(NSTimeInterval)now {
    return now >= _embeddedExtractionRetryNotBefore;
}

- (void)adoptParsedArtData:(NSData *)artData {
    @synchronized (self) {
        _embeddedArtData = artData;
        _embeddedArtKnown = (artData != nil);
        _embeddedExtractionSettled = YES;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
}

- (void)adoptArchivedThumbnailJPEG:(NSData *)jpegData
                    hasEmbeddedArt:(BOOL)hasEmbeddedArt {
    // Decode outside the monitor, per the file's discipline, though in
    // practice this runs during unarchiving, before the object is shared.
    VibeImage *thumbnail = VibeDecodedImageWithData(jpegData, kVibeThumbnailArtDimension);
    @synchronized (self) {
        _embeddedThumbnail = thumbnail;
        _embeddedArtKnown = hasEmbeddedArt;
        // An entry that knows of no art is artless: mark it settled rather
        // than re-reading the file for art that is not there. An art-bearing
        // entry stays NO, so the full-resolution image is re-read on demand.
        _embeddedExtractionSettled = !hasEmbeddedArt;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
}

- (BOOL)hasEmbeddedArt {
    @synchronized (self) {
        return _embeddedArtKnown;
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
    VibeEmbeddedArtExtractionResult extractionResult = VibeEmbeddedArtExtractionReadFailed;
    NSUInteger generation;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        generation = _artGeneration;
        if (_embeddedArt) {
            return _embeddedArt;
        }
        if (_embeddedArtData) {
            dataToDecode = _embeddedArtData;
            dataWasInMemory = YES;
        }
        // A conclusive artless result is never re-read, while a failed read gets
        // a small bounded retry budget, no faster than the backoff. Claim the
        // call under the lock so concurrent callers do not double-extract.
        else if (!_sourceFilePath || !_extractor || _embeddedExtractionSettled ||
                 _embeddedExtractionInFlight || _embeddedUndecodable ||
                 _embeddedExtractionFailures >= kMaxEmbeddedArtExtractionFailures ||
                 ![self retryBackoffHasElapsedLocked:now]) {
            return nil;
        }
        else {
            _embeddedExtractionInFlight = YES;
            pathToExtract = _sourceFilePath;
        }
    }
    // File I/O and the decode run outside the lock; see the discipline above.
    if (!dataToDecode && pathToExtract) {
        extractionResult = _extractor(pathToExtract, &dataToDecode);
        if (extractionResult == VibeEmbeddedArtExtractionFoundArt && !dataToDecode) {
            LogWarn(@"Embedded art extractor reported art without bytes for %@",
                    pathToExtract.lastPathComponent);
            extractionResult = VibeEmbeddedArtExtractionReadFailed;
        }
    }
    VibeImage *decoded = dataToDecode
            ? VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension)
            : nil;
    // Read before the monitor, like the one at entry. Timed from when the read
    // RETURNED, not when it started: a read that blocked for a minute has
    // already given the condition every chance to change, and one that failed
    // instantly is the case the backoff exists for.
    NSTimeInterval completedAt = [self nowSeconds];
    @synchronized (self) {
        if (pathToExtract) {
            _embeddedExtractionInFlight = NO;
            if (extractionResult == VibeEmbeddedArtExtractionReadFailed) {
                // A demotion starts a fresh display pass. Its generation bump
                // re-armed the budget, so an older read must not spend one of
                // the new pass's attempts, or hold the new pass off behind a
                // backoff, when it finally settles.
                if (generation == _artGeneration) {
                    _embeddedExtractionFailures = MIN(kMaxEmbeddedArtExtractionFailures,
                                                       _embeddedExtractionFailures + 1);
                    _embeddedExtractionRetryNotBefore =
                            completedAt + kEmbeddedArtExtractionRetryBackoff;
                }
                return _embeddedArt; // a concurrent store, if one arrived
            }
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
            if (extractionResult == VibeEmbeddedArtExtractionNoArt) {
                _embeddedArtKnown = NO;
                _embeddedExtractionSettled = YES;
                return _embeddedArt;
            }
            _embeddedArtKnown = YES;
            _embeddedExtractionSettled = YES;
        }
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
            _embeddedExtractionSettled = NO;
        }
        return _embeddedArt ?: decoded;
    }
}

// The gate on every folder-art fallback below; the rule itself lives in
// FolderArtRules.h. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    // _embeddedArtKnown covers what the other three cannot: a cache hit whose
    // entry was written before the thumbnail was archived, and a parsed track
    // whose bytes have been discarded, both of which have art without holding
    // any of it.
    BOOL hasArtOfItsOwn = _embeddedArtKnown || _embeddedArt != nil ||
                          _embeddedArtData != nil || _embeddedThumbnail != nil;
    return VibeFileIsKnownToCarryNoArt(hasArtOfItsOwn, _embeddedExtractionSettled,
                                       _embeddedUndecodable);
}

// The file to ask the folder about, or nil when the folder must not be asked.
// Every fallback below goes through this one line, so the guarantee that a
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
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching. The
        // backoff is applied here as well as in embeddedArt, so a pass inside
        // the window answers NO rather than dispatching a load that would take
        // the artLoadDispatched flag and immediately no-op.
        BOOL canExtract = !_embeddedExtractionSettled && !_embeddedExtractionInFlight &&
                _embeddedExtractionFailures < kMaxEmbeddedArtExtractionFailures &&
                [self retryBackoffHasElapsedLocked:now] &&
                _sourceFilePath != nil && _extractor != nil;
        if (!_embeddedUndecodable && (_embeddedArtData != nil || canExtract)) {
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
            // There is nothing to drop. Keep the settled flag: an artless
            // track has it set to YES from the parse, and resetting it would
            // trigger a full TagLib re-parse merely to rediscover that there
            // is no art.
            return;
        }
        _embeddedArtData = nil;
        if (!_embeddedArt) {
            // Art exists but is not yet decoded, so re-arm the on-demand
            // re-read.
            _embeddedExtractionSettled = NO;
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
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
        if (!_embeddedExtractionSettled && !_embeddedUndecodable) {
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
        }
        // TRAP: _embeddedExtractionInFlight is deliberately NOT cleared here.
        // It is the single-flight claim over a read that is still running
        // outside the monitor, and clearing it would let the next display pass
        // start a second concurrent extraction of the same file. The old read
        // releases the claim itself when it returns, and the generation bump
        // above is what stops its failure spending this pass's budget.
        // Nothing to do for the folder's cover: FolderArtResolver owns it, bounded
        // to the few folders in play, and dropping it here would only make the
        // next track in the same folder decode it again.
        if (!_embeddedArt && !_embeddedArtData) {
            return; // artless or never loaded — keep the settled flag
        }
        _embeddedArt = nil;
        _embeddedArtData = nil;
        // The file has art, so re-arm the on-demand re-read for the next time
        // this track is shown at full resolution.
        _embeddedExtractionSettled = NO;
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
