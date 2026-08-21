//
// When the header installs art, keeps what is up, or falls back to the record
// backdrop. The failure modes are a backdrop flashing over a cover that is a
// moment from appearing, and a stale cover left up for good.
//

#import <XCTest/XCTest.h>

#import "ArtworkDisplayRules.h"

@interface ArtworkDisplayRulesTests : XCTestCase
@end

@implementation ArtworkDisplayRulesTests

#pragma mark - Nothing loaded

// Closing a file must clear the header. Without this, a nil track reads as
// "unresolved" and the keep-previous policy leaves the closed track's art and
// tint on screen.
- (void)testNoTrackAlwaysShowsTheDefault {
    XCTAssertEqual(VibeArtworkDisplayActionFor(NO, NO, NO, YES), VibeArtworkDisplayActionShowDefault);
    XCTAssertEqual(VibeArtworkDisplayActionFor(NO, NO, YES, YES), VibeArtworkDisplayActionShowDefault);
    XCTAssertEqual(VibeArtworkDisplayActionFor(NO, NO, NO, NO), VibeArtworkDisplayActionShowDefault);
}

#pragma mark - Art in hand

- (void)testArtInHandIsAlwaysInstalled {
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, YES, YES, YES), VibeArtworkDisplayActionInstall);
    // Even mid-resolve: something better may follow, but what is here is real.
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, YES, NO, YES), VibeArtworkDisplayActionInstall);
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, YES, NO, NO), VibeArtworkDisplayActionInstall);
}

#pragma mark - The unresolved gap

// The no-flash rule: while the new track's art is still pending, the previous
// track's art stays up. Two tracks that both have covers must never show the
// backdrop between them.
- (void)testAnUnresolvedTrackKeepsThePreviousArt {
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, NO, NO, YES),
                   VibeArtworkDisplayActionKeepPrevious);
}

// With a folder fallback, nil art can mean "another worker is resolving this
// folder right now". Reading that as artless flashes the backdrop over a cover
// that appears a moment later.
- (void)testNilArtIsNotArtlessnessWhileSomethingIsStillPending {
    XCTAssertNotEqual(VibeArtworkDisplayActionFor(YES, NO, NO, YES),
                      VibeArtworkDisplayActionShowDefault);
}

// Before the first render there is no previous art to keep, so an unresolved
// track shows the backdrop rather than an empty frame.
- (void)testTheFirstRenderShowsTheDefaultRatherThanNothing {
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, NO, NO, NO),
                   VibeArtworkDisplayActionShowDefault);
}

#pragma mark - Definitively artless

- (void)testAResolvedTrackWithNoArtShowsTheDefault {
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, NO, YES, YES),
                   VibeArtworkDisplayActionShowDefault);
    XCTAssertEqual(VibeArtworkDisplayActionFor(YES, NO, YES, NO),
                   VibeArtworkDisplayActionShowDefault);
}

#pragma mark - Asynchronous render acceptance

- (void)testRenderResultRequiresCurrentGenerationAndDisplayTarget {
    NSObject *track = [[NSObject alloc] init];
    NSObject *otherTrack = [[NSObject alloc] init];
    NSObject *metadata = [[NSObject alloc] init];
    NSObject *art = [[NSObject alloc] init];
    XCTAssertTrue(VibeArtworkRenderResultMayInstall(7, 7,
                                                     track, metadata, art,
                                                     track, metadata, art));
    // An unresolved replacement has not started its own render, so generation
    // alone cannot identify the track the header now describes.
    XCTAssertFalse(VibeArtworkRenderResultMayInstall(7, 7,
                                                      track, metadata, art,
                                                      otherTrack, metadata, art));
    XCTAssertFalse(VibeArtworkRenderResultMayInstall(6, 7,
                                                      track, metadata, art,
                                                      track, metadata, art));
}

- (void)testRenderFromReplacedMetadataOnTheSameTrackIsRejected {
    NSObject *track = [[NSObject alloc] init];
    NSObject *fallbackMetadata = [[NSObject alloc] init];
    NSObject *successfulMetadata = [[NSObject alloc] init];
    NSObject *art = [[NSObject alloc] init];

    XCTAssertFalse(VibeArtworkRenderResultMayInstall(7, 7,
                                                      track, fallbackMetadata, art,
                                                      track, successfulMetadata, art));
}

- (void)testRenderFromReplacedArtOnTheSameTrackAndMetadataIsRejected {
    NSObject *track = [[NSObject alloc] init];
    NSObject *metadata = [[NSObject alloc] init];
    NSObject *oldArt = [[NSObject alloc] init];
    NSObject *newArt = [[NSObject alloc] init];

    XCTAssertFalse(VibeArtworkRenderResultMayInstall(7, 7,
                                                      track, metadata, oldArt,
                                                      track, metadata, newArt));
}

// The whole policy in one place, so a future edit has to break a named case
// rather than a boolean expression by accident.
- (void)testTheCompleteTruthTable {
    struct {
        BOOL hasTrack, hasArt, artResolved, initialized;
        VibeArtworkDisplayAction expected;
    } cases[] = {
        {NO,  NO,  NO,  NO,  VibeArtworkDisplayActionShowDefault},
        {NO,  NO,  NO,  YES, VibeArtworkDisplayActionShowDefault},
        {NO,  NO,  YES, NO,  VibeArtworkDisplayActionShowDefault},
        {NO,  NO,  YES, YES, VibeArtworkDisplayActionShowDefault},
        {YES, NO,  NO,  NO,  VibeArtworkDisplayActionShowDefault},
        {YES, NO,  NO,  YES, VibeArtworkDisplayActionKeepPrevious},
        {YES, NO,  YES, NO,  VibeArtworkDisplayActionShowDefault},
        {YES, NO,  YES, YES, VibeArtworkDisplayActionShowDefault},
        {YES, YES, NO,  NO,  VibeArtworkDisplayActionInstall},
        {YES, YES, NO,  YES, VibeArtworkDisplayActionInstall},
        {YES, YES, YES, NO,  VibeArtworkDisplayActionInstall},
        {YES, YES, YES, YES, VibeArtworkDisplayActionInstall},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        XCTAssertEqual(VibeArtworkDisplayActionFor(cases[i].hasTrack, cases[i].hasArt,
                                                   cases[i].artResolved, cases[i].initialized),
                       cases[i].expected,
                       @"track=%d art=%d resolved=%d initialized=%d",
                       cases[i].hasTrack, cases[i].hasArt,
                       cases[i].artResolved, cases[i].initialized);
    }
}

@end
