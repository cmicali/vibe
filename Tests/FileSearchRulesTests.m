//
//  FileSearchRulesTests.m
//  VibeTests
//
//  The iOS search screen's matching rules. Compiles here even though the header
//  only ships in VibeiOS: it is Foundation-only, and the two sections agreeing
//  on what a query matches is exactly the kind of thing a live app cannot be
//  asked about cheaply.
//

#import <XCTest/XCTest.h>

#import "FileSearchIndexInternal.h"
#import "FileSearchRules.h"

@interface FileSearchRulesTests : XCTestCase <FileSearchIndexDelegate>
@property (nonatomic) XCTestExpectation *buildFinished;
@property (nonatomic) NSMutableArray<NSURL *> *temporaryRoots;
@end

@implementation FileSearchRulesTests

- (void)setUp {
    [super setUp];
    self.temporaryRoots = [NSMutableArray array];
}

- (void)tearDown {
    for (NSURL *root in self.temporaryRoots) {
        [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
    }
    [super tearDown];
}

- (FileSearchIndex *)indexWithRelativeFilePaths:(NSArray<NSString *> *)paths {
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [self.temporaryRoots addObject:root];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:NULL]);
    for (NSString *path in paths) {
        NSURL *file = [root URLByAppendingPathComponent:path];
        XCTAssertTrue([NSFileManager.defaultManager
                createDirectoryAtURL:file.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:NULL]);
        XCTAssertTrue([[NSData data] writeToURL:file atomically:YES]);
    }

    FileSearchIndex *index = [[FileSearchIndex alloc] init];
    index.delegate = self;
    self.buildFinished = [self expectationWithDescription:@"index built"];
    [index setRoots:@[root]];
    [index beginBuildIfNeeded];
    [self waitForExpectations:@[self.buildFinished] timeout:1.0];
    index.delegate = nil;
    self.buildFinished = nil;
    return index;
}

- (void)fileSearchIndexDidGrow:(FileSearchIndex *)index {
}

- (void)fileSearchIndexDidFinishBuilding:(FileSearchIndex *)index {
    [self.buildFinished fulfill];
}

#pragma mark - Text

- (void)testEmptyQueryIsNoConstraint {
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"anything", @""));
    XCTAssertTrue(VibeSearchTextMatchesQuery(nil, @""));
}

- (void)testMatchesAnywhereNotJustThePrefix {
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"The Great Gig in the Sky", @"gig"));
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"The Great Gig in the Sky", @"Sky"));
    XCTAssertFalse(VibeSearchTextMatchesQuery(@"The Great Gig in the Sky", @"moon"));
}

- (void)testCaseAndDiacriticInsensitive {
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"Björk", @"bjork"));
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"Bjork", @"björk"));
    XCTAssertTrue(VibeSearchTextMatchesQuery(@"SIGUR RÓS", @"sigur ros"));
}

- (void)testPreparedFileSearchKeepsCaseDiacriticAndWidthSemantics {
    NSString *text = VibeSearchFoldedText(@"Ｂjörk — Jóga.flac\nHomogenic");
    XCTAssertTrue(VibeSearchFoldedTextContainsQuery(
            text, VibeSearchFoldedText(@"bjork")));
    XCTAssertTrue(VibeSearchFoldedTextContainsQuery(
            text, VibeSearchFoldedText(@"joga")));
    XCTAssertTrue(VibeSearchFoldedTextContainsQuery(
            text, VibeSearchFoldedText(@"homogenic")));
    XCTAssertFalse(VibeSearchFoldedTextContainsQuery(
            text, VibeSearchFoldedText(@"vespertine")));
}

- (void)testEmptyTextMatchesOnlyAnEmptyQuery {
    XCTAssertFalse(VibeSearchTextMatchesQuery(@"", @"a"));
    XCTAssertFalse(VibeSearchTextMatchesQuery(nil, @"a"));
}

#pragma mark - Tracks

- (void)testTrackMatchesAnyOfTitleArtistOrFilename {
    XCTAssertTrue(VibeSearchTrackMatchesQuery(@"Teardrop", @"Massive Attack", @"04 Teardrop.flac", @"tear"));
    XCTAssertTrue(VibeSearchTrackMatchesQuery(@"Teardrop", @"Massive Attack", @"04 Teardrop.flac", @"massive"));
    XCTAssertTrue(VibeSearchTrackMatchesQuery(@"Teardrop", @"Massive Attack", @"04 Teardrop.flac", @"flac"));
    XCTAssertFalse(VibeSearchTrackMatchesQuery(@"Teardrop", @"Massive Attack", @"04 Teardrop.flac", @"portishead"));
}

// An untagged track has no title and no artist; the filename is the whole
// answer, as it is everywhere else in the app.
- (void)testUntaggedTrackFallsBackToTheFilename {
    XCTAssertTrue(VibeSearchTrackMatchesQuery(nil, nil, @"unknown-04.mp3", @"unknown"));
    XCTAssertFalse(VibeSearchTrackMatchesQuery(nil, nil, @"unknown-04.mp3", @"teardrop"));
}

- (void)testEmptyQueryMatchesEveryTrack {
    XCTAssertTrue(VibeSearchTrackMatchesQuery(nil, nil, @"x.mp3", @""));
}

#pragma mark - Files

// A found file has no tags, so its folder is the album or artist and has to
// count: a query for the folder must find tracks named nothing like it.
- (void)testFileMatchesItsFolderName {
    XCTAssertTrue(VibeSearchFileMatchesQuery(@"01.mp3", @"Kid A", @"kid a"));
    XCTAssertTrue(VibeSearchFileMatchesQuery(@"Idioteque.mp3", @"Kid A", @"idiot"));
    XCTAssertFalse(VibeSearchFileMatchesQuery(@"01.mp3", @"Kid A", @"amnesiac"));
}

// The one place the files rule deliberately disagrees with the text rule: an
// empty query browses the playlist but must never dump the file tree.
- (void)testEmptyQueryMatchesNoFile {
    XCTAssertFalse(VibeSearchFileMatchesQuery(@"01.mp3", @"Kid A", @""));
}

- (void)testFileWithNoFolderNameStillMatchesOnItsOwnName {
    XCTAssertTrue(VibeSearchFileMatchesQuery(@"Idioteque.mp3", nil, @"idiot"));
    XCTAssertTrue(VibeSearchFileMatchesQuery(@"Idioteque.mp3", @"", @"idiot"));
}

#pragma mark - Root coverage

// The shared decision behind both the index's pruning and the settings list's
// "you already added a folder that reaches this one".
- (void)testARootCoversItself {
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music"));
}

- (void)testARootCoversWhatIsInsideIt {
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music/Albums/Kid A"));
}

- (void)testARootDoesNotCoverItsOwnParent {
    XCTAssertFalse(VibeSearchRootCoversPath(@"/Data/Music/Albums", @"/Data/Music"));
}

// The separator is the whole reason this is a function: on a bare prefix test
// "/Music" would swallow "/Music Videos" and that folder would never be walked.
- (void)testARootDoesNotCoverASiblingSharingItsPrefix {
    XCTAssertFalse(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music Videos"));
    XCTAssertFalse(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Musical"));
}

- (void)testATrailingSeparatorOnEitherSideChangesNothing {
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music/", @"/Data/Music/track.mp3"));
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music/"));
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music/", @"/Data/Music"));
}

- (void)testAnEmptyPathCoversNothingAndIsCoveredByNothing {
    XCTAssertFalse(VibeSearchRootCoversPath(@"", @"/Data/Music"));
    XCTAssertFalse(VibeSearchRootCoversPath(@"/Data/Music", @""));
}

#pragma mark - Persistent-root merging

- (void)testExistingAncestorAbsorbsARestoredOrLiveChild {
    NSArray<NSString *> *roots = @[@"/Data/Music", @"/Provider/Dropbox"];
    XCTAssertEqual(VibeSearchFolderCoveringRootIndex(
            roots, @"/Data/Music/Albums/Kid A"), 0u);
    XCTAssertEqual(VibeSearchFolderIndexesCoveredByRoot(
            roots, @"/Data/Music/Albums/Kid A").count, 0u);
}

- (void)testRestoredOrLiveAncestorReplacesEveryExistingChild {
    NSArray<NSString *> *roots = @[
        @"/Data/Music/Albums/Kid A",
        @"/Provider/Dropbox",
        @"/Data/Music/Singles"
    ];
    XCTAssertEqual(VibeSearchFolderCoveringRootIndex(roots, @"/Data/Music"), NSNotFound);
    NSMutableIndexSet *expected = [NSMutableIndexSet indexSetWithIndex:0];
    [expected addIndex:2];
    XCTAssertEqualObjects(VibeSearchFolderIndexesCoveredByRoot(roots, @"/Data/Music"),
                          expected);
}

- (void)testExactDuplicateTakesTheAbsorbPathOnly {
    NSArray<NSString *> *roots = @[@"/Data/Music"];
    XCTAssertEqual(VibeSearchFolderCoveringRootIndex(roots, @"/Data/Music"), 0u);
}

- (void)testRemovedParentSuppressesOnlyItsPendingSubtree {
    NSArray<NSString *> *removedRoots = @[@"/Data/Music"];
    XCTAssertTrue(VibeSearchPendingRestoreShouldBeSuppressed(
            removedRoots, @[], @"/Data/Music/Albums/Kid A"));
    XCTAssertFalse(VibeSearchPendingRestoreShouldBeSuppressed(
            removedRoots, @[], @"/Provider/Dropbox"));
}

- (void)testExplicitReAddSupersedesAnOlderParentRemoval {
    XCTAssertFalse(VibeSearchPendingRestoreShouldBeSuppressed(
            @[@"/Data/Music"], @[@"/Data/Music/Albums"],
            @"/Data/Music/Albums/Kid A"));
    XCTAssertTrue(VibeSearchPendingRestoreShouldBeSuppressed(
            @[@"/Data/Music"], @[@"/Provider/Dropbox"],
            @"/Data/Music/Albums/Kid A"));
}

#pragma mark - Root pruning

static NSArray<NSString *> *PrunedPaths(NSArray<NSString *> *paths) {
    NSMutableArray<NSURL *> *roots = [NSMutableArray array];
    for (NSString *path in paths) {
        [roots addObject:[NSURL fileURLWithPath:path isDirectory:YES]];
    }
    NSMutableArray<NSString *> *pruned = [NSMutableArray array];
    for (NSURL *root in [FileSearchIndex pruneNestedRoots:roots]) {
        [pruned addObject:root.URLByStandardizingPath.path];
    }
    return pruned;
}

- (void)testUnrelatedRootsAllSurvive {
    NSArray<NSString *> *pruned = PrunedPaths(@[@"/Data/Documents", @"/Provider/Dropbox"]);
    XCTAssertEqual(pruned.count, 2u);
}

// The bug this exists for: searchRoots names the open folder first and Documents
// second, so the covered root is the EARLIER one. Pruning only later roots kept
// both and listed the folder's files twice.
- (void)testAnAncestorListedSecondStillSwallowsTheFolderBeforeIt {
    XCTAssertEqualObjects(PrunedPaths(@[@"/Data/Documents/Music", @"/Data/Documents"]),
                          @[@"/Data/Documents"]);
}

- (void)testAnAncestorListedFirstSwallowsTheFolderAfterIt {
    XCTAssertEqualObjects(PrunedPaths(@[@"/Data/Documents", @"/Data/Documents/Music"]),
                          @[@"/Data/Documents"]);
}

- (void)testIdenticalRootsCollapseToOne {
    XCTAssertEqualObjects(PrunedPaths(@[@"/Data/Documents", @"/Data/Documents"]),
                          @[@"/Data/Documents"]);
}

// The separator is what keeps this apart: on a bare prefix test "/Music" covers
// "/Music Videos" and the second folder would never be walked.
- (void)testASiblingSharingAPrefixIsNotCovered {
    NSArray<NSString *> *pruned = PrunedPaths(@[@"/Data/Music", @"/Data/Music Videos"]);
    XCTAssertEqual(pruned.count, 2u);
}

- (void)testDeepNestingCollapsesToTheOutermostRoot {
    XCTAssertEqualObjects(PrunedPaths(@[@"/a/b/c/d", @"/a/b/c", @"/a"]), @[@"/a"]);
}

- (void)testNoRootsIsNoRoots {
    XCTAssertEqualObjects([FileSearchIndex pruneNestedRoots:@[]], @[]);
}

#pragma mark - Async file filtering

- (void)testAsyncFilteringExcludesPlaylistAndDeliversOnMain {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01 Everything.mp3",
        @"Music/Kid A/02 Kid A.flac",
        @"Music/Amnesiac/01 Packt.wav"
    ]];

    XCTestExpectation *foundExcluded = [self expectationWithDescription:@"excluded path found"];
    __block NSString *excludedPath;
    [index requestHitsMatchingQuery:@"everything" excluding:nil limit:1
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 1u);
        excludedPath = hits.firstObject.url.path;
        [foundExcluded fulfill];
    }];
    [self waitForExpectations:@[foundExcluded] timeout:1.0];
    if (!excludedPath) {
        return;
    }

    XCTestExpectation *delivered = [self expectationWithDescription:@"hits delivered"];
    __block BOOL requestReturned = NO;
    [index requestHitsMatchingQuery:@"kid a"
                          excluding:[NSSet setWithObject:excludedPath]
                              limit:1
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertTrue(requestReturned);
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqual(hits.count, 1u);
        XCTAssertEqualObjects(hits.firstObject.fileName, @"02 Kid A.flac");
        [delivered fulfill];
    }];
    requestReturned = YES;
    [self waitForExpectations:@[delivered] timeout:1.0];
}

- (void)testNewRequestDeterministicallySupersedesPendingFiltering {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01 Everything.mp3",
        @"Music/Amnesiac/01 Packt.wav"
    ]];

    XCTestExpectation *old = [self expectationWithDescription:@"old request dropped"];
    old.inverted = YES;
    XCTestExpectation *latest = [self expectationWithDescription:@"latest request delivered"];
    [index requestHitsMatchingQuery:@"kid" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        [old fulfill];
    }];
    [index requestHitsMatchingQuery:@"amnesiac" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 1u);
        XCTAssertEqualObjects(hits.firstObject.folderName, @"Amnesiac");
        [latest fulfill];
    }];
    [self waitForExpectations:@[latest, old] timeout:0.2];
}

- (void)testCancellationDropsAPendingDelivery {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01 Everything.mp3"
    ]];
    XCTestExpectation *delivery = [self expectationWithDescription:@"cancelled delivery"];
    delivery.inverted = YES;
    [index requestHitsMatchingQuery:@"kid" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        [delivery fulfill];
    }];
    [index cancelPendingHitRequests];
    [self waitForExpectations:@[delivery] timeout:0.1];
}

- (void)testRepeatedQueryFiltersOnlyTheNewlyAppendedSuffix {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01 Everything.mp3",
        @"Music/Amnesiac/01 Packt.wav"
    ]];

    XCTestExpectation *initial = [self expectationWithDescription:@"initial query"];
    [index requestHitsMatchingQuery:@"kid" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 1u);
        [initial fulfill];
    }];
    [self waitForExpectations:@[initial] timeout:1.0];
    XCTAssertEqual(index.lastFilterEvaluationCountForTesting, 2u);

    NSURL *newURL = [NSURL fileURLWithPath:@"/Music/Kid A/02 Kid A.flac"];
    [index appendFileURLForTesting:newURL];
    XCTestExpectation *incremental = [self expectationWithDescription:@"incremental query"];
    [index requestHitsMatchingQuery:@"kid" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 2u);
        [incremental fulfill];
    }];
    [self waitForExpectations:@[incremental] timeout:1.0];
    XCTAssertEqual(index.lastFilterEvaluationCountForTesting, 1u);
}

@end
