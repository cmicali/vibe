//
//  CodableAudioWaveformTests.mm
//  VibeTests
//
//  The cache entry: the summary's archive under its version, and the
//  observers' results that ride along, each a property-list object under its
//  identifier. The summary's own bytes are tested in vibe-libs'
//  WaveformSummaryTests.
//

#import <XCTest/XCTest.h>
#import "AudioAnalysisObservers.h"
#import "AudioWaveform.h"

#include <vector>

@interface CodableAudioWaveformTests : XCTestCase
@end

// A complete summary of a few hundred bins, with or without bands.
static std::unique_ptr<AudioWaveform> SampleSummary(bool bands, bool complete = true) {
    auto summary = std::make_unique<AudioWaveform>(4, bands, 44100);
    for (int i = 0; i < 300; i++) {
        double bandSums[wavecore::kBandCount] = {0.04, 0.01, 0.002};
        summary->appendBin(-0.25f - (float)(i % 3) * 0.1f, 0.5f, 0.1, bandSums, 4);
    }
    if (complete) summary->markComplete();
    return summary;
}

static NSData *SummaryBytes(bool bands, bool complete = true) {
    std::vector<uint8_t> blob = SampleSummary(bands, complete)->encode();
    return [NSData dataWithBytes:blob.data() length:blob.size()];
}

// An entry as this format writes one, with its parts given: the results as
// raw bytes, so a test can hand it bytes that will not read.
static NSData *ArchiveWithParts(int version, NSData *summary, NSData *results) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:version forKey:@"version"];
    if (summary) {
        [archiver encodeBytes:(const uint8_t *)summary.bytes length:summary.length forKey:@"summary"];
    }
    if (results) {
        [archiver encodeBytes:(const uint8_t *)results.bytes length:results.length forKey:@"results"];
    }
    [archiver finishEncoding];
    return archiver.encodedData;
}

static NSData *ResultBytes(id results) {
    return [NSKeyedArchiver archivedDataWithRootObject:results requiringSecureCoding:YES error:NULL];
}

static NSData *ArchiveWithKeys(int version, NSData *summary) {
    return ArchiveWithParts(version, summary, ResultBytes(@{}));
}

static CodableAudioWaveform *DecodeArchive(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [[CodableAudioWaveform alloc] initWithCoder:unarchiver];
    [unarchiver finishDecoding];
    return decoded;
}

// Through PINCache's own shape: an insecure root archive.
static CodableAudioWaveform *RoundTrip(CodableAudioWaveform *original) {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:NO error:&error];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return decoded;
}

static CodableAudioWaveform *RoundTripResults(NSDictionary *results) {
    CodableAudioWaveform *original = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(false)];
    original.results = results;
    return RoundTrip(original);
}

static NSString *Tempo(void) {
    return AudioBPMAnalyzer.waveformObserver.identifier;
}

static NSString *Key(void) {
    return AudioKeyAnalyzer.waveformObserver.identifier;
}

// Format 6, as the analyzers' own fields wrote it: the tempo inline, the key
// as an object, and a flag for each.
static NSData *Format6Archive(NSData *summary) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:6 forKey:@"version"];
    [archiver encodeBytes:(const uint8_t *)summary.bytes length:summary.length forKey:@"summary"];
    [archiver encodeFloat:128 forKey:@"bpm"];
    [archiver encodeObject:@9 forKey:@"key"];
    [archiver encodeBool:YES forKey:@"bpmAnalyzed"];
    [archiver encodeBool:YES forKey:@"keyAnalyzed"];
    [archiver finishEncoding];
    return archiver.encodedData;
}

@implementation CodableAudioWaveformTests

- (void)testEncodeThenDecodePreservesTheSummaryBandsAndResults {
    CodableAudioWaveform *original = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(true)];
    original.results = @{Tempo(): @128.0f, Key(): @9};
    CodableAudioWaveform *decoded = RoundTrip(original);
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.waveform->frames(), original.waveform->frames());
    XCTAssertTrue(decoded.waveform->hasBands());
    wavecore::Column column = decoded.waveform->column(8, 12);
    XCTAssertEqualWithAccuracy(column.lo, -0.45f, 1e-3);
    XCTAssertEqualWithAccuracy(column.hi, 0.5f, 1e-3);
    // Every bin alike, so every window's RMS is a bin's.
    XCTAssertEqualWithAccuracy(column.loudest, sqrtf(0.025f), 1e-3);
    XCTAssertEqualWithAccuracy(column.bandLoudest[0], 0.1f, 1e-3);
    XCTAssertEqual([AudioBPMAnalyzer tempoInResults:decoded.results], 128);
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:decoded.results], 9);
}

- (void)testAnEntryWithoutBandsDecodesWithoutThem {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false)));
    XCTAssertNotNil(decoded);
    XCTAssertFalse(decoded.waveform->hasBands());
    XCTAssertEqualObjects(decoded.results, @{});
}

- (void)testMismatchedVersionIsRejected {
    // Old entries decode their absent version as 0, which must also fail.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion + 1, SummaryBytes(true))));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(0, SummaryBytes(true))));
}

// Format 6 named the tempo and key in fields of their own. It is a miss like
// any older version, so its file decodes again and files its results anew.
- (void)testAFormat6EntryIsAMiss {
    XCTAssertGreaterThan(kCodableAudioWaveformVersion, 6);
    XCTAssertNil(DecodeArchive(Format6Archive(SummaryBytes(true))));
}

- (void)testAMissingOrBrokenSummaryIsRejected {
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, nil)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, [NSData data])));
    NSData *valid = SummaryBytes(true);
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                               [valid subdataWithRange:NSMakeRange(0, valid.length - 8)])));
}

// The cache only files a complete decode, so anything else is corruption.
- (void)testAnIncompleteSummaryIsRejected {
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(true, false))));
}

#pragma mark - Results

// Every property-list class survives the archive, nested as deep as a beat
// grid or a loudness curve would be.
- (void)testEveryPropertyListClassRoundTrips {
    NSDictionary *results = @{
        @"number": @128.5f,
        @"integer": @9,
        @"string": @"8A",
        @"date": [NSDate dateWithTimeIntervalSince1970:1700000000.25],
        @"data": [NSData dataWithBytes:"\x00\x01\xfe\xff" length:4],
        @"array": @[@0.5, @1.0, @1.5, @"beat"],
        @"dictionary": @{@"curve": @[@-14.2, @-13.9], @"unit": @"LUFS", @"at": @[[NSDate dateWithTimeIntervalSince1970:0]]},
        @"empty": @[],
    };
    CodableAudioWaveform *decoded = RoundTripResults(results);
    XCTAssertNotNil(decoded);
    XCTAssertEqualObjects(decoded.results, results);
}

// Results that will not read reject the entry, as a bad summary does, so its
// file decodes again: absent, not an archive, a root that is no dictionary,
// a key that is no string, or a class outside the property list.
- (void)testResultsThatWillNotReadRejectTheEntry {
    NSData *summary = SummaryBytes(false);
    XCTAssertNil(DecodeArchive(ArchiveWithParts(kCodableAudioWaveformVersion, summary, nil)));
    XCTAssertNil(DecodeArchive(ArchiveWithParts(kCodableAudioWaveformVersion, summary,
                                                [@"not an archive" dataUsingEncoding:NSUTF8StringEncoding])));
    XCTAssertNil(DecodeArchive(ArchiveWithParts(kCodableAudioWaveformVersion, summary, ResultBytes(@[@1]))));
    XCTAssertNil(DecodeArchive(ArchiveWithParts(kCodableAudioWaveformVersion, summary, ResultBytes(@{@1: @2}))));
    NSData *url = ResultBytes(@{@"link": [NSURL URLWithString:@"https://example.com"]});
    XCTAssertNotNil(url);
    XCTAssertNil(DecodeArchive(ArchiveWithParts(kCodableAudioWaveformVersion, summary, url)));
}

#pragma mark - BPM coercion (not rejection)

- (void)testNonFiniteOrNegativeBPMIsCoercedToZero {
    // A bad tempo is not a reason to throw away good waveform data: it
    // degrades to "unknown", and still covers the tempo.
    for (id bad in @[@((float)NAN), @((float)INFINITY), @-5.0f, @0.0f, @"128", @[@128]]) {
        CodableAudioWaveform *decoded = RoundTripResults(@{Tempo(): bad});
        XCTAssertNotNil(decoded, @"bpm %@ must not reject the entry", bad);
        XCTAssertNotNil(decoded.results[Tempo()]);
        XCTAssertEqual([AudioBPMAnalyzer tempoInResults:decoded.results], 0.0f);
    }
}

#pragma mark - Musical key coercion (not rejection)

- (void)testAbsentKeyDecodesAsNone {
    // Not the 0 an integer decode fabricates, which is C major.
    CodableAudioWaveform *decoded = RoundTripResults(@{Tempo(): @120.0f});
    XCTAssertNotNil(decoded);
    XCTAssertNil(decoded.results[Key()], @"not run, so it does not cover the key");
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:decoded.results], VibeMusicalKeyNone);
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{}], VibeMusicalKeyNone);
}

- (void)testOutOfRangeOrWrongClassKeyIsCoercedToNone {
    // 0 is a valid key (C major), so the coercion must come from range and
    // class checks, never from a nil-ish read.
    for (id bad in @[@(24), @(-2), @(3.5), @"8A", @[@(3)]]) {
        CodableAudioWaveform *decoded = RoundTripResults(@{Key(): bad});
        XCTAssertNotNil(decoded, @"key %@ must not reject the entry", bad);
        XCTAssertEqual([AudioKeyAnalyzer keyInResults:decoded.results], VibeMusicalKeyNone, @"key %@ must coerce to none", bad);
    }
    CodableAudioWaveform *cMajor = RoundTripResults(@{Key(): @(0)});
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:cMajor.results], 0, @"C major is preserved, not mistaken for absent");
}

@end
