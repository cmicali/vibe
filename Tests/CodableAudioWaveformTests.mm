// PINCache unarchives WITHOUT secure coding, so initWithCoder: is all that
// stands between a rotted entry and the renderers, and a bad entry keyed by
// file hash comes back on every play until it ages out.

#import <XCTest/XCTest.h>

#import "AudioWaveform.h"

#include <cmath>
#include <vector>

// Must match NUM_CHUNKS in AudioWaveform.mm — initWithCoder: requires exact
// equality, which is what makes the length check overflow-proof.
static const NSUInteger kEncodedChunkCount = 4096 * 2;

@interface CodableAudioWaveformTests : XCTestCase
@end

@implementation CodableAudioWaveformTests

#pragma mark - Helpers

// No "key" entry: byte-honest for an archive written before keys were
// analyzed.
static NSData *ArchiveWithKeys(int version, id numChunks, NSData *chunkBytes, float bpm) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:version forKey:@"version"];
    [archiver encodeObject:numChunks forKey:@"numChunks"];
    [archiver encodeBytes:(const uint8_t *)chunkBytes.bytes length:chunkBytes.length forKey:@"chunks"];
    [archiver encodeFloat:bpm forKey:@"bpm"];
    [archiver finishEncoding];
    return archiver.encodedData;
}

static NSData *ArchiveWithMusicalKey(int version, id numChunks, NSData *chunkBytes,
                                     float bpm, id key) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:version forKey:@"version"];
    [archiver encodeObject:numChunks forKey:@"numChunks"];
    [archiver encodeBytes:(const uint8_t *)chunkBytes.bytes length:chunkBytes.length forKey:@"chunks"];
    [archiver encodeFloat:bpm forKey:@"bpm"];
    [archiver encodeObject:key forKey:@"key"];
    [archiver finishEncoding];
    return archiver.encodedData;
}

// Decodes straight through initWithCoder: rather than through a root object,
// so a rejected archive surfaces as nil instead of an unarchiver error.
static CodableAudioWaveform *DecodeArchive(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [[CodableAudioWaveform alloc] initWithCoder:unarchiver];
    [unarchiver finishDecoding];
    return decoded;
}

// A well-formed payload: chunk i = (-i/1000, +i/1000), small enough to stay
// exactly representable.
static NSData *ValidChunkBytes(void) {
    std::vector<AudioWaveformCacheChunk> chunks(kEncodedChunkCount, AudioWaveformCacheChunk());
    for (NSUInteger i = 0; i < kEncodedChunkCount; i++) {
        chunks[i].set(-(float)i / 1000.0f, (float)i / 1000.0f);
    }
    return [NSData dataWithBytes:chunks.data()
                          length:kEncodedChunkCount * sizeof(AudioWaveformCacheChunk)];
}

// ArchiveWithKeys plus a "bands" payload.
static NSData *ArchiveWithBands(NSData *bandBytes) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    NSData *chunks = ValidChunkBytes();
    [archiver encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    [archiver encodeObject:@(kEncodedChunkCount) forKey:@"numChunks"];
    [archiver encodeBytes:(const uint8_t *)chunks.bytes length:chunks.length forKey:@"chunks"];
    [archiver encodeBytes:(const uint8_t *)bandBytes.bytes length:bandBytes.length forKey:@"bands"];
    [archiver encodeFloat:120 forKey:@"bpm"];
    [archiver finishEncoding];
    return archiver.encodedData;
}

#pragma mark - Round trip

- (void)testValidArchiveDecodes {
    CodableAudioWaveform *decoded =
            DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @(kEncodedChunkCount),
                                          ValidChunkBytes(), 128.5f));
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.waveform->getNumChunks(), kEncodedChunkCount);
    XCTAssertEqualWithAccuracy(decoded.bpm, 128.5f, 1e-4);
    XCTAssertEqualWithAccuracy(decoded.waveform->getChunkAtIndex(500, kEncodedChunkCount).getMax(),
                               0.5f, 1e-6);
}

- (void)testEncodeThenDecodePreservesChunksBandsAndBPM {
    CodableAudioWaveform *original =
            [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform(true)];
    AudioWaveformCacheChunk marker;
    marker.set(-0.75f, 0.5f, 1.2f, 3.0f);
    original.waveform->setChunkAtIndex(marker, 7);
    const float bands[kAudioWaveformBandCount] = {0.9f, 0.3f, 0.06f};
    original.waveform->setBandSumSquaresAtIndex(bands, 7);
    original.bpm = 174.0f;
    original.key = 21; // Am

    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original
                                        requiringSecureCoding:NO
                                                        error:&error];
    XCTAssertNil(error);

    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];

    XCTAssertNotNil(decoded);
    XCTAssertEqualWithAccuracy(decoded.bpm, 174.0f, 1e-4);
    XCTAssertEqual(decoded.key, 21);
    NSUInteger count = decoded.waveform->getNumChunks();
    XCTAssertEqual(count, original.waveform->getNumChunks());
    XCTAssertEqual(decoded.waveform->getChunkAtIndex(7, count).getMin(), -0.75f);
    XCTAssertEqual(decoded.waveform->getChunkAtIndex(7, count).getMax(), 0.5f);
    XCTAssertEqualWithAccuracy(decoded.waveform->getChunkAtIndex(7, count).getMeanSquare(),
                               1.2f / 3.0f, 1e-6);
    float meanSquares[kAudioWaveformBandCount];
    decoded.waveform->getBandMeanSquares(7, count, meanSquares);
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        // float16's 11 significant bits.
        XCTAssertEqualWithAccuracy(meanSquares[b], bands[b] / 3.0f, bands[b] / 3.0f / 1024, @"band %lu", b);
    }
}

// A long chunk's sum is past float16's 65,504; the archive keeps the mean.
- (void)testALongChunksBandsSurviveTheArchive {
    CodableAudioWaveform *original =
            [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform(true)];
    AudioWaveformCacheChunk chunk;
    chunk.set(-0.9f, 0.9f, 300000, 1000000);
    const float bands[kAudioWaveformBandCount] = {290000, 30000, 9000};
    original.waveform->setChunkAtIndex(chunk, 0);
    original.waveform->setBandSumSquaresAtIndex(bands, 0);

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:NO error:nil];
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:nil];
    unarchiver.requiresSecureCoding = NO;
    CodableAudioWaveform *decoded = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [unarchiver finishDecoding];

    XCTAssertTrue(decoded.waveform->hasBands());
    float meanSquares[kAudioWaveformBandCount];
    decoded.waveform->getBandMeanSquares(0, kEncodedChunkCount, meanSquares);
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        float expected = bands[b] / 1000000;
        XCTAssertEqualWithAccuracy(meanSquares[b], expected, expected / 1024, @"band %lu", b);
    }
}

#pragma mark - Bands

// An entry from before the bands, or from a decode not asked for them, is a
// waveform without them.
- (void)testAnEntryWithoutBandsDecodesWithoutThem {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                                                  @(kEncodedChunkCount), ValidChunkBytes(), 120));
    XCTAssertNotNil(decoded);
    XCTAssertFalse(decoded.waveform->hasBands());
}

// Every band's mean square, as the float16 bits given.
static NSData *HalfBandBytes(uint16_t half) {
    std::vector<uint16_t> bands(kEncodedChunkCount * kAudioWaveformBandCount, half);
    return [NSData dataWithBytes:bands.data() length:bands.size() * sizeof(uint16_t)];
}

- (void)testWholeBandsDecode {
    CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithBands(HalfBandBytes(0x3400)));
    XCTAssertNotNil(decoded);
    XCTAssertTrue(decoded.waveform->hasBands());
}

// Bad bands are not a reason to throw away good waveform data: the entry
// keeps its chunks, and the next request for the bands decodes them again.
// Short, NaN, negative, and float32 sums, the width they once had.
- (void)testBadBandsDegradeToNone {
    NSData *whole = HalfBandBytes(0x3400);
    NSMutableData *poisoned = [whole mutableCopy];
    ((uint16_t *)poisoned.mutableBytes)[whole.length / sizeof(uint16_t) - 1] = 0x7E00;
    std::vector<float> wide(kEncodedChunkCount * kAudioWaveformBandCount, 0.25f);
    for (NSData *bad in @[[whole subdataWithRange:NSMakeRange(0, whole.length - 2)], poisoned,
                          HalfBandBytes(0xB400),
                          [NSData dataWithBytes:wide.data() length:wide.size() * sizeof(float)]]) {
        CodableAudioWaveform *decoded = DecodeArchive(ArchiveWithBands(bad));
        XCTAssertNotNil(decoded);
        XCTAssertFalse(decoded.waveform->hasBands());
        XCTAssertEqualWithAccuracy(decoded.waveform->getChunkAtIndex(500, kEncodedChunkCount).getMax(), 0.5f, 1e-6);
    }
}

#pragma mark - Rejection branches

- (void)testMismatchedVersionIsRejected {
    // Old entries decode their absent version as 0, which must also fail.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion + 1,
                                               @(kEncodedChunkCount), ValidChunkBytes(), 120)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(0, @(kEncodedChunkCount), ValidChunkBytes(), 120)));
}

- (void)testWrongClassForChunkCountIsRejected {
    // Validated before being messaged, or another class raises an
    // unrecognized selector inside the decode.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @"not a number",
                                               ValidChunkBytes(), 120)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @[@1],
                                               ValidChunkBytes(), 120)));
}

- (void)testUnexpectedChunkCountIsRejected {
    std::vector<AudioWaveformCacheChunk> small(100, AudioWaveformCacheChunk());
    NSData *bytes = [NSData dataWithBytes:small.data()
                                   length:100 * sizeof(AudioWaveformCacheChunk)];
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @(100), bytes, 120)));
}

- (void)testTruncatedPayloadIsRejected {
    NSData *valid = ValidChunkBytes();
    NSData *truncated = [valid subdataWithRange:NSMakeRange(0, valid.length - 8)];
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                               @(kEncodedChunkCount), truncated, 120)));
}

- (void)testEmptyPayloadIsRejected {
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                               @(kEncodedChunkCount), [NSData data], 120)));
}

- (void)testNonFiniteSamplesInThePayloadAreRejected {
    // Generation clamps NaN, but the archive carries no checksum.
    for (float poison : {(float)NAN, (float)INFINITY, (float)-INFINITY}) {
        NSMutableData *bytes = [ValidChunkBytes() mutableCopy];
        float *values = (float *)bytes.mutableBytes;
        values[9000] = poison;
        XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                                   @(kEncodedChunkCount), bytes, 120)),
                     @"non-finite sample must be rejected");
    }
}

- (void)testNonFiniteSampleIsCaughtAtEitherEndOfThePayload {
    NSUInteger floatCount = kEncodedChunkCount * sizeof(AudioWaveformCacheChunk) / sizeof(float);
    for (NSUInteger index : {(NSUInteger)0, floatCount - 1}) {
        NSMutableData *bytes = [ValidChunkBytes() mutableCopy];
        ((float *)bytes.mutableBytes)[index] = NAN;
        XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                                   @(kEncodedChunkCount), bytes, 120)),
                     @"non-finite sample at float %lu must be rejected", index);
    }
}

#pragma mark - BPM coercion (not rejection)

- (void)testNonFiniteOrNegativeBPMIsCoercedToZero {
    // A bad tempo is not a reason to throw away good waveform data — unlike
    // the chunk payload, it degrades to "unknown".
    for (float bad : {(float)NAN, (float)INFINITY, -5.0f, 0.0f}) {
        CodableAudioWaveform *decoded =
                DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion,
                                              @(kEncodedChunkCount), ValidChunkBytes(), bad));
        XCTAssertNotNil(decoded, @"bpm %f must not reject the entry", bad);
        XCTAssertEqual(decoded.bpm, 0.0f);
    }
}

#pragma mark - Musical key coercion (not rejection)

- (void)testAbsentKeyDecodesAsNone {
    // Not the 0 an integer decode fabricates, which is C major. This is what
    // keeps entries without a key valid without a version bump.
    CodableAudioWaveform *decoded =
            DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @(kEncodedChunkCount),
                                          ValidChunkBytes(), 120));
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.key, -1);
}

- (void)testValidKeyDecodes {
    CodableAudioWaveform *decoded = DecodeArchive(
            ArchiveWithMusicalKey(kCodableAudioWaveformVersion, @(kEncodedChunkCount),
                                  ValidChunkBytes(), 120, @(21)));
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.key, 21);
}

- (void)testOutOfRangeOrWrongClassKeyIsCoercedToNone {
    // 0 is a valid key (C major), so the coercion must come from range and
    // class checks, never from a nil-ish read.
    for (id bad in @[@(24), @(-2), @"8A", @[@(3)]]) {
        CodableAudioWaveform *decoded = DecodeArchive(
                ArchiveWithMusicalKey(kCodableAudioWaveformVersion, @(kEncodedChunkCount),
                                      ValidChunkBytes(), 120, bad));
        XCTAssertNotNil(decoded, @"key %@ must not reject the entry", bad);
        XCTAssertEqual(decoded.key, -1, @"key %@ must coerce to none", bad);
    }
}

- (void)testCMajorKeyIsPreservedNotMistakenForAbsent {
    CodableAudioWaveform *decoded = DecodeArchive(
            ArchiveWithMusicalKey(kCodableAudioWaveformVersion, @(kEncodedChunkCount),
                                  ValidChunkBytes(), 120, @(0)));
    XCTAssertNotNil(decoded);
    XCTAssertEqual(decoded.key, 0);
}

#pragma mark - snapshot

- (void)testSnapshotIsIndependentOfTheLiveBuffer {
    // Progress ticks hand a snapshot to the main thread while the loader keeps
    // writing the live buffer; sharing it would be a data race.
    CodableAudioWaveform *live =
            [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform()];
    live.bpm = 90.0f;
    live.key = 5; // F
    CodableAudioWaveform *snapshot = [live snapshot];

    AudioWaveformCacheChunk written;
    written.set(-1.0f, 1.0f);
    live.waveform->setChunkAtIndex(written, 3);

    NSUInteger count = snapshot.waveform->getNumChunks();
    XCTAssertNotEqual(snapshot.waveform, live.waveform, @"must not share the buffer");
    XCTAssertEqual(snapshot.waveform->getChunkAtIndex(3, count).getMax(), 0.0f);
    XCTAssertEqual(live.waveform->getChunkAtIndex(3, count).getMax(), 1.0f);
    XCTAssertEqual(snapshot.bpm, 90.0f, @"bpm rides along with the snapshot");
    XCTAssertEqual(snapshot.key, 5, @"key rides along with the snapshot");
}

- (void)testSnapshotOfAnEmptyWaveformIsNil {
    CodableAudioWaveform *empty = [[CodableAudioWaveform alloc] initWithWaveform:nil];
    XCTAssertNil([empty snapshot]);
}

@end
