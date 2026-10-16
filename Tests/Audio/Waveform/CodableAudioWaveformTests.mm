//
//  CodableAudioWaveformTests.mm
//  VibeTests
//
//  The cache entry: the summary's archive under its version, and the tempo,
//  key and analysis flags that ride along. The summary's own bytes are
//  tested in WaveformCore/WaveformSummaryTests.
//

#import <XCTest/XCTest.h>
#import "AudioWaveform.h"

#include <vector>

@interface CodableAudioWaveformTests : XCTestCase
@end

// A complete summary of a few hundred bins, with or without bands.
static std::unique_ptr<AudioWaveform> SampleSummary(bool bands, bool complete = true) {
    auto summary = std::make_unique<AudioWaveform>(4, 1, bands, 44100);
    for (int i = 0; i < 300; i++) {
        float lo = -0.25f - (float)(i % 3) * 0.1f, hi = 0.5f;
        double bandSums[wavecore::kBandCount] = {0.04, 0.01, 0.002};
        summary->appendBin(&lo, &hi, 0.1, bandSums, 4);
    }
    if (complete) summary->markComplete();
    return summary;
}

static NSData *SummaryBytes(bool bands, bool complete = true) {
    std::vector<uint8_t> blob = SampleSummary(bands, complete)->encode();
    return [NSData dataWithBytes:blob.data() length:blob.size()];
}

static NSData *ArchiveWithKeys(int version, NSData *summary, float bpm, id key) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:version forKey:@"version"];
    if (summary) {
        [archiver encodeBytes:(const uint8_t *)summary.bytes length:summary.length forKey:@"summary"];
    }
    [archiver encodeFloat:bpm forKey:@"bpm"];
    if (key) {
        [archiver encodeObject:key forKey:@"key"];
    }
    [archiver finishEncoding];
    return archiver.encodedData;
}

static CodableAudioWaveform *DecodeArchive(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [[CodableAudioWaveform alloc] initWithCoder:unarchiver];
    [unarchiver finishDecoding];
    return decoded;
}

static CodableAudioWaveform *RoundTrip(CodableAudioWaveform *original) {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:NO error:&error];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return decoded;
}

@implementation CodableAudioWaveformTests

- (void)testEncodeThenDecodePreservesTheSummaryBandsAndAnalysis {
    CodableAudioWaveform *original = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(true)];
    original.bpm = 128;
    original.key = 9;
    CodableAudioWaveform *decoded = RoundTrip(original);
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.waveform->frames(), original.waveform->frames());
    XCTAssertTrue(decoded.waveform->hasBands());
    wavecore::Column column = decoded.waveform->column(8, 12);
    XCTAssertEqualWithAccuracy(column.lo, -0.45f, 1e-3);
    XCTAssertEqualWithAccuracy(column.hi, 0.5f, 1e-3);
    XCTAssertEqualWithAccuracy(column.meanSquare(), 0.025f, 1e-4);
    XCTAssertEqualWithAccuracy(column.bandMeanSquare(0), 0.01f, 1e-4);
    XCTAssertEqual(decoded.bpm, 128);
    XCTAssertEqual(decoded.key, 9);
}

- (void)testAnEntryWithoutBandsDecodesWithoutThem {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, nil));
    XCTAssertNotNil(decoded);
    XCTAssertFalse(decoded.waveform->hasBands());
}

- (void)testMismatchedVersionIsRejected {
    // Old entries decode their absent version as 0, which must also fail.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion + 1, SummaryBytes(true), 120, nil)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(0, SummaryBytes(true), 120, nil)));
}

- (void)testAMissingOrBrokenSummaryIsRejected {
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, nil, 120, nil)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, [NSData data], 120, nil)));
    NSData *valid = SummaryBytes(true);
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                               [valid subdataWithRange:NSMakeRange(0, valid.length - 8)], 120, nil)));
}

// The cache only files a complete decode, so anything else is corruption.
- (void)testAnIncompleteSummaryIsRejected {
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(true, false), 120, nil)));
}

#pragma mark - BPM coercion (not rejection)

- (void)testNonFiniteOrNegativeBPMIsCoercedToZero {
    // A bad tempo is not a reason to throw away good waveform data: it
    // degrades to "unknown".
    for (float bad : {(float)NAN, (float)INFINITY, -5.0f, 0.0f}) {
        CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), bad, nil));
        XCTAssertNotNil(decoded, @"bpm %f must not reject the entry", bad);
        XCTAssertEqual(decoded.bpm, 0.0f);
    }
}

#pragma mark - Musical key coercion (not rejection)

- (void)testAbsentKeyDecodesAsNone {
    // Not the 0 an integer decode fabricates, which is C major.
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, nil));
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.key, -1);
}

- (void)testOutOfRangeOrWrongClassKeyIsCoercedToNone {
    // 0 is a valid key (C major), so the coercion must come from range and
    // class checks, never from a nil-ish read.
    for (id bad in @[@(24), @(-2), @"8A", @[@(3)]]) {
        CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, bad));
        XCTAssertNotNil(decoded, @"key %@ must not reject the entry", bad);
        XCTAssertEqual(decoded.key, -1, @"key %@ must coerce to none", bad);
    }
    CodableAudioWaveform *cMajor = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, @(0)));
    XCTAssertEqual(cMajor.key, 0, @"C major is preserved, not mistaken for absent");
}

#pragma mark - Analysis flags

- (void)testAnArchiveWithoutAnalysisFlagsReadsAnalyzed {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 0, nil));
    XCTAssertNotNil(decoded);
    XCTAssertTrue(decoded.bpmAnalyzed);
    XCTAssertTrue(decoded.keyAnalyzed);
}

- (void)testAnalysisFlagsSurviveTheArchive {
    CodableAudioWaveform *original = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(false)];
    original.bpmAnalyzed = NO;
    original.keyAnalyzed = YES;
    CodableAudioWaveform *decoded = RoundTrip(original);
    XCTAssertNotNil(decoded);
    XCTAssertFalse(decoded.bpmAnalyzed);
    XCTAssertTrue(decoded.keyAnalyzed);
}

@end
