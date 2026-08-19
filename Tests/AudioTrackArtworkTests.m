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
    XCTAssertNotEqualObjects(artwork.cachedThumbnail, _folderCover);
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
    XCTAssertNil(artwork.embeddedThumbnail);
}

- (void)testTheArchivableThumbnailIsTheFilesOwnArtWhenItHasSome {
    NSData *embedded = [self embeddedArtData];
    AudioTrackArtwork *artwork = [self artworkWithExtractor:^VibeEmbeddedArtExtractionResult(
            NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    (void)[artwork loadArtBlocking]; // decode it
    XCTAssertNotNil(artwork.embeddedThumbnail);
    XCTAssertNotEqualObjects(artwork.embeddedThumbnail, _folderCover);
}

// The metadata scan calls this before publishing a row. It must warm the
// file's own thumbnail WITHOUT resolving folder art, or a playlist scan turns
// into a folder-art storm across every artless row.
- (void)testThePrewarmNeverTouchesTheFolder {
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

    [artwork prewarmEmbeddedThumbnail];

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
    NSImage *thumbnail = artwork.cachedThumbnail;
    XCTAssertNotNil(thumbnail);
    XCTAssertNotEqualObjects(thumbnail, _folderCover);
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

@end
