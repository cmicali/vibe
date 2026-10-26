
#import "IOSShellTestCase.h"

#import "FilePaths.h"
#import "FileSearchIndexInternal.h"
#import "FileSearchRules.h"
#import "FolderSessionRules.h"

@interface FileSearchRulesTests : IOSShellTestCase <FileSearchIndexDelegate>
@property (nonatomic) XCTestExpectation *buildFinished;
@end

@implementation FileSearchRulesTests

// An index over the harness's root, holding these files.
- (FileSearchIndex *)indexWithRelativeFilePaths:(NSArray<NSString *> *)paths {
    return [self indexWithRelativeFilePaths:paths cap:0];
}

// The same, capped at `cap` files unless it is 0.
- (FileSearchIndex *)indexWithRelativeFilePaths:(NSArray<NSString *> *)paths cap:(NSUInteger)cap {
    for (NSString *path in paths) {
        [self file:path];
    }

    FileSearchIndex *index = [[FileSearchIndex alloc] init];
    if (cap > 0) {
        index.maxIndexedFilesForTesting = cap;
    }
    index.delegate = self;
    self.buildFinished = [self expectationWithDescription:@"index built"];
    [index setRoots:@[self.root]];
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

- (NSArray<FileSearchHit *> *)hitsOf:(FileSearchIndex *)index matching:(NSString *)query {
    XCTestExpectation *delivered = [self expectationWithDescription:@"hits delivered"];
    __block NSArray<FileSearchHit *> *answer = @[];
    [index requestHitsMatchingQuery:query excluding:nil limit:100 completion:^(NSArray<FileSearchHit *> *hits) {
        answer = hits;
        [delivered fulfill];
    }];
    [self waitForExpectations:@[delivered] timeout:VIBE_TEST_HANG_TIMEOUT];
    return answer;
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

// iOS spells a picked folder under /private/var and the app's container under
// /var. Spelling alone must see one tree.
- (void)testAPrivateSpellingIsCoveredByItsAlias {
    XCTAssertEqualObjects(PrunedPaths(@[@"/private/var/mobile/Documents/Music", @"/var/mobile/Documents"]),
                          @[@"/var/mobile/Documents"]);
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

    // The walk resolves its root, so a hit is spelled under /private. The
    // playlist's paths are the alias-free spelling.
    XCTAssertTrue([excludedPath hasPrefix:@"/private/"], @"%@", excludedPath);
    XCTestExpectation *delivered = [self expectationWithDescription:@"hits delivered"];
    __block BOOL requestReturned = NO;
    [index requestHitsMatchingQuery:@"kid a"
                          excluding:[NSSet setWithObject:VibeComparablePath(excludedPath)]
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

// The walk lists a CUE sheet as a file. Only audio is a hit.
- (void)testTheIndexDropsACueSheet {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/Kid A/01.flac",
        @"Music/Kid A/Kid A.cue"
    ]];
    NSArray<FileSearchHit *> *hits = [self hitsOf:index matching:@"kid a"];
    XCTAssertEqualObjects([hits valueForKey:@"fileName"], @[@"01.flac"]);
}

// The cap stops the index and cancels the walk's token, so a large library
// is not listed to its end.
- (void)testTheFileCapCancelsTheWalk {
    FileSearchIndex *index = [self indexWithRelativeFilePaths:@[
        @"Music/A/1.mp3", @"Music/A/2.mp3", @"Music/A/3.mp3", @"Music/B/4.mp3"
    ] cap:2];
    XCTAssertTrue(index.buildProgressForTesting.isCancelled);
    XCTAssertFalse(index.isBuilding);
    XCTAssertEqual([self hitsOf:index matching:@"mp3"].count, 2u);
}

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

#pragma mark - The open intent

// Two Adds onto an empty session take token 7. The first promotes to 8. Its
// sibling is still the user's. A real replace or a clear drops it.
- (void)testAPromotionIsNotASupersession {
    XCTAssertTrue(VibeFolderSessionAddTokenIsCurrent(7, 7, 0));
    XCTAssertTrue(VibeFolderSessionAddTokenIsCurrent(7, 8, 8), @"the promoted sibling");
    XCTAssertFalse(VibeFolderSessionAddTokenIsCurrent(7, 9, 8), @"the user's replace after the promotion");
    XCTAssertFalse(VibeFolderSessionAddTokenIsCurrent(7, 8, 0), @"a replace with no promotion");
    XCTAssertFalse(VibeFolderSessionAddTokenIsCurrent(6, 8, 8), @"two below the promotion");
    XCTAssertTrue(VibeFolderSessionAddTokenIsCurrent(9, 9, 8));
}

// Without the carry, an Add taken after an empty open captures a generation
// that never landed, and Add is dead for the session.
- (void)testAnEmptySettleCarriesTheLandedGeneration {
    XCTAssertEqual(VibeFolderSessionCarriedOpenIntentGeneration(3, 4), (uint64_t)4);
    XCTAssertEqual(VibeFolderSessionCarriedOpenIntentGeneration(0, 4), (uint64_t)0,
                   @"zero stays zero, so an Add is still promoted");
}

#pragma mark - The screen's sections

- (void)testTheScopeBarFollowsTheDrawnOrderAndTheAccount {
    XCTAssertEqualObjects(VibeSearchScopeSections(NO),
                          (@[@(VibeSearchSectionCount), @(VibeSearchSectionPlaylist), @(VibeSearchSectionFiles)]));
    XCTAssertEqualObjects(VibeSearchScopeSections(YES).lastObject, @(VibeSearchSectionDropbox));
    XCTAssertTrue(VibeSearchScopeIncludes(VibeSearchSectionCount, VibeSearchSectionDropbox), @"All");
    XCTAssertTrue(VibeSearchScopeIncludes(VibeSearchSectionFiles, VibeSearchSectionFiles));
    XCTAssertFalse(VibeSearchScopeIncludes(VibeSearchSectionFiles, VibeSearchSectionPlaylist));
}

- (void)testTheFilesSectionShowsHitsOrARunningWalkInScope {
    XCTAssertTrue(VibeSearchShowsFilesSection(YES, VibeSearchSectionCount, 2, NO));
    XCTAssertTrue(VibeSearchShowsFilesSection(YES, VibeSearchSectionFiles, 0, YES), @"Searching files…");
    XCTAssertFalse(VibeSearchShowsFilesSection(YES, VibeSearchSectionCount, 0, NO));
    XCTAssertFalse(VibeSearchShowsFilesSection(NO, VibeSearchSectionCount, 2, YES), @"the empty query lists no files");
    XCTAssertFalse(VibeSearchShowsFilesSection(YES, VibeSearchSectionPlaylist, 2, YES));
}

- (void)testTheDropboxSectionShowsWhileAskingAndAfterAFailure {
    XCTAssertTrue(VibeSearchShowsDropboxSection(YES, YES, VibeSearchSectionCount, 0, YES, NO));
    XCTAssertTrue(VibeSearchShowsDropboxSection(YES, YES, VibeSearchSectionDropbox, 0, NO, YES));
    XCTAssertTrue(VibeSearchShowsDropboxSection(YES, YES, VibeSearchSectionCount, 3, NO, NO));
    XCTAssertFalse(VibeSearchShowsDropboxSection(YES, YES, VibeSearchSectionCount, 0, NO, NO));
    XCTAssertFalse(VibeSearchShowsDropboxSection(NO, YES, VibeSearchSectionCount, 3, YES, YES), @"unlinked");
    XCTAssertFalse(VibeSearchShowsDropboxSection(YES, NO, VibeSearchSectionCount, 3, NO, NO));
    XCTAssertFalse(VibeSearchShowsDropboxSection(YES, YES, VibeSearchSectionFiles, 3, NO, NO));
}

- (void)testNoResultsWaitsForEveryHalfInScope {
    XCTAssertTrue(VibeSearchSettledEmpty(YES, 0, NO, NO, NO));
    XCTAssertFalse(VibeSearchSettledEmpty(NO, 0, NO, NO, NO), @"the empty query is the browse list");
    XCTAssertFalse(VibeSearchSettledEmpty(YES, 1, NO, NO, NO));
    XCTAssertFalse(VibeSearchSettledEmpty(YES, 0, YES, NO, NO), @"files still matching");
    XCTAssertFalse(VibeSearchSettledEmpty(YES, 0, NO, YES, NO), @"a walk still running");
    XCTAssertFalse(VibeSearchSettledEmpty(YES, 0, NO, NO, YES), @"Dropbox asking or failed");
}

#pragma mark - The remembered track

- (void)testAnExactKeyOutranksAFilenameAnywhere {
    NSArray *keys = @[@"/old/01.wav", @"/b/02.wav", @"/a/01.wav"];
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"/a/01.wav"), 2u);
}

- (void)testTheFirstFilenameHitIsTheFallback {
    NSArray *keys = @[@"/x/02.wav", @"/moved/01.wav", @"/other/01.wav"];
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"/container-uuid/01.wav"), 1u);
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"01.wav"), 1u, @"an older build's bare filename");
}

- (void)testACueRowsWindowRidesOnBothTiers {
    NSArray *keys = @[@"/a/image.flac#0-100", @"/a/image.flac#100-200"];
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"/a/image.flac#100-200"), 1u);
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"/moved/image.flac#100-200"), 1u);
}

- (void)testNothingRememberedOrMatchedParksNowhere {
    NSArray *keys = @[@"/a/01.wav", @""];
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, nil), (NSUInteger)NSNotFound);
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @""), (NSUInteger)NSNotFound);
    XCTAssertEqual(VibeFolderSessionRememberedIndex(keys, @"/a/02.wav"), (NSUInteger)NSNotFound);
}

@end
