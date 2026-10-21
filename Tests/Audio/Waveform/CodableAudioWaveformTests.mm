//
//  CodableAudioWaveformTests.mm
//  VibeTests
//
//  The cache entry: the summary's archive under its version, and the
//  observers' results that ride along. Format 6 holds Vibe's tempo and key,
//  so these read the entries the analyzers' own fields wrote before the
//  observers. The summary's own bytes are tested in
//  WaveformCore/WaveformSummaryTests.
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

// An entry as format 6 was written before the observers: the tempo inline,
// the key as an object, and both flags.
static void EncodeFormat6(NSCoder *coder, int version, NSData *summary, float bpm, id key,
                          BOOL bpmAnalyzed, BOOL keyAnalyzed) {
    [coder encodeInt:version forKey:@"version"];
    if (summary) {
        [coder encodeBytes:(const uint8_t *)summary.bytes length:summary.length forKey:@"summary"];
    }
    [coder encodeFloat:bpm forKey:@"bpm"];
    if (key) {
        [coder encodeObject:key forKey:@"key"];
    }
    [coder encodeBool:bpmAnalyzed forKey:@"bpmAnalyzed"];
    [coder encodeBool:keyAnalyzed forKey:@"keyAnalyzed"];
}

static NSData *ArchiveWithKeys(int version, NSData *summary, float bpm, id key, BOOL analyzed = YES) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    EncodeFormat6(archiver, version, summary, bpm, key, analyzed, analyzed);
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

static NSData *Archive(CodableAudioWaveform *original) {
    NSError *error = nil;
    return [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:NO error:&error];
}

static CodableAudioWaveform *RoundTrip(CodableAudioWaveform *original) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:Archive(original) error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];
    return decoded;
}

// Stands for the entry as the analyzers' own fields encoded it.
@interface Format6Entry : NSObject <NSCoding>
@property (nonatomic) NSData *summary;
@property (nonatomic) float bpm;
@property (nonatomic) NSInteger key;
@property (nonatomic) BOOL bpmAnalyzed;
@property (nonatomic) BOOL keyAnalyzed;
@end

@implementation Format6Entry
// Another test class's observers, in this process only, are marked skipped.
- (void)encodeWithCoder:(NSCoder *)coder {
    EncodeFormat6(coder, kCodableAudioWaveformVersion, self.summary, self.bpm, @(self.key),
                  self.bpmAnalyzed, self.keyAnalyzed);
    for (NSString *identifier in AudioWaveformObserver.identifiers) {
        if (![@[@"bpm", @"key"] containsObject:identifier]) {
            [coder encodeBool:NO forKey:[identifier stringByAppendingString:@"Analyzed"]];
        }
    }
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    return [super init];
}
@end

static NSDictionary *PropertyList(NSData *archive) {
    return [NSPropertyListSerialization propertyListWithData:archive options:0 format:NULL error:NULL];
}

static NSString *Tempo(void) {
    return AudioBPMAnalyzer.waveformObserver.identifier;
}

static NSString *Key(void) {
    return AudioKeyAnalyzer.waveformObserver.identifier;
}

@implementation CodableAudioWaveformTests

// An entry reads the results of the observers already made, as the mac makes
// both at launch.
- (void)setUp {
    [super setUp];
    (void)Tempo();
    (void)Key();
}

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

#pragma mark - The format does not change

// An entry with both results archives to the property list the analyzers'
// own fields wrote, so neither build re-analyzes the other's entries.
- (void)testAnEntryWithBothResultsArchivesAsFormat6Did {
    NSData *summary = SummaryBytes(true);
    Format6Entry *before = [Format6Entry new];
    before.summary = summary;
    before.bpm = 127.5f;
    before.key = 0;
    before.bpmAnalyzed = YES;
    before.keyAnalyzed = YES;
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver setClassName:NSStringFromClass(CodableAudioWaveform.class) forClass:Format6Entry.class];
    [archiver encodeObject:before forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];

    CodableAudioWaveform *after = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(true)];
    after.results = @{Tempo(): @127.5f, Key(): @0};
    XCTAssertEqualObjects(Archive(after), archiver.encodedData, @"byte for byte");
}

// An observer the decode skipped is marked, and its value left out. A build
// that reads the fields reads that value as none, so the marks decide.
- (void)testASkippedObserverIsMarkedAsFormat6Marked {
    CodableAudioWaveform *original = [[CodableAudioWaveform alloc] initWithWaveform:SampleSummary(false)];
    original.results = @{Tempo(): @120.0f};
    NSDictionary *entry = nil;
    for (id object in PropertyList(Archive(original))[@"$objects"]) {
        if ([object isKindOfClass:NSDictionary.class] && object[@"version"]) {
            entry = object;
        }
    }
    XCTAssertEqualObjects(entry[@"bpmAnalyzed"], @YES);
    XCTAssertEqualObjects(entry[@"keyAnalyzed"], @NO);
    XCTAssertEqualObjects(entry[@"bpm"], @120.0f);
    XCTAssertNil(entry[@"key"], @"absent, which the fields read as none, never C major");
}

- (void)testAFormat6EntryReadsAsResults {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 98.25f, @(14)));
    XCTAssertEqualObjects(decoded.results[Tempo()], @98.25);
    XCTAssertEqualObjects(decoded.results[Key()], @14);
}

- (void)testAnUnmarkedOrSkippedObserverHasNoResult {
    CodableAudioWaveform *skipped = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 0, @(-1), NO));
    XCTAssertNotNil(skipped);
    XCTAssertEqual(skipped.results.count, 0u);

    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    NSData *summary = SummaryBytes(false);
    [archiver encodeBytes:(const uint8_t *)summary.bytes length:summary.length forKey:@"summary"];
    [archiver encodeFloat:120 forKey:@"bpm"];
    [archiver finishEncoding];
    CodableAudioWaveform *unmarked = DecodeArchive(archiver.encodedData);
    XCTAssertNotNil(unmarked);
    XCTAssertNil(unmarked.results[Tempo()], @"every format 6 entry carries its marks");
}

#pragma mark - BPM coercion (not rejection)

- (void)testNonFiniteOrNegativeBPMIsCoercedToZero {
    // A bad tempo is not a reason to throw away good waveform data: it
    // degrades to "unknown", and still covers the tempo.
    for (float bad : {(float)NAN, (float)INFINITY, -5.0f, 0.0f}) {
        CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), bad, nil));
        XCTAssertNotNil(decoded, @"bpm %f must not reject the entry", bad);
        XCTAssertNotNil(decoded.results[Tempo()]);
        XCTAssertEqual([AudioBPMAnalyzer tempoInResults:decoded.results], 0.0f);
    }
}

#pragma mark - Musical key coercion (not rejection)

- (void)testAbsentKeyDecodesAsNone {
    // Not the 0 an integer decode fabricates, which is C major.
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, nil));
    XCTAssertNotNil(decoded);
    XCTAssertNotNil(decoded.results[Key()], @"marked, so it covers the key");
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:decoded.results], VibeMusicalKeyNone);
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:@{}], VibeMusicalKeyNone);
}

- (void)testOutOfRangeOrWrongClassKeyIsCoercedToNone {
    // 0 is a valid key (C major), so the coercion must come from range and
    // class checks, never from a nil-ish read.
    for (id bad in @[@(24), @(-2), @"8A", @[@(3)]]) {
        CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, bad));
        XCTAssertNotNil(decoded, @"key %@ must not reject the entry", bad);
        XCTAssertEqual([AudioKeyAnalyzer keyInResults:decoded.results], VibeMusicalKeyNone, @"key %@ must coerce to none", bad);
    }
    CodableAudioWaveform *cMajor = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, SummaryBytes(false), 120, @(0)));
    XCTAssertEqual([AudioKeyAnalyzer keyInResults:cMajor.results], 0, @"C major is preserved, not mistaken for absent");
}

@end
