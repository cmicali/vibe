//
// The five art accessors and the one rule they all apply: a file's own artwork
// always wins, "unknown" is never "artless", and the folder's cover is a
// display-time fallback that must never reach the disk cache.
//

#import <XCTest/XCTest.h>

#import "AudioTrackArtworkInternal.h"
#import "FolderArtResolverInternal.h"
#import "NSImage+Util.h"

#include <os/lock.h>

@interface AudioTrackArtworkTests : XCTestCase
@end

@implementation AudioTrackArtworkTests {
    NSImage *_folderCover;
    NSString *_directory;
    NSString *_trackPath;
}

- (void)setUp {
    [AudioTrackArtwork clearDecodedThumbnailCacheForTesting];
    _folderCover = [[NSImage alloc] initWithSize:NSMakeSize(4, 4)];
    _directory = @"/Library/Albums/Precedence";
    _trackPath = [_directory stringByAppendingPathComponent:@"track.mp3"];
}

// A resolver that always has a cover for the directory, so any folder lookup
// this class makes is visible in the result.
- (FolderArtResolver *)resolverWithCover {
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return self->_folderCover;
    }];
    [resolver noteListedDirectories:[NSSet setWithObject:_directory]
             artFilenameByDirectory:@{_directory: @"cover.jpg"}];
    return resolver;
}

// Real PNG bytes, so the class's own ImageIO decode succeeds and the result is
// distinguishable from the folder cover by size.
- (NSData *)embeddedArtData {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    [image lockFocus];
    [NSColor.blueColor setFill];
    NSRectFill(NSMakeRect(0, 0, 8, 8));
    [image unlockFocus];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (AudioTrackArtwork *)artworkWithExtractor:(AudioTrackArtworkExtractor)extractor {
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:extractor];
    artwork.folderArt = [self resolverWithCover];
    return artwork;
}

- (NSImage *)waitForThumbnailDecode:(AudioTrackArtwork *)artwork {
    XCTestExpectation *completed = [self expectationWithDescription:@"thumbnail decoded"];
    __block NSImage *decoded = nil;
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        decoded = image;
        [completed fulfill];
    }]);
    [self waitForExpectations:@[completed] timeout:2.0];
    return decoded;
}

#pragma mark - The file's own art wins

- (void)testEmbeddedArtBeatsTheFoldersCover {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    NSImage *art = [artwork loadArtBlocking];
    XCTAssertNotNil(art);
    XCTAssertNotEqualObjects(art, _folderCover);
    XCTAssertNil(artwork.cachedThumbnail, @"the row accessor never decodes synchronously");
    XCTAssertNotEqualObjects([artwork decodeThumbnailForArchiving], _folderCover);
}

// The window before a file's own art has been read is NOT the artless answer.
// Getting this wrong puts a folder cover in front of a track's own artwork.
- (void)testAnUnreadFileNeverFallsBackToTheFolder {
    __block BOOL extracted = NO;
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^VibeEmbeddedArtExtractionResult(
                                                                                NSString *path, NSData *__autoreleasing *artData) {
        extracted = YES;
        return VibeEmbeddedArtExtractionNoArt;
    }];
    artwork.folderArt = [self resolverWithCover];
    // Non-blocking accessors must not answer with the folder while the file's
    // own art is merely unknown.
    XCTAssertNil(artwork.cachedArt);
    XCTAssertNil(artwork.cachedThumbnail);
    XCTAssertFalse(extracted, @"neither accessor may read the audio file");
}

- (void)testTheFolderAnswersOnlyOnceTheFileIsKnownArtless {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    // The blocking accessor settles the question and then falls back.
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
    // And the non-blocking ones follow, now that the answer is known.
    XCTAssertEqualObjects(artwork.cachedArt, _folderCover);
}

- (void)testUndecodableOwnArtFallsBackToTheFolder {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        *artData = [@"not an image" dataUsingEncoding:NSUTF8StringEncoding];
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
}

#pragma mark - The cache boundary

// The disk cache is keyed by the AUDIO file's size and mtime, which a sidecar
// image cannot move: an archived cover would outlive its file, and an archived
// "artless" would suppress the lookup forever. So the archive's thumbnail is
// the file's own art or nothing, whatever the folder holds.
- (void)testTheArchivableThumbnailIsNeverTheFoldersCover {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover, @"precondition: the folder has one");
    XCTAssertNil([artwork decodeThumbnailForArchiving]);
}

- (void)testTheArchivableThumbnailIsTheFilesOwnArtWhenItHasSome {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    (void)[artwork loadArtBlocking]; // decode it
    XCTAssertNotNil([artwork decodeThumbnailForArchiving]);
    XCTAssertNotEqualObjects([artwork decodeThumbnailForArchiving], _folderCover);
}

// The metadata scan encodes through this before publishing a row. It must
// decode the file's own thumbnail WITHOUT resolving folder art, or a playlist
// scan turns into a folder-art storm across every artless row.
- (void)testTheArchiveDecodeNeverTouchesTheFolder {
    __block NSUInteger folderLookups = 0;
    FolderArtResolver *counting = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        folderLookups++;
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        folderLookups++;
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        folderLookups++;
        return YES;
    } dataReader:^NSData *(NSString *path) {
        folderLookups++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return self->_folderCover;
    }];
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^VibeEmbeddedArtExtractionResult(
                                                                                NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    artwork.folderArt = counting;

    (void)[artwork decodeThumbnailForArchiving];

    XCTAssertEqual(folderLookups, 0u);
}

#pragma mark - Cache-hit instances

// A cache hit carries the archived thumbnail and no art bytes. An entry that
// archived no thumbnail was artless, so it may use the folder's cover without
// re-reading the audio file.
- (void)testACacheHitWithoutAThumbnailIsArtlessAndUsesTheFolder {
    __block BOOL extracted = NO;
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^VibeEmbeddedArtExtractionResult(
                                                                                NSString *path, NSData *__autoreleasing *artData) {
        extracted = YES;
        return VibeEmbeddedArtExtractionNoArt;
    }];
    artwork.folderArt = [self resolverWithCover];
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:NO];

    XCTAssertEqualObjects([artwork loadArtBlocking], _folderCover);
    XCTAssertFalse(extracted, @"an archived artless entry must not re-parse the file");
}

// The row accessor is non-blocking on purpose — a playlist cell calls it while
// drawing — so it answers nil until a background resolve has produced the
// thumbnail, rather than reading and decoding a cover on the main thread.
- (void)testTheRowAccessorNeverBlocksForAnUnresolvedFolder {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:NO];

    XCTAssertNil(artwork.cachedThumbnail, @"nothing is decoded yet, so nothing to hand back");

    // It scheduled the resolve, so the cover appears without anyone blocking.
    NSPredicate *resolved = [NSPredicate predicateWithBlock:^BOOL(AudioTrackArtwork *subject, id _) {
        return [subject.cachedThumbnail isEqual:self->_folderCover];
    }];
    [self expectationForPredicate:resolved evaluatedWithObject:artwork handler:nil];
    [self waitForExpectationsWithTimeout:5.0 handler:nil];
}

// The iOS-written cache entry: no thumbnail archived at all, because iOS keeps
// none, and the has-art flag is the only record that the file carries any. It
// must behave exactly like a thumbnail-bearing entry — re-read on demand —
// since reading as artless would leave the pager on the placeholder for good
// and hand the folder's cover to a file that has its own art.
- (void)testACacheHitWithNoThumbnailButKnownArtStillReadsTheFile {
    NSData *embedded = [self embeddedArtData];
    __block BOOL extracted = NO;
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:_trackPath
                                                                        extractor:^VibeEmbeddedArtExtractionResult(
                                                                                NSString *path, NSData *__autoreleasing *artData) {
        extracted = YES;
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    artwork.folderArt = [self resolverWithCover];
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTAssertTrue(artwork.artNeedsLoad, @"art the entry knows about is still worth a load");
    NSImage *art = [artwork loadArtBlocking];
    XCTAssertTrue(extracted, @"the file has to be re-read; the archive carries no bytes");
    XCTAssertNotNil(art);
    XCTAssertNotEqualObjects(art, _folderCover, @"the file's own art, never the folder's");
}

- (void)testAKnownArtsTransientReadFailureRetriesWithoutUsingTheFolder {
    NSData *embedded = [self embeddedArtData];
    __block NSUInteger attempts = 0;
    __block NSTimeInterval clock = 1000;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        if (attempts == 1) {
            return VibeEmbeddedArtExtractionReadFailed;
        }
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    artwork.clock = ^NSTimeInterval { return clock; };
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertNil(artwork.cachedArt, @"a read failure is not permission to use the folder cover");
    clock += 5; // the retry backoff has its own test
    XCTAssertTrue(artwork.artNeedsLoad, @"a transient failure must leave another attempt available");

    NSImage *retried = [artwork loadArtBlocking];
    XCTAssertNotNil(retried);
    XCTAssertNotEqualObjects(retried, _folderCover);
    XCTAssertEqual(attempts, 2u);
}

- (void)testRepeatedReadFailuresAreBoundedAndRearmedOnTrackDemotion {
    __block NSUInteger attempts = 0;
    __block NSTimeInterval clock = 0;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    artwork.clock = ^NSTimeInterval { return clock; };
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        XCTAssertNil([artwork loadArtBlocking]);
        clock += 60; // past the backoff, so only the count can stop it
    }
    XCTAssertFalse(artwork.artNeedsLoad, @"the current display pass must not retry forever");
    XCTAssertNil(artwork.cachedArt, @"known embedded art still excludes the folder cover");
    XCTAssertEqual(attempts, 3u);
    XCTAssertNil([artwork loadArtBlocking], @"and waiting longer must not buy a fourth");
    XCTAssertEqual(attempts, 3u);

    [artwork discardDecodedArt];
    XCTAssertTrue(artwork.artNeedsLoad, @"a later visit gets a fresh bounded retry budget");
}

// The budget bounds how many reads a bad file costs; the backoff bounds how
// fast they are spent. updateUI fires several times in quick succession at a
// track start, and without this all three attempts went back to back — each
// blocking a worker on a read that had no reason to behave differently
// milliseconds after the last one failed.
- (void)testAFailedReadIsNotRetriedUntilItsBackoffElapses {
    __block NSUInteger attempts = 0;
    __block NSTimeInterval clock = 1000;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    artwork.clock = ^NSTimeInterval { return clock; };
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 1u);

    // Every pass inside the window is refused, and says so through artNeedsLoad
    // as well, so updateUI does not spend the dispatch flag on a load that
    // would immediately no-op.
    XCTAssertFalse(artwork.artNeedsLoad);
    clock += 0.5;
    XCTAssertNil([artwork loadArtBlocking]);
    clock += 0.5;
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 1u, @"a burst of passes must not spend the whole budget at once");
    XCTAssertFalse(artwork.artNeedsLoad);

    clock += 5;
    XCTAssertTrue(artwork.artNeedsLoad, @"past the backoff the attempt is available again");
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 2u);
}

// The backoff must never outlive the failure that set it: a read that succeeds
// after one that failed leaves nothing behind to hold up a later re-read.
- (void)testASuccessfulReadClearsTheBackoff {
    NSData *embedded = [self embeddedArtData];
    __block NSUInteger attempts = 0;
    __block NSTimeInterval clock = 1000;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        if (attempts == 1) {
            return VibeEmbeddedArtExtractionReadFailed;
        }
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    artwork.clock = ^NSTimeInterval { return clock; };
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTAssertNil([artwork loadArtBlocking]);
    clock += 5;
    XCTAssertNotNil([artwork loadArtBlocking]);

    // Demote and come back: the re-read is available immediately, with no
    // leftover window from the failure two visits ago.
    [artwork discardDecodedArt];
    XCTAssertTrue(artwork.artNeedsLoad);
    XCTAssertNotNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 3u);
}

// A demotion re-arms the budget, so it must clear the window too — otherwise a
// track revisited within two seconds of its last failure would be refused on
// arrival, which is exactly when a user flicking back and forth revisits it.
- (void)testDemotionClearsTheBackoffAsWellAsTheBudget {
    __block NSUInteger attempts = 0;
    __block NSTimeInterval clock = 1000;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    artwork.clock = ^NSTimeInterval { return clock; };
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 1u);
    XCTAssertFalse(artwork.artNeedsLoad, @"inside the window");

    [artwork discardDecodedArt]; // the track left the header and came back
    XCTAssertTrue(artwork.artNeedsLoad, @"the new visit does not inherit the old window");
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertEqual(attempts, 2u);
}

- (void)testAStaleReadFailureDoesNotSpendTheNextVisitsRetryBudget {
    dispatch_semaphore_t extractionStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t finishStaleExtraction = dispatch_semaphore_create(0);
    __block NSUInteger attempts = 0;
    // Read under a lock: the stale extraction runs on another thread, so the
    // clock is read from two threads at once.
    __block NSTimeInterval clock = 1000;
    os_unfair_lock clockLock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock *clockLockPointer = &clockLock;
    NSTimeInterval (^readClock)(void) = ^NSTimeInterval {
        os_unfair_lock_lock(clockLockPointer);
        NSTimeInterval value = clock;
        os_unfair_lock_unlock(clockLockPointer);
        return value;
    };
    void (^advanceClock)(NSTimeInterval) = ^(NSTimeInterval seconds) {
        os_unfair_lock_lock(clockLockPointer);
        clock += seconds;
        os_unfair_lock_unlock(clockLockPointer);
    };
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        attempts++;
        if (attempts == 1) {
            dispatch_semaphore_signal(extractionStarted);
            dispatch_semaphore_wait(finishStaleExtraction, DISPATCH_TIME_FOREVER);
        }
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    artwork.clock = readClock;
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];

    XCTestExpectation *staleExtractionFinished = [self expectationWithDescription:@"stale extraction"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        (void)[artwork loadArtBlocking];
        [staleExtractionFinished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(extractionStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);

    [artwork discardDecodedArt];
    dispatch_semaphore_signal(finishStaleExtraction);
    [self waitForExpectations:@[staleExtractionFinished] timeout:2.0];

    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        XCTAssertNil([artwork loadArtBlocking]);
        advanceClock(60); // past the backoff, so only the count can stop it
    }
    XCTAssertEqual(attempts, 4u, @"the stale attempt plus three attempts for the new display pass");
    XCTAssertFalse(artwork.artNeedsLoad);
}

// The bytes go, the fact does not: a discard re-arms the re-read, and must not
// let the track read as artless in the window before that read lands.
- (void)testDiscardingArtKeepsTheFileKnownToCarrySome {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    [artwork adoptParsedArtData:embedded];
    XCTAssertTrue(artwork.hasEmbeddedArt);

    (void)[artwork loadArtBlocking];
    [artwork discardDecodedArt];
    XCTAssertTrue(artwork.hasEmbeddedArt, @"the file still has art; only the decode went");
    XCTAssertNotEqualObjects([artwork cachedArt], _folderCover,
                             @"and the folder's cover must not slip in front of it");
}

- (void)testACacheHitWithAThumbnailKeepsItsOwn {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    [artwork adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];
    XCTAssertNil(artwork.cachedThumbnail);
    NSImage *thumbnail = [self waitForThumbnailDecode:artwork];
    XCTAssertNotNil(thumbnail);
    XCTAssertNotEqualObjects(thumbnail, _folderCover);
}

- (void)testArchivedThumbnailDecodesOffMainAndReturnsAfterEviction {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:
            ^VibeEmbeddedArtExtractionResult(NSString *path,
                    NSData *__autoreleasing *artData) {
        XCTFail(@"an archived thumbnail must not re-read its audio file");
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    [artwork adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];

    XCTAssertFalse(artwork.decodedThumbnailIsCachedForTesting,
                   @"unarchiving thousands of rows must not decode thousands of bitmaps");
    XCTAssertNil(artwork.cachedThumbnail, @"drawing must never pay an ImageIO decode");
    XCTAssertNotNil([self waitForThumbnailDecode:artwork]);
    XCTAssertTrue(artwork.decodedThumbnailIsCachedForTesting);

    [artwork evictDecodedThumbnailForTesting];
    XCTAssertFalse(artwork.decodedThumbnailIsCachedForTesting);
    XCTAssertNil(artwork.cachedThumbnail, @"eviction does not move decode work onto drawing");
    XCTAssertNotNil([self waitForThumbnailDecode:artwork],
                    @"compact bytes restore pixels without reopening the song");
}

- (void)testConcurrentRequestsForOneRowDecodeExactlyOnce {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];
    NSImage *decodedImage = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    dispatch_semaphore_t decoderStarted = dispatch_semaphore_create(0);
    os_unfair_lock decoderGate = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock *decoderGatePointer = &decoderGate;
    os_unfair_lock_lock(decoderGatePointer);
    NSLock *countLock = [[NSLock alloc] init];
    __block NSUInteger decodeCount = 0;
    artwork.thumbnailDecoder = ^NSImage *(NSData *data) {
        [countLock lock];
        decodeCount++;
        [countLock unlock];
        dispatch_semaphore_signal(decoderStarted);
        os_unfair_lock_lock(decoderGatePointer);
        os_unfair_lock_unlock(decoderGatePointer);
        return decodedImage;
    };

    XCTestExpectation *completed = [self expectationWithDescription:@"thumbnail decoded"];
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertEqualObjects(image, decodedImage);
        [completed fulfill];
    }]);
    XCTAssertEqual(dispatch_semaphore_wait(decoderStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertFalse([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTFail(@"a duplicate request owns no second completion");
    }]);
    os_unfair_lock_unlock(decoderGatePointer);
    [self waitForExpectations:@[completed] timeout:2.0];
    [countLock lock];
    NSUInteger finalDecodeCount = decodeCount;
    [countLock unlock];
    XCTAssertEqual(finalDecodeCount, 1u);
}

- (void)testDecodedThumbnailCacheHasAnExactGlobal128ImageBound {
    NSUInteger limit = AudioTrackArtwork.decodedThumbnailCacheLimitForTesting;
    XCTAssertEqual(limit, 128u);
    NSMutableArray<AudioTrackArtwork *> *artworks = [NSMutableArray array];
    NSData *encoded = [self embeddedArtData];
    for (NSUInteger index = 0; index <= limit; index++) {
        AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
        [artwork adoptArchivedThumbnailData:encoded hasEmbeddedArt:YES];
        XCTAssertNotNil([self waitForThumbnailDecode:artwork]);
        [artworks addObject:artwork];
        XCTAssertLessThanOrEqual(AudioTrackArtwork.decodedThumbnailCacheCountForTesting, limit);
    }
    XCTAssertEqual(AudioTrackArtwork.decodedThumbnailCacheCountForTesting, limit);
    XCTAssertFalse(artworks.firstObject.decodedThumbnailIsCachedForTesting);
    XCTAssertTrue(artworks.lastObject.decodedThumbnailIsCachedForTesting);
}

// Decodes completing against a full cache evict the oldest entries rather
// than growing past the bound, and the rows that just decoded stay readable.
- (void)testCompletingDecodesEvictRatherThanExceedTheBound {
    NSUInteger limit = [AudioTrackArtwork decodedThumbnailCacheLimitForTesting];
    NSData *encoded = [self embeddedArtData];
    NSMutableArray<AudioTrackArtwork *> *artworks = [NSMutableArray array];
    for (NSUInteger index = 0; index < limit; index++) {
        AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
        [artwork adoptArchivedThumbnailData:encoded hasEmbeddedArt:YES];
        XCTAssertNotNil([self waitForThumbnailDecode:artwork]);
        [artworks addObject:artwork];
    }
    XCTAssertEqual([AudioTrackArtwork decodedThumbnailCacheCountForTesting], limit);

    dispatch_semaphore_t decoderStarted = dispatch_semaphore_create(0);
    os_unfair_lock decoderGate = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock *decoderGatePointer = &decoderGate;
    os_unfair_lock_lock(decoderGatePointer);
    XCTestExpectation *firstCompleted = [self expectationWithDescription:@"first decode"];
    XCTestExpectation *secondCompleted = [self expectationWithDescription:@"second decode"];
    AudioTrackThumbnailDecoder blockingDecoder = ^NSImage *(NSData *data) {
        dispatch_semaphore_signal(decoderStarted);
        os_unfair_lock_lock(decoderGatePointer);
        os_unfair_lock_unlock(decoderGatePointer);
        return [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    };
    AudioTrackArtwork *first = [self artworkWithExtractor:nil];
    AudioTrackArtwork *second = [self artworkWithExtractor:nil];
    [first adoptArchivedThumbnailData:encoded hasEmbeddedArt:YES];
    [second adoptArchivedThumbnailData:encoded hasEmbeddedArt:YES];
    first.thumbnailDecoder = blockingDecoder;
    second.thumbnailDecoder = blockingDecoder;
    XCTAssertTrue([first requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertNotNil(image);
        [firstCompleted fulfill];
    }]);
    XCTAssertTrue([second requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertNotNil(image);
        [secondCompleted fulfill];
    }]);
    XCTAssertEqual(dispatch_semaphore_wait(decoderStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    XCTAssertEqual(dispatch_semaphore_wait(decoderStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    // In-flight pixels are not cache entries; the retained set stays full.
    XCTAssertEqual([AudioTrackArtwork decodedThumbnailCacheCountForTesting], limit);

    os_unfair_lock_unlock(decoderGatePointer);
    [self waitForExpectations:@[firstCompleted, secondCompleted] timeout:2.0];
    XCTAssertEqual([AudioTrackArtwork decodedThumbnailCacheCountForTesting], limit);
    XCTAssertTrue(first.decodedThumbnailIsCachedForTesting);
    XCTAssertTrue(second.decodedThumbnailIsCachedForTesting);
    XCTAssertFalse(artworks.firstObject.decodedThumbnailIsCachedForTesting,
                   @"the two stores must evict the least recently used rows");
}

- (void)testCompactThumbnailBytesRoundTripAndDecodeAfterRestore {
    NSData *encoded = [self embeddedArtData];
    AudioTrackArtwork *original = [self artworkWithExtractor:nil];
    [original adoptArchivedThumbnailData:encoded hasEmbeddedArt:YES];
    NSData *stored = original.encodedThumbnailDataForStorage;
    XCTAssertEqualObjects(stored, encoded);

    AudioTrackArtwork *restored = [self artworkWithExtractor:nil];
    [restored adoptArchivedThumbnailData:stored hasEmbeddedArt:YES];
    XCTAssertNil(restored.cachedThumbnail);
    XCTAssertNotNil([self waitForThumbnailDecode:restored]);
}

- (void)testCopiedRowRecoversItsThumbnailAfterIndependentEviction {
    AudioTrackArtwork *original = [self artworkWithExtractor:nil];
    [original adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];
    XCTAssertNotNil([self waitForThumbnailDecode:original]);
    AudioTrackArtwork *copy = [original copy];

    [original evictDecodedThumbnailForTesting];
    [copy evictDecodedThumbnailForTesting];
    XCTAssertNotNil([self waitForThumbnailDecode:original]);
    XCTAssertNotNil([self waitForThumbnailDecode:copy]);
}

// The identity key is the one staleness fence: adopting new data mid-decode
// rotates it, so the stale result is dropped, the new data's request is
// admitted while the old decode still runs, and only the new pixels land.
- (void)testAdoptingNewDataMidDecodeDropsTheStaleResult {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];
    NSImage *staleImage = [[NSImage alloc] initWithSize:NSMakeSize(4, 4)];
    NSImage *freshImage = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    NSData *freshBytes = [@"fresh" dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_semaphore_t staleDecodeStarted = dispatch_semaphore_create(0);
    os_unfair_lock staleGate = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock *staleGatePointer = &staleGate;
    os_unfair_lock_lock(staleGatePointer);
    artwork.thumbnailDecoder = ^NSImage *(NSData *data) {
        if (![data isEqual:freshBytes]) {
            dispatch_semaphore_signal(staleDecodeStarted);
            os_unfair_lock_lock(staleGatePointer);
            os_unfair_lock_unlock(staleGatePointer);
            return staleImage;
        }
        return freshImage;
    };

    XCTestExpectation *staleCompleted = [self expectationWithDescription:@"stale decode"];
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertNil(image, @"a result for departed data must not be delivered");
        [staleCompleted fulfill];
    }]);
    XCTAssertEqual(dispatch_semaphore_wait(staleDecodeStarted,
                                           dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);

    [artwork adoptParsedArtData:freshBytes];
    XCTestExpectation *freshCompleted = [self expectationWithDescription:@"fresh decode"];
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertEqualObjects(image, freshImage);
        [freshCompleted fulfill];
    }], @"the rotation must hand single-flight to the new data's request");

    os_unfair_lock_unlock(staleGatePointer);
    [self waitForExpectations:@[staleCompleted, freshCompleted] timeout:2.0];
    XCTAssertEqualObjects(artwork.cachedThumbnail, freshImage);
}

// A corrupt archived thumbnail is dropped without condemning the source art:
// the compact copy goes, and freshly parsed bytes decode again.
- (void)testCorruptArchivedBytesDropOnlyTheCompactCopy {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptArchivedThumbnailData:[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding]
                         hasEmbeddedArt:YES];
    XCTestExpectation *failed = [self expectationWithDescription:@"decode failed"];
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertNil(image);
        [failed fulfill];
    }]);
    [self waitForExpectations:@[failed] timeout:2.0];
    XCTAssertNil(artwork.encodedThumbnailDataForStorage,
                 @"the corrupt compact bytes must not be re-archived");
    XCTAssertTrue(artwork.hasEmbeddedArt, @"the file still carries art; only the copy was bad");

    [artwork adoptParsedArtData:[self embeddedArtData]];
    XCTAssertNotNil([self waitForThumbnailDecode:artwork]);
}

// Undecodable source art settles: the doomed bytes are dropped and marked, so
// redraws stop re-requesting a decode that can never succeed.
- (void)testUndecodableSourceArtSettlesInsteadOfRetrying {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptParsedArtData:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTestExpectation *failed = [self expectationWithDescription:@"decode failed"];
    XCTAssertTrue([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTAssertNil(image);
        [failed fulfill];
    }]);
    [self waitForExpectations:@[failed] timeout:2.0];
    XCTAssertFalse([artwork requestEmbeddedThumbnailDecodeWithCompletion:^(NSImage *image) {
        XCTFail(@"no bytes remain to decode");
    }]);
}

// The scan's encode path must never populate the display cache — that is what
// keeps a playlist-wide scan from evicting visible rows' pixels.
- (void)testArchiveDecodeDoesNotPopulateTheDisplayCache {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptParsedArtData:[self embeddedArtData]];
    XCTAssertNotNil([artwork decodeThumbnailForArchiving]);
    XCTAssertFalse(artwork.decodedThumbnailIsCachedForTesting);
    XCTAssertEqual(AudioTrackArtwork.decodedThumbnailCacheCountForTesting, 0u);
}

#pragma mark - Duplicate-row copies

- (void)testDuplicateRowsOwnIndependentArtworkState {
    NSData *embedded = [self embeddedArtData];
    __block NSUInteger extractions = 0;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        extractions++;
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    [artwork adoptArchivedThumbnailData:embedded hasEmbeddedArt:YES];
    AudioTrackArtwork *duplicate = [artwork copy];

    XCTAssertNotEqual(artwork, duplicate);
    XCTAssertNotNil([artwork loadArtBlocking]);
    XCTAssertNotNil([duplicate loadArtBlocking]);
    XCTAssertEqual(extractions, 2u, @"each row owns its full-resolution decode state");

    [artwork discardDecodedArt];
    XCTAssertNil(artwork.cachedArt);
    XCTAssertNotNil(duplicate.cachedArt, @"demoting one row must not demote its duplicate");
}

#pragma mark - The archived display-art rendition

// A cache-hit-shaped row whose extractor fails the test if the file is ever
// re-read: the provider must satisfy the load alone.
- (AudioTrackArtwork *)archivedRowWithProviderData:(NSData *)providerData
                                             reads:(NSUInteger *)reads {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        XCTFail(@"the archived rendition must satisfy the load without a file read");
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    [artwork adoptArchivedThumbnailData:[self embeddedArtData] hasEmbeddedArt:YES];
    NSUInteger *readCount = reads;
    artwork.archivedDisplayArtProvider = ^NSData *{
        if (readCount) {
            (*readCount)++;
        }
        return providerData;
    };
    return artwork;
}

- (void)testArchivedRenditionBeatsSourceFileExtraction {
    NSUInteger reads = 0;
    AudioTrackArtwork *artwork = [self archivedRowWithProviderData:[self embeddedArtData]
                                                             reads:&reads];
    NSImage *art = [artwork loadArtBlocking];
    XCTAssertNotNil(art);
    XCTAssertNotEqualObjects(art, _folderCover);
    XCTAssertEqual(reads, 1u);
    XCTAssertEqualObjects(artwork.cachedArt, art, @"the decode installs like any full art");
}

- (void)testDiscardedRowReReadsTheRenditionNotTheFile {
    NSUInteger reads = 0;
    AudioTrackArtwork *artwork = [self archivedRowWithProviderData:[self embeddedArtData]
                                                             reads:&reads];
    XCTAssertNotNil([artwork loadArtBlocking]);
    [artwork discardDecodedArt];
    XCTAssertNil(artwork.cachedArt);
    XCTAssertNotNil([artwork loadArtBlocking]);
    XCTAssertEqual(reads, 2u);
}

- (void)testMissingRenditionFallsBackToExtractionOnTheNextPass {
    NSData *embedded = [self embeddedArtData];
    __block NSUInteger extractions = 0;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        extractions++;
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    [artwork adoptArchivedThumbnailData:embedded hasEmbeddedArt:YES];
    artwork.archivedDisplayArtProvider = ^NSData *{
        return nil; // evicted sidecar
    };
    // The miss pass drops the provider and takes the demotion fence, so it
    // answers nil rather than blocking on the file inside a request that never
    // registered materialization.
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertNil(artwork.archivedDisplayArtProvider);
    XCTAssertEqual(extractions, 0u);
    // The re-request the fence provokes reaches extraction normally.
    XCTAssertNotNil([artwork loadArtBlocking]);
    XCTAssertEqual(extractions, 1u);
}

- (void)testCorruptRenditionDoesNotMarkTheTrackUndecodable {
    NSData *embedded = [self embeddedArtData];
    __block NSUInteger extractions = 0;
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        extractions++;
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    [artwork adoptArchivedThumbnailData:embedded hasEmbeddedArt:YES];
    artwork.archivedDisplayArtProvider = ^NSData *{
        return [NSData dataWithBytes:"not an image" length:12];
    };
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertNotNil([artwork loadArtBlocking],
            @"the file's own art must survive a corrupt sidecar");
    XCTAssertEqual(extractions, 1u);
}

// The dead-end state: an archive that knows of art but carries no thumbnail
// bytes (a failed 128px re-encode at parse). The row thumbnail must recover
// through the archived display rendition.
- (void)testArtBearingEntryWithoutThumbnailBytesRecoversThroughTheRendition {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        XCTFail(@"the rendition must recover the thumbnail without a file read");
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];
    NSData *rendition = [self embeddedArtData];
    artwork.archivedDisplayArtProvider = ^NSData *{
        return rendition;
    };
    XCTAssertNotNil([self waitForThumbnailDecode:artwork]);
    XCTAssertNotNil(artwork.cachedThumbnail);
}

- (void)testMissingRenditionLeavesTheThumbnailRequestRetryable {
    AudioTrackArtwork *artwork = [self artworkWithExtractor:nil];
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];
    artwork.archivedDisplayArtProvider = ^NSData *{
        return nil; // evicted sidecar
    };
    XCTAssertNil([self waitForThumbnailDecode:artwork]);
    // The miss cleared the single-flight flag rather than stranding it: a
    // later pass — after a full-art load repopulates bytes — can request anew.
    XCTAssertNil([self waitForThumbnailDecode:artwork]);
}

- (void)testCopyCarriesTheProviderAndDataTransitionsClearIt {
    NSUInteger reads = 0;
    AudioTrackArtwork *artwork = [self archivedRowWithProviderData:[self embeddedArtData]
                                                             reads:&reads];
    AudioTrackArtwork *duplicate = [artwork copy];
    XCTAssertNotNil([duplicate loadArtBlocking], @"same file, same disk entry");
    XCTAssertEqual(reads, 1u);
    [artwork adoptParsedArtData:[self embeddedArtData]];
    XCTAssertNil(artwork.archivedDisplayArtProvider,
            @"a data transition orphans the archived rendition");
}

@end
