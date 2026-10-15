//
//  AudioTrackMetadataFuzzTests.mm
//  VibeAudioTests
//
//  Seeded mutations of the tag tests' fixtures through the real parse and art
//  read. A mutant may parse or fail. It must return within a bound and throw
//  nothing. The original must parse the same after its fixture's mutants.
//
//  Seeded: the seed and the mutation are in every assertion message.
//  VIBE_FUZZ_SEED re-runs one base seed and VIBE_FUZZ_ROUNDS raises the
//  rounds per fixture. Through xcodebuild, prefix each with TEST_RUNNER_.
//

#import <XCTest/XCTest.h>

#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "TagLibAudioFile.h"

// std::min, never MIN: a MIN that evaluates an argument twice draws the
// generator twice and breaks the bound it computes.
#include <algorithm>

// The tag's bytes: what tagging changed, found by the common prefix and
// suffix of the file before and after. The RIFF and FORM size at 4..7 always
// changes, so it does not end the prefix.
static NSRange TagRegion(NSData *untagged, NSData *tagged) {
    const uint8_t *a = (const uint8_t *)untagged.bytes, *b = (const uint8_t *)tagged.bytes;
    NSUInteger shorter = MIN(untagged.length, tagged.length);
    NSUInteger prefix = 0;
    while (prefix < shorter && (a[prefix] == b[prefix] || (prefix >= 4 && prefix < 8))) prefix++;
    NSUInteger suffix = 0;
    while (suffix < shorter - prefix && a[untagged.length - 1 - suffix] == b[tagged.length - 1 - suffix]) suffix++;
    if (prefix >= tagged.length - suffix) {
        return NSMakeRange(0, tagged.length); // the tag rewrote nothing: fuzz the whole file
    }
    return NSMakeRange(prefix, tagged.length - suffix - prefix);
}

// Where a size field sits relative to a marker, for each container's tags.
typedef struct {
    const char *marker;
    NSInteger offset;
    BOOL littleEndian;
} SizeField;

static const SizeField kSizeFields[] = {
        {"ID3", 6, NO},                                     // ID3v2 header, synchsafe
        {"TIT2", 4, NO}, {"TPE1", 4, NO}, {"TBPM", 4, NO}, {"TKEY", 4, NO}, {"APIC", 4, NO},
        {"moov", -4, NO}, {"udta", -4, NO}, {"meta", -4, NO}, {"ilst", -4, NO},
        {"covr", -4, NO}, {"data", -4, NO}, {"tmpo", -4, NO}, {"----", -4, NO},
        {"id3 ", 4, YES}, {"ID3 ", 4, NO}, {"LIST", 4, YES}, {"INAM", 4, YES},
        {"APETAGEX", 12, YES},
        {"TITLE=", -4, YES}, {"BPM=", -4, YES}, {"METADATA_BLOCK_PICTURE=", -4, YES},
        {"OpusTags", 8, YES}, {"\x03vorbis", 7, YES},
};

static const uint32_t kSizeValues[] = {0, 1, 0x7F7F7F7F, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFFFF0};

static void Store32(uint8_t *at, uint32_t value, BOOL littleEndian) {
    uint32_t stored = littleEndian ? CFSwapInt32HostToLittle(value) : CFSwapInt32HostToBig(value);
    memcpy(at, &stored, 4);
}

static uint32_t LoadBE32(const uint8_t *at) {
    uint32_t stored;
    memcpy(&stored, at, 4); // unaligned
    return CFSwapInt32BigToHost(stored);
}

// Every size field a marker in `region` names.
static NSArray<NSArray<NSNumber *> *> *SizeFieldsIn(NSData *data, NSRange region) {
    NSMutableArray<NSArray<NSNumber *> *> *found = [NSMutableArray array];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (const SizeField &field : kSizeFields) {
        size_t length = strlen(field.marker);
        for (NSUInteger at = region.location; at + length <= NSMaxRange(region); at++) {
            if (memcmp(bytes + at, field.marker, length) != 0) continue;
            NSInteger size = (NSInteger)at + field.offset;
            if (size >= 0 && (NSUInteger)size + 4 <= data.length) {
                [found addObject:@[@(size), @(field.littleEndian)]];
            }
        }
    }
    return found;
}

// The PICTURE block of a FLAC: its header's offset, or NSNotFound.
static NSUInteger FLACPictureBlock(NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (data.length < 8 || memcmp(bytes, "fLaC", 4) != 0) return NSNotFound;
    for (NSUInteger at = 4; at + 4 <= data.length;) {
        NSUInteger length = (NSUInteger)bytes[at + 1] << 16 | (NSUInteger)bytes[at + 2] << 8 | bytes[at + 3];
        if ((bytes[at] & 0x7F) == 6) return at;
        if (bytes[at] & 0x80) break;
        at += 4 + length;
    }
    return NSNotFound;
}

static NSData *Mutate(NSData *original, NSRange region, VibeFuzzRandom *random, NSString **description) {
    NSMutableData *data = [original mutableCopy];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger length = data.length;
    // A tag at the end starts where the audio ends.
    NSUInteger audioStart = NSMaxRange(region) == length ? region.location : NSMaxRange(region);
    switch (VibeFuzzBelow(random, 9)) {
        case 0: {
            NSUInteger at = VibeFuzzBelow(random, length);
            data.length = at;
            *description = [NSString stringWithFormat:@"truncate at %lu", (unsigned long)at];
            break;
        }
        case 1: {
            NSUInteger at = std::min(length, region.location + VibeFuzzBelow(random, 16));
            data.length = at;
            *description = [NSString stringWithFormat:@"truncate in the tag header at %lu", (unsigned long)at];
            break;
        }
        case 2: {
            NSUInteger at = region.location + VibeFuzzBelow(random, region.length);
            data.length = at;
            *description = [NSString stringWithFormat:@"truncate in the tag at %lu", (unsigned long)at];
            break;
        }
        case 3:
            data.length = audioStart;
            *description = [NSString stringWithFormat:@"truncate at the audio start %lu", (unsigned long)audioStart];
            break;
        case 4: {
            NSUInteger flips = 1 + VibeFuzzBelow(random, 8);
            NSMutableArray<NSString *> *at = [NSMutableArray array];
            for (NSUInteger i = 0; i < flips; i++) {
                NSUInteger offset = region.location + VibeFuzzBelow(random, region.length);
                bytes[offset] ^= (uint8_t)(1 + VibeFuzzBelow(random, 255));
                [at addObject:@(offset).stringValue];
            }
            *description = [@"flip bytes at " stringByAppendingString:[at componentsJoinedByString:@","]];
            break;
        }
        case 5: case 6: {
            NSArray<NSArray<NSNumber *> *> *fields = SizeFieldsIn(data, region);
            uint32_t value = VibeFuzzBelow(random, 4) == 0
                    ? (uint32_t)(length + VibeFuzzBelow(random, 1 << 20))   // past the end of the file
                    : kSizeValues[VibeFuzzBelow(random, sizeof kSizeValues / sizeof kSizeValues[0])];
            if (fields.count == 0) {
                NSUInteger at = region.location + VibeFuzzBelow(random, region.length - MIN(region.length, 4));
                Store32(bytes + at, value, VibeFuzzBelow(random, 2));
                *description = [NSString stringWithFormat:@"size %#x at %lu", value, (unsigned long)at];
                break;
            }
            NSArray<NSNumber *> *field = fields[VibeFuzzBelow(random, fields.count)];
            Store32(bytes + field[0].unsignedIntegerValue, value, field[1].boolValue);
            *description = [NSString stringWithFormat:@"size field %#x at %@", value, field[0]];
            break;
        }
        case 7: {
            NSUInteger at = region.location + VibeFuzzBelow(random, region.length);
            NSUInteger span = std::min(8 + VibeFuzzBelow(random, 512), length - at);
            NSData *copy = [data subdataWithRange:NSMakeRange(at, span)];
            [data replaceBytesInRange:NSMakeRange(at + span, 0) withBytes:copy.bytes length:copy.length];
            *description = [NSString stringWithFormat:@"duplicate %lu bytes at %lu", (unsigned long)span,
                                                      (unsigned long)at];
            break;
        }
        case 8: {
            NSUInteger block = FLACPictureBlock(data);
            if (block == NSNotFound) {
                // Not a FLAC: the picture's frame or atom claims too much instead.
                NSArray<NSArray<NSNumber *> *> *fields = SizeFieldsIn(data, region);
                if (fields.count == 0) {
                    data.length = audioStart;
                    *description = [NSString stringWithFormat:@"truncate at the audio start %lu",
                                                              (unsigned long)audioStart];
                    break;
                }
                NSArray<NSNumber *> *field = fields[VibeFuzzBelow(random, fields.count)];
                Store32(bytes + field[0].unsignedIntegerValue, (uint32_t)length * 2, field[1].boolValue);
                *description = [NSString stringWithFormat:@"size field %#lx at %@", (unsigned long)length * 2, field[0]];
                break;
            }
            if (VibeFuzzBelow(random, 2)) {
                bytes[block + 1] = bytes[block + 2] = bytes[block + 3] = 0xFF;
                *description = [NSString stringWithFormat:@"PICTURE block at %lu claims 16 MB", (unsigned long)block];
                break;
            }
            // type, MIME length and text, description length and text, four
            // dimensions, then the data length.
            *description = @"PICTURE block too short to reach its data length";
            NSUInteger at = block + 4 + 4;
            if (at + 4 > length) break;
            at += 4 + LoadBE32(bytes + at);
            if (at + 4 > length) break;
            at += 4 + LoadBE32(bytes + at) + 16;
            if (at + 4 > length) break;
            Store32(bytes + at, (uint32_t)length + 1 + (uint32_t)VibeFuzzBelow(random, 1 << 24), NO);
            *description = [NSString stringWithFormat:@"PICTURE data length past the file at %lu", (unsigned long)at];
            break;
        }
    }
    return data;
}

@interface AudioTrackMetadataFuzzTests : XCTestCase
@end

@implementation AudioTrackMetadataFuzzTests {
    NSURL *_dir;
    uint64_t _baseSeed;
    NSUInteger _rounds;
    dispatch_queue_t _queue;
}

- (void)setUp {
    [super setUp];
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    _baseSeed = VibeFuzzBaseSeed(0x7A6F0E5EED5EEDULL);
    _rounds = environment[@"VIBE_FUZZ_ROUNDS"] ? (NSUInteger)environment[@"VIBE_FUZZ_ROUNDS"].integerValue : 128;
    _dir = VibeTagFixtureDirectory();
    _queue = dispatch_queue_create("VibeAudioTests.tag-fuzz",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// The parse and the art read on a worker, timed there on the uptime clock the
// art loader's backoff uses. NO when the worker outlived the hang guard.
- (BOOL)parse:(NSURL *)url metadata:(AudioTrackMetadata *__autoreleasing *)metadata
      elapsed:(NSTimeInterval *)elapsed exception:(NSString *__autoreleasing *)exception {
    __block AudioTrackMetadata *parsed = nil;
    __block NSTimeInterval took = 0;
    __block NSString *thrown = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_queue, ^{
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        try {
            @try {
                parsed = [AudioTrackMetadata metadataWithURL:url displayArtData:NULL];
                NSData *art = nil;
                VibeTagLibArtExtractor()(url.path, &art);
            }
            @catch (NSException *e) {
                thrown = [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
            }
        }
        catch (...) {
            thrown = @"a C++ exception";
        }
        took = NSProcessInfo.processInfo.systemUptime - start;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                    (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
        return NO;
    }
    *metadata = parsed;
    *elapsed = took;
    *exception = thrown;
    return YES;
}

// Well inside the hang guard, and far past a parse of these small files,
// even under the sanitizers.
static const NSTimeInterval kParseBound = 3;

- (void)testMutatedTagsParseOrFailCleanly {
    NSUInteger mutants = 0, parsed = 0;
    for (NSInteger index = 0; index < VibeTagFixtureCount; index++) {
        VibeTagFixture fixture = (VibeTagFixture)index;
        NSString *name = VibeTagFixtureName(fixture);
        NSURL *untaggedURL = nil;
        NSData *art = VibeImageOfColor(64, 0.8, 0.2, 0.3, NO);
        NSURL *url = VibeWriteTagFixture(_dir, fixture, VibeTagFixtureHasArt(fixture) ? art : nil, &untaggedURL);
        if (!url) {
            // Ogg without the render fixtures; AudioTrackMetadataTagTests reports the skip.
            XCTAssertTrue(fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus, @"%@", name);
            continue;
        }
        NSData *original = [NSData dataWithContentsOfURL:url];
        NSRange region = TagRegion([NSData dataWithContentsOfURL:untaggedURL], original);
        AudioTrackMetadata *baseline = nil;
        NSTimeInterval elapsed = 0;
        NSString *exception = nil;
        XCTAssertTrue([self parse:url metadata:&baseline elapsed:&elapsed exception:&exception]);
        XCTAssertTrue(baseline.parsedOK, @"%@", name);

        NSURL *mutantURL = [[_dir URLByAppendingPathComponent:@"mutants" isDirectory:YES]
                URLByAppendingPathComponent:name];
        [NSFileManager.defaultManager createDirectoryAtURL:mutantURL.URLByDeletingLastPathComponent
                               withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSUInteger round = 0; round < _rounds; round++) {
            uint64_t seed = _baseSeed + (uint64_t)index * 1000000 + round;
            VibeFuzzRandom random = {seed};
            for (int warm = 0; warm < 4; warm++) VibeFuzzNext(&random); // spread nearby seeds
            NSString *mutation = @"none";
            NSData *mutant = Mutate(original, region, &random, &mutation);
            XCTAssertTrue([mutant writeToURL:mutantURL atomically:NO]);
            NSString *label = [NSString stringWithFormat:@"%@ seed %llu: %@", name, seed, mutation];

            AudioTrackMetadata *metadata = nil;
            if (![self parse:mutantURL metadata:&metadata elapsed:&elapsed exception:&exception]) {
                XCTFail(@"%@: no answer within %d s", label, VIBE_TEST_HANG_TIMEOUT);
                return; // the worker still holds the queue
            }
            mutants++;
            parsed += metadata.parsedOK;
            XCTAssertNotNil(metadata, @"%@", label);
            XCTAssertNil(exception, @"%@", label);
            XCTAssertLessThan(elapsed, kParseBound, @"%@", label);
        }

        AudioTrackMetadata *again = nil;
        XCTAssertTrue([self parse:url metadata:&again elapsed:&elapsed exception:&exception], @"%@", name);
        XCTAssertTrue(again.parsedOK, @"%@: the original after its mutants", name);
        XCTAssertEqualObjects(again.title, baseline.title, @"%@: the original after its mutants", name);
        XCTAssertEqual(again.bpm, baseline.bpm, @"%@: the original after its mutants", name);
        XCTAssertEqual(again.key, baseline.key, @"%@: the original after its mutants", name);
        XCTAssertEqual(again.duration, baseline.duration, @"%@: the original after its mutants", name);
    }
    XCTAssertGreaterThan(mutants, 0u);
    // Nothing to assert on the ratio; it shows whether the mutations still
    // reach the parsers rather than all failing at the door.
    [XCTContext runActivityNamed:[NSString stringWithFormat:@"%lu mutants, %lu parsed", (unsigned long)mutants,
                                                            (unsigned long)parsed]
                           block:^(id<XCTActivity> activity) { (void)activity; }];
}

@end
