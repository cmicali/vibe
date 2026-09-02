//
// Resolver ordering, invalidation, input validation and memory bounds.
//

#import <XCTest/XCTest.h>

#import "FolderArtRules.h"
#import "FolderArtResolverInternal.h"

@interface FolderArtResolverTests : XCTestCase
@end

@implementation FolderArtResolverTests

- (FolderArtResolver *)resolverWithFileInfo:(FolderArtFileInfoProvider)fileInfo
                              dataReader:(FolderArtDataReader)dataReader
                                 decoder:(FolderArtDecoder)decoder {
    return [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        return @[@"cover.jpg"];
    } fileInfo:fileInfo dataReader:dataReader decoder:decoder];
}

- (void)testInvalidateFencesAnInFlightDecode {
    dispatch_semaphore_t decodeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueDecode = dispatch_semaphore_create(0);
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        dispatch_semaphore_signal(decodeStarted);
        dispatch_semaphore_wait(continueDecode, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/One";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];

    XCTestExpectation *finished = [self expectationWithDescription:@"stale decode returned"];
    __block NSImage *result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [resolver displayImageForAudioFilePath:track];
        [finished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(decodeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    [resolver invalidate];
    dispatch_semaphore_signal(continueDecode);
    [self waitForExpectations:@[finished] timeout:2.0];

    XCTAssertNil(result);
    XCTAssertNil([resolver cachedDisplayImageForAudioFilePath:track]);
}

- (void)testAuthoritativeListingSupersedesAnOlderProbe {
    dispatch_semaphore_t probeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueProbe = dispatch_semaphore_create(0);
    __block NSString *readPath = nil;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        if ([path.lastPathComponent isEqualToString:@"cover.jpg"]) {
            dispatch_semaphore_signal(probeStarted);
            dispatch_semaphore_wait(continueProbe, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        }
        return YES;
    } dataReader:^NSData *(NSString *path) {
        readPath = path;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Two";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];

    XCTestExpectation *oldProbeFinished = [self expectationWithDescription:@"old probe returned"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        XCTAssertNil([resolver displayImageForAudioFilePath:track]);
        [oldProbeFinished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(probeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"folder.jpg"}];
    dispatch_semaphore_signal(continueProbe);
    [self waitForExpectations:@[oldProbeFinished] timeout:2.0];

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqualObjects(readPath, [directory stringByAppendingPathComponent:@"folder.jpg"]);
}

- (void)testFinalReadRejectsASymbolicLinkCandidate {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES attributes:nil error:nil]);
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }];
    NSImage *source = [[NSImage alloc] initWithSize:NSMakeSize(2, 2)];
    [source lockFocus];
    [NSColor.redColor setFill];
    NSRectFill(NSMakeRect(0, 0, 2, 2));
    [source unlockFocus];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:source.TIFFRepresentation];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *target = [directory stringByAppendingPathComponent:@"actual.png"];
    XCTAssertTrue([png writeToFile:target atomically:YES]);
    NSString *candidate = [directory stringByAppendingPathComponent:@"cover.jpg"];
    XCTAssertTrue([NSFileManager.defaultManager createSymbolicLinkAtPath:candidate
                                                     withDestinationPath:target error:nil]);

    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *path) {
        return YES;
    }];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];
    XCTAssertNil([resolver displayImageForAudioFilePath:
            [directory stringByAppendingPathComponent:@"track.mp3"]]);
}

- (void)testFinalReadRejectsAnOversizedListedCandidate {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtPath:directory
                                          withIntermediateDirectories:YES attributes:nil error:nil]);
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    }];
    NSString *candidate = [directory stringByAppendingPathComponent:@"cover.jpg"];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:candidate contents:NSData.data attributes:nil]);
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:candidate];
    [handle truncateFileAtOffset:20ull * 1024 * 1024 + 1];
    [handle closeFile];

    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *path) {
        return YES;
    }];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];
    XCTAssertNil([resolver displayImageForAudioFilePath:
            [directory stringByAppendingPathComponent:@"track.mp3"]]);
}

- (void)testRecordedDirectoryStateIsBounded {
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return NO;
    } dataReader:^NSData *(NSString *path) {
        return nil;
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return nil;
    }];
    NSMutableSet<NSString *> *directories = [NSMutableSet set];
    for (NSUInteger index = 0; index < 5000; index++) {
        [directories addObject:[NSString stringWithFormat:@"/Library/Albums/%lu", index]];
    }
    [resolver noteListedDirectories:directories artFilenameByDirectory:@{}];
    XCTAssertLessThanOrEqual(resolver.recordedDirectoryCount, 4096u);
}

// Eviction batches down to a floor rather than running once per new folder, so
// the sort it costs is paid about once per (limit - floor) arrivals. Landing
// exactly on the limit would mean a per-entry trim.
- (void)testEvictionBatchesBelowTheLimit {
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return NO;
    } dataReader:^NSData *(NSString *path) {
        return nil;
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return nil;
    }];
    NSMutableSet<NSString *> *directories = [NSMutableSet set];
    for (NSUInteger index = 0; index < 4097; index++) {
        [directories addObject:[NSString stringWithFormat:@"/Library/Batched/%lu", index]];
    }
    [resolver noteListedDirectories:directories artFilenameByDirectory:@{}];
    XCTAssertEqual(resolver.recordedDirectoryCount, 3072u);
}

#pragma mark - Whether a background load is worth dispatching

// This answer drives artNeedsLoad, and through it the header's decision
// to dispatch a load at all. A wrong NO is a permanently blank header; a wrong
// YES re-dispatches the same doomed load on every UI tick.
- (void)testTheBackgroundLoadTruthTable {
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    XCTAssertTrue([resolver needsBackgroundLoadForAudioFilePath:@"/Library/Albums/Unknown/track.mp3"],
                  @"never looked at: worth a load");

    NSString *withCover = @"/Library/Albums/HasCover";
    [resolver noteListedDirectories:[NSSet setWithObject:withCover]
             artFilenameByDirectory:@{withCover: @"cover.jpg"}];
    NSString *coveredTrack = [withCover stringByAppendingPathComponent:@"track.mp3"];
    XCTAssertTrue([resolver needsBackgroundLoadForAudioFilePath:coveredTrack],
                  @"a cover is known to exist but nothing is decoded yet");

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:coveredTrack], decoded);
    XCTAssertFalse([resolver needsBackgroundLoadForAudioFilePath:coveredTrack],
                   @"the display image is cached: nothing left to load");

    NSString *bare = @"/Library/Albums/Bare";
    [resolver noteListedDirectories:[NSSet setWithObject:bare] artFilenameByDirectory:@{}];
    XCTAssertFalse([resolver needsBackgroundLoadForAudioFilePath:
                    [bare stringByAppendingPathComponent:@"track.mp3"]],
                   @"settled as artless: a load would find nothing, forever");
}

#pragma mark - The setting

// Off means off: every accessor answers nil and NOTHING touches the disk, so
// the switch cannot cost a single syscall.
- (void)testTheSettingOffAnswersNilAndTouchesNothing {
    __block BOOL enabled = NO;
    __block NSUInteger fileSystemCalls = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return enabled;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        fileSystemCalls++;
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        fileSystemCalls++;
        return YES;
    } dataReader:^NSData *(NSString *path) {
        fileSystemCalls++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Switched";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];

    XCTAssertNil([resolver displayImageForAudioFilePath:track]);
    XCTAssertNil([resolver cachedDisplayImageForAudioFilePath:track]);
    XCTAssertNil([resolver cachedThumbnailForAudioFilePath:track resolveIfUnknown:YES]);
    XCTAssertFalse([resolver needsBackgroundLoadForAudioFilePath:track]);
    XCTAssertEqual(fileSystemCalls, 0u);

    // Switching it on gets the answer the walk recorded while it was off rather
    // than starting from guesswork, which also proves folderArtSettingDidChange
    // — the one call every writer of the setting makes — keeps settled answers.
    enabled = YES;
    [resolver folderArtSettingDidChange];
    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqualObjects([resolver settledArtPathForDirectory:directory],
                          [directory stringByAppendingPathComponent:@"cover.jpg"]);
}

#pragma mark - The cost model

// The bill every coverless folder in a library pays, once, ever.
- (void)testACoverlessFolderIsProbedOnceAndNeverAgain {
    __block NSUInteger probes = 0;
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        probes++;
        return NO;
    } dataReader:^NSData *(NSString *path) {
        return nil;
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return nil;
    }];
    NSString *directory = @"/Library/Albums/Coverless";
    for (NSUInteger i = 0; i < 50; i++) {
        NSString *name = [NSString stringWithFormat:@"track%lu.mp3", i];
        NSString *track = [directory stringByAppendingPathComponent:name];
        XCTAssertNil([resolver displayImageForAudioFilePath:track]);
    }
    XCTAssertEqual(probes, (NSUInteger)kVibeFolderArtStatProbeCount);
}

// Per folder, never per track: an album of a thousand tracks reads its cover
// once and shares it.
- (void)testAThousandTracksInOneFolderCostOneRead {
    __block NSUInteger reads = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        reads++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Long";
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];
    for (NSUInteger i = 0; i < 1000; i++) {
        NSString *name = [NSString stringWithFormat:@"track%lu.mp3", i];
        NSString *track = [directory stringByAppendingPathComponent:name];
        XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    }
    XCTAssertEqual(reads, 1u);
}

// The non-resolving accessor is what a playlist cell calls while drawing. It
// must never schedule work, or scrolling a big playlist becomes a disk storm.
- (void)testTheNonResolvingAccessorSchedulesNothing {
    __block NSUInteger fileSystemCalls = 0;
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        fileSystemCalls++;
        return YES;
    } dataReader:^NSData *(NSString *path) {
        fileSystemCalls++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    }];
    for (NSUInteger i = 0; i < 20; i++) {
        XCTAssertNil([resolver cachedThumbnailForAudioFilePath:@"/Library/Albums/Cold/track.mp3"
                                              resolveIfUnknown:NO]);
    }
    XCTAssertEqual(fileSystemCalls, 0u);
}

// Which strategy a folder gets is decided by how the user opened it: a bulk
// open is already doing bulk I/O, so one listing buys every spelling; a lone
// file has nothing to piggyback on and probes instead.
- (void)testABulkOpenListsWhereALoneFileProbes {
    __block NSUInteger listings = 0, probes = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *(^makeResolver)(void) = ^FolderArtResolver *(void) {
        return [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
            return YES;
        } accessProvider:^BOOL(NSString *directory) {
            return YES;
        } lister:^NSArray<NSString *> *(NSString *directory) {
            listings++;
            return @[@"front.png"];
        } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
            probes++;
            return YES;
        } dataReader:^NSData *(NSString *path) {
            return [NSData dataWithBytes:"x" length:1];
        } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
            return decoded;
        }];
    };
    NSString *directory = @"/Library/Albums/Strategy";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];

    FolderArtResolver *loneFile = makeResolver();
    XCTAssertEqualObjects([loneFile displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(listings, 0u, @"a lone file has no listing to piggyback on");
    XCTAssertGreaterThan(probes, 0u);

    listings = 0; probes = 0;
    FolderArtResolver *bulk = makeResolver();
    [bulk preferListingForDirectories:[NSSet setWithObject:directory]];
    XCTAssertEqualObjects([bulk displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(listings, 1u, @"one listing, which finds front.png that no probe asks about");
}

// How the user opened a folder is a fact about the open, not a cached answer,
// so a setting change leaves it alone — otherwise the toggle would silently
// demote a bulk-opened folder to the lone file's guesswork.
- (void)testTheListingPreferenceOutlivesASettingChange {
    __block NSUInteger listings = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        listings++;
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/StillBulk";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver preferListingForDirectories:[NSSet setWithObject:directory]];

    [resolver folderArtSettingDidChange];

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(listings, 1u);
}

#pragma mark - Concurrency

// Folder walks run four wide, so several threads settle answers at once.
- (void)testConcurrentListingsSettleEveryFolderExactlyOnce {
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    }];
    const size_t walkers = 8, perWalker = 50;
    dispatch_apply(walkers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t walker) {
        for (NSUInteger i = 0; i < perWalker; i++) {
            NSString *directory = [NSString stringWithFormat:@"/Library/Concurrent/%zu-%lu", walker, i];
            [resolver noteListedDirectories:[NSSet setWithObject:directory]
                     artFilenameByDirectory:@{directory: @"cover.jpg"}];
        }
    });
    for (size_t walker = 0; walker < walkers; walker++) {
        for (NSUInteger i = 0; i < perWalker; i++) {
            NSString *directory = [NSString stringWithFormat:@"/Library/Concurrent/%zu-%lu", walker, i];
            XCTAssertEqualObjects([resolver settledArtPathForDirectory:directory],
                                  [directory stringByAppendingPathComponent:@"cover.jpg"]);
        }
    }
    XCTAssertEqual(resolver.recordedDirectoryCount, (NSUInteger)(walkers * perWalker));
}

// What the resolve claim is for: two asks for the same UNRESOLVED folder must
// not both walk it, since a bulk-opened folder resolves by listing and that
// would list one directory twice. (A folder whose answer is already settled
// decodes without the claim — see displayImageForAudioFilePath: — so two
// simultaneous asks there may both decode, at the cost of one duplicate read.)
- (void)testTwoConcurrentAsksForOneUnresolvedFolderWalkItOnce {
    dispatch_semaphore_t probeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueProbe = dispatch_semaphore_create(0);
    __block NSUInteger probes = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        @synchronized (self) { probes++; }
        dispatch_semaphore_signal(probeStarted);
        dispatch_semaphore_wait(continueProbe, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *track = @"/Library/Albums/Contended/track.mp3";

    XCTestExpectation *first = [self expectationWithDescription:@"first ask"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [resolver displayImageForAudioFilePath:track];
        [first fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(probeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);

    // The second arrives while the first still holds the claim.
    XCTestExpectation *second = [self expectationWithDescription:@"second ask"];
    __block NSImage *loser = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        loser = [resolver displayImageForAudioFilePath:track];
        [second fulfill];
    });
    [self waitForExpectations:@[second] timeout:5.0];
    XCTAssertNil(loser, @"it goes without for this pass rather than walking the folder again");

    dispatch_semaphore_signal(continueProbe);
    [self waitForExpectations:@[first] timeout:5.0];
    XCTAssertEqual(probes, 1u, @"one walk, not two");
}

- (void)testBlockingResolveNotifiesARowThatSkippedItsOwnJob {
    dispatch_semaphore_t probeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueProbe = dispatch_semaphore_create(0);
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(
            NSString *path, unsigned long long *size) {
        dispatch_semaphore_signal(probeStarted);
        dispatch_semaphore_wait(continueProbe,
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *track = @"/Library/Albums/HeaderAndRow/track.mp3";

    XCTestExpectation *displayFinished = [self expectationWithDescription:@"display resolved"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [resolver displayImageForAudioFilePath:track];
        [displayFinished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(probeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);

    XCTestExpectation *redraw = [self expectationForNotification:FolderArtDidResolveNotification
                                                          object:resolver handler:nil];
    XCTAssertNil([resolver cachedThumbnailForAudioFilePath:track resolveIfUnknown:YES],
                 @"the header still owns the directory's resolve claim");

    dispatch_semaphore_signal(continueProbe);
    [self waitForExpectations:@[displayFinished, redraw] timeout:5.0];
    XCTAssertEqualObjects([resolver cachedThumbnailForAudioFilePath:track
                                                    resolveIfUnknown:NO], decoded);
}

// A cover replaced while its decode is in flight: the finished image belongs
// to the old file and must not be cached against the new answer.
- (void)testAReplacedCoverDoesNotCacheTheOldDecode {
    dispatch_semaphore_t decodeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueDecode = dispatch_semaphore_create(0);
    NSImage *stale = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    NSImage *fresh = [[NSImage alloc] initWithSize:NSMakeSize(2, 2)];
    __block NSString *readPath = nil;
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        readPath = path;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        if ([readPath.lastPathComponent isEqualToString:@"cover.jpg"]) {
            dispatch_semaphore_signal(decodeStarted);
            dispatch_semaphore_wait(continueDecode, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            return stale;
        }
        return fresh;
    }];
    NSString *directory = @"/Library/Albums/Replaced";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];

    XCTestExpectation *finished = [self expectationWithDescription:@"stale decode returned"];
    __block NSImage *result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [resolver displayImageForAudioFilePath:track];
        [finished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(decodeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    // The folder is re-listed with a different cover while that decode runs.
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"folder.jpg"}];
    dispatch_semaphore_signal(continueDecode);
    [self waitForExpectations:@[finished] timeout:5.0];

    XCTAssertNil(result, @"the answer it decoded is no longer the folder's answer");
    XCTAssertNotEqualObjects([resolver cachedDisplayImageForAudioFilePath:track], stale);
}

#pragma mark - What a grant change may forget

// Opening a folder harvests its cover from the walk for free, and the auto-add
// posts a grant change milliseconds later. Answering that with a full
// invalidate discards the harvest, leaving the re-resolve to the lone-file stat
// probes, which know only three names — so on the FIRST open of any folder a
// cover.png would silently not exist.
- (void)testAGrantChangeKeepsACoverAlreadyFound {
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    __block NSUInteger listings = 0;
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return YES;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        listings++;
        return @[];   // a re-resolve would find nothing, so a lost answer shows
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        // Only the walked cover exists. The three stat probes are all .jpg, so
        // a re-resolve after a wrongly-broad invalidate finds nothing.
        return [path.lastPathComponent isEqualToString:@"cover.png"];
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Walked";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    // A cover only the walk can know about: cover.png is not a stat probe.
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.png"}];

    [resolver invalidateDirectoriesSettledWithoutGrant];

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(listings, 0u, @"the walk's answer should have been used, not re-resolved");
}

// A donated cover path can outlive the scope that made the listing. If its
// decoded images are later evicted, reopening that known path still requires a
// currently active grant; the path itself survives so restoring access does not
// demote a cover.png to the lone-file .jpg probes.
- (void)testARevokedGrantBlocksKnownCoverReadsUntilAccessReturns {
    __block BOOL granted = YES;
    __block NSUInteger reads = 0;
    __block NSUInteger probes = 0;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [[FolderArtResolver alloc]
            initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return granted;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        return @[];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        probes++;
        return NO;
    } dataReader:^NSData *(NSString *path) {
        reads++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Revoked";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    NSString *cover = [directory stringByAppendingPathComponent:@"cover.png"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.png"}];

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(reads, 1u);
    [resolver folderArtSettingDidChange]; // deterministically evicts decoded images

    granted = NO;
    [resolver invalidateDirectoriesSettledWithoutGrant];
    XCTAssertNil([resolver displayImageForAudioFilePath:track]);
    XCTAssertEqual(reads, 1u, @"revocation must be observed before the file reader runs");
    XCTAssertFalse([resolver needsBackgroundLoadForAudioFilePath:track],
                   @"a blocked path must not dispatch again on every UI pass");
    XCTAssertNil([resolver displayImageForAudioFilePath:track]);
    XCTAssertEqual(reads, 1u);

    granted = YES;
    [resolver invalidateDirectoriesSettledWithoutGrant];
    XCTAssertTrue([resolver needsBackgroundLoadForAudioFilePath:track]);
    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(reads, 2u);
    XCTAssertEqual(probes, 0u, @"restoring access must reuse the donated cover path");
    XCTAssertEqualObjects([resolver settledArtPathForDirectory:directory], cover);
}

// The other half: a folder skipped for want of a grant is exactly what a grant
// change must forget, or the art never appears until the app restarts.
- (void)testAGrantChangeForgetsTheFoldersItLeftAlone {
    __block BOOL granted = NO;
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [[FolderArtResolver alloc] initWithEnabledProvider:^BOOL{
        return YES;
    } accessProvider:^BOOL(NSString *directory) {
        return granted;
    } lister:^NSArray<NSString *> *(NSString *directory) {
        return @[@"cover.jpg"];
    } fileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Ungranted";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];

    XCTAssertNil([resolver displayImageForAudioFilePath:track]);

    granted = YES;
    // Without the invalidation the folder stays settled as artless forever.
    XCTAssertNil([resolver displayImageForAudioFilePath:track]);
    [resolver invalidateDirectoriesSettledWithoutGrant];
    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
}

// The header's decode leaves the row thumbnail behind, so the cover file is
// opened once for both sizes rather than again the moment a row draws.
- (void)testTheDisplayDecodeAlsoProducesTheThumbnailFromOneRead {
    __block NSUInteger reads = 0;
    __block NSMutableArray<NSNumber *> *decodedSizes = [NSMutableArray array];
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        reads++;
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        [decodedSizes addObject:@(maxPixelSize)];
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/OneRead";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];

    XCTAssertEqualObjects([resolver displayImageForAudioFilePath:track], decoded);
    XCTAssertEqual(reads, 1u);
    XCTAssertEqual(decodedSizes.count, 2u);
    // The thumbnail is cached, so a row drawing now costs no read at all.
    XCTAssertEqualObjects([resolver cachedThumbnailForAudioFilePath:track resolveIfUnknown:NO], decoded);
    XCTAssertEqual(reads, 1u);
}

// A settled cover decodes without the resolve claim, so eviction has to be told
// about it some other way: dropping its answerGeneration mid-decode would make the
// finished image fail its own currency check and vanish.
- (void)testEvictionLeavesADecodeInFlightAlone {
    dispatch_semaphore_t decodeStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t continueDecode = dispatch_semaphore_create(0);
    NSImage *decoded = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    FolderArtResolver *resolver = [self resolverWithFileInfo:^BOOL(NSString *path, unsigned long long *size) {
        return YES;
    } dataReader:^NSData *(NSString *path) {
        return [NSData dataWithBytes:"x" length:1];
    } decoder:^NSImage *(NSData *data, CGFloat maxPixelSize) {
        dispatch_semaphore_signal(decodeStarted);
        dispatch_semaphore_wait(continueDecode, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        return decoded;
    }];
    NSString *directory = @"/Library/Albums/Pinned";
    NSString *track = [directory stringByAppendingPathComponent:@"track.mp3"];
    [resolver noteListedDirectories:[NSSet setWithObject:directory]
             artFilenameByDirectory:@{directory: @"cover.jpg"}];

    XCTestExpectation *finished = [self expectationWithDescription:@"decode returned"];
    __block NSImage *result = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        result = [resolver displayImageForAudioFilePath:track];
        [finished fulfill];
    });
    XCTAssertEqual(dispatch_semaphore_wait(decodeStarted,
            dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    // Overflow the history while that decode is still running.
    NSMutableSet<NSString *> *flood = [NSMutableSet set];
    for (NSUInteger index = 0; index < 5000; index++) {
        [flood addObject:[NSString stringWithFormat:@"/Library/Flood/%lu", index]];
    }
    [resolver noteListedDirectories:flood artFilenameByDirectory:@{}];
    dispatch_semaphore_signal(continueDecode);
    [self waitForExpectations:@[finished] timeout:5.0];

    XCTAssertEqualObjects(result, decoded);
}

@end
