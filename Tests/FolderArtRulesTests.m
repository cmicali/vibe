//
// What a folder cover may be called, the order it is looked for in, and which
// one wins when a folder holds several. The order IS the cost model: only the
// first few are ever stat'd blind, and the rest exist to be matched against a
// listing the app was doing anyway.
//

#import <XCTest/XCTest.h>

#import "FolderArtRules.h"

@interface FolderArtRulesTests : XCTestCase
@end

@implementation FolderArtRulesTests {
    NSArray<NSString *> *_candidates;
}

- (void)setUp {
    _candidates = VibeFolderArtCandidateFilenames();
}

#pragma mark - Order

- (void)testTheProbedPrefixIsTheThreeCommonestSpellings {
    NSArray<NSString *> *probed =
            [_candidates subarrayWithRange:NSMakeRange(0, kVibeFolderArtStatProbeCount)];
    XCTAssertEqualObjects(probed, (@[@"cover.jpg", @"folder.jpg", @"album.jpg"]));
}

- (void)testJPGForEveryNameOutranksAnyOtherExtension {
    // A folder holding both cover.png and folder.jpg gets the .jpg: it is the
    // one the ripper that wrote the audio also wrote.
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"folder.jpg"), VibeFolderArtCandidateRank(@"cover.png"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"front.jpg"), VibeFolderArtCandidateRank(@"cover.png"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"album.png"), VibeFolderArtCandidateRank(@"cover.jpeg"));
}

- (void)testNameOrderWithinAnExtension {
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"cover.jpg"), VibeFolderArtCandidateRank(@"folder.jpg"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"folder.jpg"), VibeFolderArtCandidateRank(@"album.jpg"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"album.jpg"), VibeFolderArtCandidateRank(@"front.jpg"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"cover.png"), VibeFolderArtCandidateRank(@"folder.png"));
}

// The stems other players write, so a library tagged elsewhere is found as-is.
// They rank below cover/folder/album/front, which keeps the probe prefix intact.
- (void)testTheOtherEcosystemSpellingsAreRecognized {
    for (NSString *name in @[@"albumart.jpg", @"art.jpg", @"albumart.png", @"art.jpeg"]) {
        XCTAssertNotEqual(VibeFolderArtCandidateRank(name), NSNotFound, @"%@", name);
    }
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"front.jpg"),
                      VibeFolderArtCandidateRank(@"albumart.jpg"));
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"albumart.jpg"),
                      VibeFolderArtCandidateRank(@"art.jpg"));
    // Still last by extension, so a jpg beside a webp keeps winning.
    XCTAssertLessThan(VibeFolderArtCandidateRank(@"art.jpeg"),
                      VibeFolderArtCandidateRank(@"cover.webp"));
}

- (void)testWebPIsACoverExtension {
    XCTAssertNotEqual(VibeFolderArtCandidateRank(@"cover.webp"), NSNotFound);
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(@[@"cover.webp"]), @"cover.webp");
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(@[@"cover.webp", @"folder.jpg"]), @"folder.jpg");
}

// Names deliberately left out: thumb is by its name a small image and would
// show soft at the header size, poster and default are video-library
// conventions, and back is the wrong side of the sleeve.
- (void)testTheDeliberatelyExcludedNamesStayExcluded {
    for (NSString *name in @[@"thumb.jpg", @"poster.jpg", @"default.jpg", @"back.jpg",
                             @"albumart_large.jpg", @"albumartsmall.jpg"]) {
        XCTAssertEqual(VibeFolderArtCandidateRank(name), NSNotFound, @"%@", name);
    }
}

- (void)testEveryCandidateIsUniqueLowerCaseAndExtensioned {
    XCTAssertEqual(_candidates.count, [NSSet setWithArray:_candidates].count);
    for (NSString *candidate in _candidates) {
        XCTAssertEqualObjects(candidate, candidate.lowercaseString,
                              @"the file system folds case for a stat, and the rank folds it for a listing");
        XCTAssertGreaterThan(candidate.pathExtension.length, 0u);
    }
}

// A folder with no cover pays one stat per probed candidate — once, ever. Keep
// that bill small: this is the number every coverless folder in a library pays.
- (void)testTheProbedPrefixStaysSmall {
    XCTAssertLessThanOrEqual(kVibeFolderArtStatProbeCount, 3u);
    XCTAssertLessThanOrEqual(kVibeFolderArtStatProbeCount, _candidates.count);
}

#pragma mark - Matching a listing

- (void)testRankMatchesCaseInsensitively {
    // The listing path is the only one that sees real spellings, and this is
    // where Folder.JPG has to be recognized on a case-sensitive volume.
    XCTAssertEqual(VibeFolderArtCandidateRank(@"Folder.JPG"), VibeFolderArtCandidateRank(@"folder.jpg"));
    XCTAssertEqual(VibeFolderArtCandidateRank(@"COVER.Png"), VibeFolderArtCandidateRank(@"cover.png"));
}

- (void)testRankRejectsPartialAndUnrelatedNames {
    NSArray<NSString *> *nonCovers = @[@"scan-cover.jpg", @"folder art.jpg", @"covers.jpg", @"back.jpg",
                                       @"cover.txt", @"cover", @"albumart_large.jpg", @".cover.jpg",
                                       @"._cover.jpg", @"01 Track.mp3", @""];
    for (NSString *name in nonCovers) {
        XCTAssertEqual(VibeFolderArtCandidateRank(name), NSNotFound, @"%@", name);
    }
    XCTAssertEqual(VibeFolderArtCandidateRank(nil), NSNotFound);
}

- (void)testBestCandidateKeepsTheSpellingItWasGiven {
    NSArray<NSString *> *listing = @[@"01 Track.mp3", @"Folder.JPG", @"notes.txt"];
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(listing), @"Folder.JPG");
}

- (void)testBestCandidateWinsByRank {
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(@[@"album.jpg", @"cover.jpg", @"folder.jpg"]),
                          @"cover.jpg");
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(@[@"cover.png", @"folder.jpg"]), @"folder.jpg");
    XCTAssertEqualObjects(VibeFolderArtBestCandidate(@[@"front.jpeg", @"album.png"]), @"album.png");
}

- (void)testBestCandidateOfNothing {
    XCTAssertNil(VibeFolderArtBestCandidate(@[]));
    XCTAssertNil(VibeFolderArtBestCandidate(nil));
    XCTAssertNil(VibeFolderArtBestCandidate(@[@"01 Track.mp3", @"notes.txt"]));
}

#pragma mark - Ranking

// NSNotFound is NSIntegerMax, not NSUIntegerMax, so it must be tested rather
// than compared.
- (void)testRankBeatsTreatsNotFoundAsNeitherCandidateNorIncumbent {
    XCTAssertTrue(VibeFolderArtRankBeats(0, NSNotFound), @"anything beats nothing yet");
    XCTAssertTrue(VibeFolderArtRankBeats(3, 7));
    XCTAssertFalse(VibeFolderArtRankBeats(7, 3));
    XCTAssertFalse(VibeFolderArtRankBeats(3, 3), @"ties keep the incumbent");
    XCTAssertFalse(VibeFolderArtRankBeats(NSNotFound, NSNotFound), @"a non-cover is never a cover");
    XCTAssertFalse(VibeFolderArtRankBeats(NSNotFound, 7));
}

#pragma mark - Streaming accumulation (the folder walk)

- (void)testNoteCandidateKeepsTheBestPerDirectory {
    NSMutableDictionary<NSString *, NSString *> *art = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *ranks = [NSMutableDictionary dictionary];
    // Arriving in the order a directory enumerator might hand them over.
    VibeFolderArtNoteCandidate(@"/A", @"01 Track.mp3", art, ranks);
    VibeFolderArtNoteCandidate(@"/A", @"album.jpg", art, ranks);
    VibeFolderArtNoteCandidate(@"/A", @"Cover.JPG", art, ranks);
    VibeFolderArtNoteCandidate(@"/A", @"folder.jpg", art, ranks);
    VibeFolderArtNoteCandidate(@"/B", @"front.png", art, ranks);
    XCTAssertEqualObjects(art[@"/A"], @"Cover.JPG", @"best wins, spelling preserved");
    XCTAssertEqualObjects(art[@"/B"], @"front.png");
    XCTAssertEqual(art.count, 2u, @"directories with no cover leave no entry");
}

- (void)testNoteCandidateIgnoresNonCoversAndEmptyDirectories {
    NSMutableDictionary<NSString *, NSString *> *art = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *ranks = [NSMutableDictionary dictionary];
    VibeFolderArtNoteCandidate(@"/A", @"01 Track.mp3", art, ranks);
    VibeFolderArtNoteCandidate(@"/A", @"scan-cover.jpg", art, ranks);
    VibeFolderArtNoteCandidate(@"", @"cover.jpg", art, ranks);
    VibeFolderArtNoteCandidate(nil, @"cover.jpg", art, ranks);
    VibeFolderArtNoteCandidate(@"/A", nil, art, ranks);
    XCTAssertEqual(art.count, 0u);
}

- (void)testNoteCandidateAgreesWithBestCandidate {
    NSArray<NSString *> *listing = @[@"02 B.wav", @"folder.png", @"cover.jpeg", @"art.txt"];
    NSMutableDictionary<NSString *, NSString *> *art = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *ranks = [NSMutableDictionary dictionary];
    for (NSString *filename in listing) {
        VibeFolderArtNoteCandidate(@"/A", filename, art, ranks);
    }
    XCTAssertEqualObjects(art[@"/A"], VibeFolderArtBestCandidate(listing),
                          @"the streaming and whole-listing forms rank identically");
}

#pragma mark - When the fallback applies

// The invariant behind "a tagged library never opens a cover file".

- (void)testAFileWithArtOfItsOwnIsNeverKnownArtless {
    XCTAssertFalse(VibeFileIsKnownToCarryNoArt(YES, NO, NO));
    XCTAssertFalse(VibeFileIsKnownToCarryNoArt(YES, YES, NO), @"even once extraction has run");
}

- (void)testUnknownIsNotArtless {
    // Nothing found yet and nothing looked for: the folder must not step in,
    // or it would stand in front of art that is about to appear.
    XCTAssertFalse(VibeFileIsKnownToCarryNoArt(NO, NO, NO));
}

- (void)testArtlessOnceExtractionHasRunAndFoundNothing {
    XCTAssertTrue(VibeFileIsKnownToCarryNoArt(NO, YES, NO));
}

- (void)testUndecodableArtCountsAsArtlessEvenWhileBytesRemain {
    // Permanent for the file's content, so the folder's cover is the better
    // showing — and this must hold even though the bytes are still in hand.
    XCTAssertTrue(VibeFileIsKnownToCarryNoArt(YES, YES, YES));
    XCTAssertTrue(VibeFileIsKnownToCarryNoArt(NO, NO, YES));
}

@end
