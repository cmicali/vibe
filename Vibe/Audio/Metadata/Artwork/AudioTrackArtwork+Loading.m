//
// AudioTrackArtwork+Loading.m
// Vibe
//
// The full-art load: the extraction gate, the blocking read ladder, and the
// async load ArtworkLoadRegistry admits. Every transition takes the artwork
// monitor; no monitor spans I/O or a decode.
//

#import "AudioTrackArtworkInternal.h"
#import "ArtworkLoadRegistry.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

// Failed reads per display pass; discardDecodedArt re-arms them.
static const NSUInteger kMaxEmbeddedArtExtractionFailures = 3;

// The gap after a failed read: a track start runs updateUI several times in
// quick succession, which would spend every attempt back to back. Not a
// poll; it only gates the next pass that asks.
static const NSTimeInterval kEmbeddedArtExtractionRetryBackoff = 2.0;

@implementation AudioTrackArtwork (Loading)

// Never under the monitor: the injected clock is arbitrary code.
- (NSTimeInterval)nowSeconds {
    AudioTrackArtworkClock clock = self.clock;
    return clock ? clock() : NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)retryBackoffHasElapsedLocked:(NSTimeInterval)now {
    return now >= _embeddedExtractionRetryNotBefore;
}

- (BOOL)canStartEmbeddedExtractionLockedAt:(NSTimeInterval)now {
    return !VibeEmbeddedArtFactIsSettled(_embeddedArtFact)
            && !_embeddedExtractionInFlight &&
            !_embeddedUndecodable &&
            _embeddedExtractionFailures < kMaxEmbeddedArtExtractionFailures &&
            [self retryBackoffHasElapsedLocked:now] &&
            _sourceFilePath != nil && _extractor != nil;
}

// The file's own art, or the folder's cover when it has none. Blocking.
- (VibeImage *)loadArtBlocking {
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
    }
    return [self loadArtBlockingForExpectedGeneration:generation
                                sourceFileReadAllowed:YES];
}

- (VibeImage *)loadArtBlockingForExpectedGeneration:(NSUInteger)generation
                              sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    VibeImage *embedded = [self embeddedArtForExpectedGeneration:generation
                                           sourceFileReadAllowed:sourceFileReadAllowed];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        if (generation != _artGeneration) {
            return nil;
        }
        path = [self folderFallbackPathLocked];
    }
    return [self.folderArt displayImageForAudioFilePath:path];
}

// Lazy: only displayed tracks pay the decode. Order: decoded art, in-memory
// bytes, archived rendition, source-file extraction.
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    AudioTrackArchivedDisplayArtProvider providerToRead = nil;
    VibeEmbeddedArtExtractionResult extractionResult = VibeEmbeddedArtExtractionReadFailed;
    NSUInteger generation;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        // One critical section with the extraction claim: a demotion lands
        // wholly before the read or wholly after its claim.
        if (expectedGeneration != _artGeneration) {
            return nil;
        }
        generation = expectedGeneration;
        if (_embeddedArt) {
            return _embeddedArt;
        }
        if (_embeddedArtData) {
            dataToDecode = _embeddedArtData;
            dataWasInMemory = YES;
        }
        else if (_archivedDisplayArtProvider) {
            // No extraction claim: a concurrent read is at worst redundant,
            // and the store is generation-fenced.
            providerToRead = _archivedDisplayArtProvider;
        }
        else if ([self canStartEmbeddedExtractionLockedAt:now]) {
            if (!sourceFileReadAllowed) {
                return nil;
            }
            _embeddedExtractionInFlight = YES;
            pathToExtract = _sourceFilePath;
        }
        else {
            return nil;
        }
    }
    // Outside the monitor: a provider read can block indefinitely.
    if (providerToRead) {
        dataToDecode = providerToRead();
        VibeImage *decodedProviderArt = dataToDecode
                ? VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension)
                : nil;
        if (!decodedProviderArt) {
            // Not undecodable: the file's own art may be fine. Drop the
            // provider and take the demotion fence, so finishRequest
            // re-requests a still-wanted row and the next pass extracts.
            @synchronized (self) {
                if (_archivedDisplayArtProvider == providerToRead) {
                    _archivedDisplayArtProvider = nil;
                }
                if (generation == _artGeneration) {
                    _artGeneration++;
                    _artLoadPending = NO;
                }
            }
            return nil;
        }
        @synchronized (self) {
            // Never re-pinned as _embeddedArtData; a re-read is cheap.
            if (generation == _artGeneration && !_embeddedArt) {
                _embeddedArt = decodedProviderArt;
            }
            return _embeddedArt ?: decodedProviderArt;
        }
    }
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
    // Start the backoff after the read returns, even if the read was slow.
    NSTimeInterval completedAt = [self nowSeconds];
    @synchronized (self) {
        if (pathToExtract) {
            _embeddedExtractionInFlight = NO;
            if (extractionResult == VibeEmbeddedArtExtractionReadFailed) {
                // A superseded read must not spend the new pass's budget.
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
                _embeddedArtFact = VibeEmbeddedArtFactArtless;
                return _embeddedArt;
            }
            _embeddedArtFact = VibeEmbeddedArtFactHasArtSettled;
        }
        if (dataToDecode && !decoded) {
            // Do not retry decoding these bytes.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
            return _embeddedArt; // still nil unless a concurrent store won
        }
        // Store only if no demotion ran mid-load; otherwise return it
        // transiently.
        if (generation == _artGeneration) {
            // Only freshly read bytes: in-memory ones gone by now were dropped
            // by discardArtData, and restoring them would undo it.
            if (dataToDecode && !_embeddedArtData && !dataWasInMemory) {
                _embeddedArtData = dataToDecode;
            }
            if (!_embeddedArt && decoded) {
                _embeddedArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Superseded: nothing stored, but the file has art, so the new
            // pass must read again.
            _embeddedArtFact = VibeEmbeddedArtFactHasArtNeedsRead;
        }
        return _embeddedArt ?: decoded;
    }
}

- (BOOL)artNeedsLoad {
    NSString *path;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // The backoff applies here too, so a pass inside the window answers
        // NO rather than dispatching a load that would no-op.
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        if (!_embeddedUndecodable && (_embeddedArtData != nil ||
                _archivedDisplayArtProvider != nil || canExtract)) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // Cannot spin: the resolver answers NO for good once a folder has none.
    return [self.folderArt needsBackgroundLoadForAudioFilePath:path];
}

- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL **)sourceURL {
    NSParameterAssert(generation);
    NSParameterAssert(sourceURL);
    if (![self artNeedsLoad]) {
        return NO;
    }
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_artLoadPending || _embeddedArt) {
            return NO;
        }
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        BOOL hasArchivedRendition = _archivedDisplayArtProvider != nil;
        BOOL needsEmbeddedWork = !_embeddedUndecodable &&
                (_embeddedArtData != nil || hasArchivedRendition || canExtract);
        // No source URL while a rendition stands in: it must not materialize
        // the song.
        *sourceURL = needsEmbeddedWork && canExtract && !_embeddedArtData &&
                !hasArchivedRendition
                ? [NSURL fileURLWithPath:_sourceFilePath] : nil;
        *generation = _artGeneration;
        _artLoadPending = YES;
        return YES;
    }
}

- (void)loadArtIfNeededWithLabel:(NSString *)label
                     stillWanted:(BOOL (^)(void))stillWanted
                       completion:(void (^)(VibeImage *))completion {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(stillWanted);
    NSParameterAssert(completion);
    [VibeSharedArtworkLoadRegistry() loadArtwork:self label:label
                                     stillWanted:stillWanted completion:completion];
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
    @synchronized (self) {
        return _artGeneration == generation;
    }
}

- (void)clearLoadPendingForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            _artLoadPending = NO;
        }
    }
}

- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            [self discardDecodedArtStateLocked];
        }
    }
}

@end
