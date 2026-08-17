//
// Convert to FLAC: which files are eligible, and what the output is called.
//

#import <XCTest/XCTest.h>

#import "FLACConvertRules.h"

@interface FLACConvertRulesTests : XCTestCase
@end

@implementation FLACConvertRulesTests

#pragma mark - Eligibility by sniffed type

- (void)testUncompressedTypesAreConvertible {
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(FILETYPE_WAV, @"wav"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(FILETYPE_AIFF, @"aiff"));
}

- (void)testAlreadyLosslessTypesAreNotConvertible {
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_FLAC, @"flac"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_ALAC, @"m4a"));
}

- (void)testLossyTypesAreNotConvertible {
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_MP3, @"mp3"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_MP2, @"mp2"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_AAC, @"aac"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_MP4, @"m4a"));
}

- (void)testSniffedTypeBeatsTheExtension {
    // TagLib read the bytes; the extension is only ever a guess.
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(FILETYPE_MP3, @"wav"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(FILETYPE_WAV, @"mp3"));
}

- (void)testPreliminaryContainerUsesTheMetadataTypeRatherThanTheExtension {
    XCTAssertEqual(VibeUncompressedContainerForFile(FILETYPE_WAV, @"mp3"),
            VibeUncompressedContainerWAV);
    XCTAssertEqual(VibeUncompressedContainerForFile(FILETYPE_AIFF, @"wav"),
            VibeUncompressedContainerAIFF);
    XCTAssertEqual(VibeUncompressedContainerForFile(FILETYPE_MP3, @"wav"),
            VibeUncompressedContainerUnknown);
}

#pragma mark - Eligibility before metadata arrives

- (void)testUnparsedTrackFallsBackToItsExtension {
    // A row is eligible from the moment it is dropped, not when the background
    // scan reaches it.
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"wav"));
    // The claimed UTType (com.microsoft.waveform-audio) declares wav, wave,
    // AND bwf — all plain RIFF WAVE — and the open filter admits all three,
    // so eligibility claims them too.
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"wave"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"bwf"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"aif"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"aiff"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, @"mp3"));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, @"flac"));
}

- (void)testExtensionFallbackIsCaseInsensitive {
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"WAV"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(nil, @"AIFF"));
}

- (void)testPreliminaryContainerFallsBackToAnUnparsedFilesExtension {
    XCTAssertEqual(VibeUncompressedContainerForFile(nil, @"BWF"),
            VibeUncompressedContainerWAV);
    XCTAssertEqual(VibeUncompressedContainerForFile(@"", @"AIFF"),
            VibeUncompressedContainerAIFF);
}

- (void)testAifcIsNotEligibleOnExtensionAlone {
    // AIFF-C carries a compression type and may hold anything, so it waits for
    // TagLib to call it AIFF.
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, @"aifc"));
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(FILETYPE_AIFF, @"aifc"));
}

- (void)testMissingTypeAndExtensionIsNotConvertible {
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, nil));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, @""));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(@"", nil));
    XCTAssertFalse(VibeTrackIsConvertibleToFLAC(nil, @"txt"));
}

- (void)testEmptyTypeIsTreatedAsUnparsedRatherThanUnknown {
    // A cache decode can hand back a nil-or-empty fileType on a track whose
    // extension is perfectly good; that must not disable the item.
    XCTAssertTrue(VibeTrackIsConvertibleToFLAC(@"", @"wav"));
}

#pragma mark - Destination name

- (void)testExtensionIsReplacedNotAppended {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.wav"), @"foo.flac");
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.aiff"), @"foo.flac");
}

- (void)testOnlyTheLastComponentOfADottedNameIsReplaced {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.bar.wav"), @"foo.bar.flac");
    XCTAssertEqualObjects(VibeFLACDestinationName(@"01. Track 2.wav"), @"01. Track 2.flac");
}

- (void)testUppercaseExtensionStillYieldsALowercaseFlac {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.WAV"), @"foo.flac");
}

- (void)testExtensionlessNameGainsOne {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo"), @"foo.flac");
}

- (void)testWaveAndBwfExtensionsAreReplacedLikeWav {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.wave"), @"foo.flac");
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo.bwf"), @"foo.flac");
}

- (void)testTrailingDotIsKeptNotTreatedAsAnExtension {
    // stringByDeletingPathExtension leaves a bare trailing dot alone, so the
    // odd-but-harmless result is foo..flac — pinned so a future normalization
    // is a deliberate choice.
    XCTAssertEqualObjects(VibeFLACDestinationName(@"foo."), @"foo..flac");
}

- (void)testDotfileKeepsItsWholeName {
    // Deleting the "extension" of a dotfile leaves nothing, and a bare
    // ".flac" would collide with every other conversion in the folder.
    XCTAssertEqualObjects(VibeFLACDestinationName(@".wav"), @".wav.flac");
}

- (void)testNamesWithSpacesAndUnicodeSurvive {
    XCTAssertEqualObjects(VibeFLACDestinationName(@"Café – Intro.aif"), @"Café – Intro.flac");
}

@end
