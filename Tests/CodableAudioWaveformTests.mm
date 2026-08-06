//
// The disk-cache archive contract. PINCache unarchives WITHOUT secure
// coding, so initWithCoder: is the only thing standing between a corrupt or
// bit-rotted entry and the renderers — and a bad entry keyed by file hash
// would come back on every play until it ages out. Every rejection branch is
// asserted independently here.
//

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

// Builds an archive with hand-chosen values for the four keys initWithCoder:
// reads, so each validation branch can be exercised in isolation.
static NSData *ArchiveWithKeys(int version, id numChunks, NSData *chunkBytes, float bpm) {
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [archiver encodeInt:version forKey:@"version"];
    [archiver encodeObject:numChunks forKey:@"numChunks"];
    [archiver encodeBytes:(const uint8_t *)chunkBytes.bytes length:chunkBytes.length forKey:@"chunks"];
    [archiver encodeFloat:bpm forKey:@"bpm"];
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

- (void)testEncodeThenDecodePreservesChunksAndBPM {
    CodableAudioWaveform *original =
            [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform()];
    AudioWaveformCacheChunk marker;
    marker.set(-0.75f, 0.5f);
    original.waveform->setChunkAtIndex(marker, 7);
    original.bpm = 174.0f;

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
    NSUInteger count = decoded.waveform->getNumChunks();
    XCTAssertEqual(count, original.waveform->getNumChunks());
    XCTAssertEqual(decoded.waveform->getChunkAtIndex(7, count).getMin(), -0.75f);
    XCTAssertEqual(decoded.waveform->getChunkAtIndex(7, count).getMax(), 0.5f);
}

#pragma mark - Rejection branches

- (void)testMismatchedVersionIsRejected {
    // Old entries decode their absent version as 0, which must also fail.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion + 1,
                                               @(kEncodedChunkCount), ValidChunkBytes(), 120)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(0, @(kEncodedChunkCount), ValidChunkBytes(), 120)));
}

- (void)testWrongClassForChunkCountIsRejected {
    // Validated before being messaged: a bit-rotted entry that decodes
    // numChunks as some other class would otherwise raise an unrecognized
    // selector inside the decode, ahead of the payload checks.
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @"not a number",
                                               ValidChunkBytes(), 120)));
    XCTAssertNil(DecodeArchive(ArchiveWithKeys(kCodableAudioWaveformVersion, @[@1],
                                               ValidChunkBytes(), 120)));
}

- (void)testUnexpectedChunkCountIsRejected {
    // The encoder only ever writes kEncodedChunkCount; requiring exact
    // equality is what removes the unchecked multiply from the length check.
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
    // Generation clamps NaN before chunks are stored, but the archive carries
    // no checksum — a single rotted float would otherwise poison the
    // renderers' geometry on every play of this file until the entry expires.
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
    NSUInteger floatCount = kEncodedChunkCount * 2;
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

#pragma mark - snapshot

- (void)testSnapshotIsIndependentOfTheLiveBuffer {
    // Progress ticks hand a snapshot to the main thread while the loader keeps
    // writing the live buffer; sharing it would be a data race.
    CodableAudioWaveform *live =
            [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform()];
    live.bpm = 90.0f;
    CodableAudioWaveform *snapshot = [live snapshot];

    AudioWaveformCacheChunk written;
    written.set(-1.0f, 1.0f);
    live.waveform->setChunkAtIndex(written, 3);

    NSUInteger count = snapshot.waveform->getNumChunks();
    XCTAssertNotEqual(snapshot.waveform, live.waveform, @"must not share the buffer");
    XCTAssertEqual(snapshot.waveform->getChunkAtIndex(3, count).getMax(), 0.0f);
    XCTAssertEqual(live.waveform->getChunkAtIndex(3, count).getMax(), 1.0f);
    XCTAssertEqual(snapshot.bpm, 90.0f, @"bpm rides along with the snapshot");
}

- (void)testSnapshotOfAnEmptyWaveformIsNil {
    CodableAudioWaveform *empty = [[CodableAudioWaveform alloc] initWithWaveform:nil];
    XCTAssertNil([empty snapshot]);
}

@end
