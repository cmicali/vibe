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

@interface FileSearchRulesTests : XCTestCase
@end

@implementation FileSearchRulesTests

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

@end
