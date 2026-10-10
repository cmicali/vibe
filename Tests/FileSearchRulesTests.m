//
//  FileSearchRulesTests.m
//  VibeTests
//
//  What a search matches, and the Files tab's decisions: the root's rows, what
//  Recents names for a link, which open the next launch restores, and the
//  recents a launch's pruning keeps. The header ships only in VibeiOS but is
//  Foundation-only, so it compiles here.
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
    [self waitForExpectations:@[self.buildFinished] timeout:VIBE_TEST_HANG_TIMEOUT];
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

- (void)testUntaggedTrackFallsBackToTheFilename {
    XCTAssertTrue(VibeSearchTrackMatchesQuery(nil, nil, @"unknown-04.mp3", @"unknown"));
    XCTAssertFalse(VibeSearchTrackMatchesQuery(nil, nil, @"unknown-04.mp3", @"teardrop"));
}

- (void)testEmptyQueryMatchesEveryTrack {
    XCTAssertTrue(VibeSearchTrackMatchesQuery(nil, nil, @"x.mp3", @""));
}

#pragma mark - Root coverage

// Shared by the index's pruning and the settings list's "already covered".
- (void)testARootCoversItself {
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music"));
}

- (void)testARootCoversWhatIsInsideIt {
    XCTAssertTrue(VibeSearchRootCoversPath(@"/Data/Music", @"/Data/Music/Albums/Kid A"));
}

- (void)testARootDoesNotCoverItsOwnParent {
    XCTAssertFalse(VibeSearchRootCoversPath(@"/Data/Music/Albums", @"/Data/Music"));
}

// On a bare prefix test "/Music" would swallow "/Music Videos".
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

// searchRoots names the open folder before Documents, so the covered root can
// be the EARLIER one; pruning only later roots would list its files twice.
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
    [self waitForExpectations:@[foundExcluded] timeout:VIBE_TEST_HANG_TIMEOUT];
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
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// A found file has no tags, so its folder stands in for album and artist.
- (void)testFileMatchesItsFolderName {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01.mp3",
        @"Music/Amnesiac/Idioteque.mp3"
    ]];
    XCTestExpectation *delivered = [self expectationWithDescription:@"hits delivered"];
    [index requestHitsMatchingQuery:@"kid a" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 1u);
        XCTAssertEqualObjects(hits.firstObject.fileName, @"01.mp3");
        [delivered fulfill];
    }];
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// Unlike the playlist's text rule: an empty query browses the playlist but must
// never dump the file tree.
- (void)testEmptyQueryFindsNoFile {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01.mp3"
    ]];
    XCTestExpectation *delivered = [self expectationWithDescription:@"hits delivered"];
    [index requestHitsMatchingQuery:@"" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 0u);
        [delivered fulfill];
    }];
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
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
    [self waitForExpectations:@[latest] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForExpectations:@[old] timeout:0.2];
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
    [self waitForExpectations:@[initial] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(index.lastFilterEvaluationCountForTesting, 2u);

    NSURL *newURL = [NSURL fileURLWithPath:@"/Music/Kid A/02 Kid A.flac"];
    [index appendFileURLForTesting:newURL];
    XCTestExpectation *incremental = [self expectationWithDescription:@"incremental query"];
    [index requestHitsMatchingQuery:@"kid" excluding:nil limit:10
                         completion:^(NSArray<FileSearchHit *> *hits) {
        XCTAssertEqual(hits.count, 2u);
        [incremental fulfill];
    }];
    [self waitForExpectations:@[incremental] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(index.lastFilterEvaluationCountForTesting, 1u);
}

#pragma mark - The root's rows

- (void)testOpenURLIsTheLastLocationsRowAfterBrowseFiles {
    NSArray *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 2, NO);
    NSArray *expected = @[@(VibeBrowserRootRowLocation), @(VibeBrowserRootRowLocation), @(VibeBrowserRootRowAddFolder),
                          @(VibeBrowserRootRowBrowseFiles), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(rows, expected, @"a location's row is its index in the store");
}

- (void)testThePasteRowFollowsOpenURLOnlyWithALinkOnTheClipboard {
    NSArray *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 1, YES);
    NSArray *expected = @[@(VibeBrowserRootRowLocation), @(VibeBrowserRootRowAddFolder),
                          @(VibeBrowserRootRowBrowseFiles), @(VibeBrowserRootRowOpenURL), @(VibeBrowserRootRowPasteURL)];
    XCTAssertEqualObjects(rows, expected);
    XCTAssertFalse([VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 1, NO)
            containsObject:@(VibeBrowserRootRowPasteURL)]);
    for (NSInteger section = VibeBrowserRootSectionSources; section < VibeBrowserRootSectionLocations; section++) {
        XCTAssertFalse([VibeBrowserRootRows((VibeBrowserRootSection)section, YES, 1, YES)
                containsObject:@(VibeBrowserRootRowPasteURL)]);
    }
}

- (void)testConnectDropboxIsOfferedOnlyUntilLinked {
    NSArray *unlinked = VibeBrowserRootRows(VibeBrowserRootSectionLocations, NO, 0, NO);
    NSArray *expected = @[@(VibeBrowserRootRowConnectDropbox), @(VibeBrowserRootRowAddFolder),
                          @(VibeBrowserRootRowBrowseFiles), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(unlinked, expected);
    XCTAssertFalse([VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 0, NO)
            containsObject:@(VibeBrowserRootRowConnectDropbox)]);
}

- (void)testTheSourcesAndRecentsSections {
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionSources, NO, 3, NO), @[@(VibeBrowserRootRowDevice)]);
    NSArray *linked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowDropbox)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionSources, YES, 3, NO), linked);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionRecents, YES, 3, NO), @[@(VibeBrowserRootRowRecents)]);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionCount, YES, 3, NO), @[]);
}

#pragma mark - Recents

- (void)testTheRecentsURLsAreTheirPaths {
    NSArray *items = @[@{@"path": @"/a/Song.mp3", @"folder": @NO},
                       @{@"path": @"/b", @"folder": @YES},
                       @{@"folder": @NO},
                       @{@"path": @""},
                       @"not an item"];
    NSArray<NSURL *> *urls = VibeRecentItemURLs(items);
    XCTAssertEqual(urls.count, 2u);
    XCTAssertEqualObjects(urls[0].path, @"/a/Song.mp3");
    XCTAssertEqualObjects(urls[1].path, @"/b");
    XCTAssertTrue(urls[0].isFileURL);
}

#pragma mark - The restored playlist

- (void)testAOneFileOpenKeepsAFolderBookmark {
    XCTAssertFalse(VibeFolderSessionPersistsBase(NO, NO, YES, NO), @"a mirror file too: it is not a link");
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, NO, NO, NO), @"over a file bookmark, or none");
}

- (void)testALinkOpenedAloneReplacesAFolderBookmark {
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, NO, YES, YES));
}

- (void)testAnOpenThatBroughtAFolderPersists {
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, YES, YES, NO));
}

- (void)testAnOpenInsideAOneOffPickKeepsTheSessions {
    XCTAssertFalse(VibeFolderSessionPersistsBase(YES, YES, NO, NO));
    XCTAssertFalse(VibeFolderSessionPersistsBase(YES, NO, NO, YES));
}

@end
