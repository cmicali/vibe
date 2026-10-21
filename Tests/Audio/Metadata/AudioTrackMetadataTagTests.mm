//
//  AudioTrackMetadataTagTests.mm
//  VibeAudioTests
//
//  The real tag parse over the real TagLib: each format's tags and facts, the
//  tempo and key that beat analysis, embedded art through the bounded decode,
//  and TagLibAudioFile's detection. Every file is written here
//  (AudioTrackMetadataTagFixtures.h), except Ogg's audio, which the render
//  suite's generator makes with ffmpeg; those tests skip without it.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackMetadataTagFixtures.h"
#import "PlatformImage.h"
#import "PlaylistFile.h"
#import "TagLibAudioFile.h"
#import "CloudFileMaterializer.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@interface AudioTrackMetadataTagTests : XCTestCase
@end

// Each fixture tagged with the class's art, written once for the class.
// A test gets a copy in its own directory, so it may change the copy.
static NSURL *sFixtureDir;
static NSDictionary<NSNumber *, NSURL *> *sFixtures;
static NSData *sArt;

@implementation AudioTrackMetadataTagTests {
    NSURL *_dir;
}

+ (void)setUp {
    [super setUp];
    sArt = VibeImageOfColor(300, 0.8, 0.2, 0.3, NO);
    sFixtureDir = VibeTagFixtureDirectory();
    NSMutableDictionary<NSNumber *, NSURL *> *fixtures = [NSMutableDictionary dictionary];
    for (NSInteger fixture = 0; fixture < VibeTagFixtureCount; fixture++) {
        fixtures[@(fixture)] = VibeWriteTagFixture(sFixtureDir, (VibeTagFixture)fixture, sArt, NULL);
    }
    sFixtures = fixtures;
}

+ (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:sFixtureDir error:NULL];
    [super tearDown];
}

- (void)setUp {
    [super setUp];
    _dir = VibeTagFixtureDirectory();
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// The class's copy when `art` is the class's or the format carries none.
// Other art is written fresh.
- (NSURL *)write:(VibeTagFixture)fixture art:(NSData *)art {
    NSURL *url = nil;
    if (art == sArt || !VibeTagFixtureHasArt(fixture)) {
        NSURL *written = sFixtures[@(fixture)];
        NSURL *copy = [_dir URLByAppendingPathComponent:VibeTagFixtureName(fixture)];
        [NSFileManager.defaultManager removeItemAtURL:copy error:NULL];
        if (written && [NSFileManager.defaultManager copyItemAtURL:written toURL:copy error:NULL]) url = copy;
    }
    else {
        url = VibeWriteTagFixture(_dir, fixture, art, NULL);
    }
    if (fixture == VibeTagFixtureVorbis || fixture == VibeTagFixtureOpus) {
        XCTSkipUnless(url != nil, @"%@ needs the render fixtures; run make test-audio with ffmpeg installed",
                      VibeTagFixtureName(fixture));
    }
    XCTAssertNotNil(url, @"%@", VibeTagFixtureName(fixture));
    return url;
}

// The parse the loader runs on a cache miss, with the folder's cover kept
// out so only the file's own art can answer.
static AudioTrackMetadata *Parse(NSURL *url, NSData *__autoreleasing *displayArt) {
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:url displayArtData:displayArt];
    metadata.artwork.folderArt = nil;
    return metadata;
}

static VibeEmbeddedArtExtractionResult Extract(NSURL *url, NSData *__autoreleasing *art) {
    return VibeTagLibArtExtractor()(url.path, art);
}

- (void)assertFixture:(VibeTagFixture)fixture fileType:(VibeAudioFileFormat)fileType rate:(int)rate
             duration:(NSTimeInterval)duration {
    NSURL *url = [self write:fixture art:sArt];
    NSString *name = VibeTagFixtureName(fixture);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse(url, &displayArt);
    XCTAssertTrue(metadata.parsedOK, @"%@", name);
    XCTAssertEqualObjects(metadata.fileType, fileType, @"%@", name);
    XCTAssertEqualObjects(metadata.sampleRate, @(rate), @"%@", name);
    XCTAssertEqualWithAccuracy(metadata.duration, duration, 0.06, @"%@", name);
    if (fixture == VibeTagFixtureW64) {
        XCTAssertEqualObjects(metadata.title, @"plain", @"%@: the filename stands in", name);
        XCTAssertNil(metadata.artist, @"%@", name);
    }
    else {
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertEqualObjects(metadata.artist, kVibeTagArtist, @"%@", name);
    }

    if (VibeTagFixtureHasBPMAndKey(fixture)) {
        // MP4's tmpo atom holds a whole number.
        XCTAssertEqual(metadata.bpm, fixture == VibeTagFixtureM4A ? floorf(kVibeTagBPM) : kVibeTagBPM, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyMake(9, YES), @"%@", name);
    }
    else {
        XCTAssertEqual(metadata.bpm, 0.0f, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyNone, @"%@: untagged is None, never C major", name);
    }

    NSData *extracted = nil;
    VibeEmbeddedArtExtractionResult result = Extract(url, &extracted);
    if (VibeTagFixtureHasArt(fixture)) {
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@", name);
        NSData *thumbnail = metadata.artwork.encodedThumbnailDataForStorage;
        XCTAssertNotNil(thumbnail, @"%@", name);
        CGSize size = VibeEncodedImagePixelSize(thumbnail);
        XCTAssertEqual(MAX(size.width, size.height), kVibeThumbnailArtDimension, @"%@", name);
        XCTAssertEqualObjects(displayArt, sArt, @"%@: art within the bound is archived verbatim", name);
        XCTAssertEqual(result, VibeEmbeddedArtExtractionFoundArt, @"%@", name);
        XCTAssertEqualObjects(extracted, sArt, @"%@", name);
        XCTAssertNotNil([metadata.artwork loadArtBlocking], @"%@", name);
    }
    else {
        XCTAssertFalse(metadata.artwork.hasEmbeddedArt, @"%@", name);
        XCTAssertNil(displayArt, @"%@", name);
        // TagLib has no CAF or W64 parser, so the art read cannot answer.
        BOOL coreAudio = fixture == VibeTagFixtureCAF || fixture == VibeTagFixtureW64;
        XCTAssertEqual(result, coreAudio ? VibeEmbeddedArtExtractionReadFailed : VibeEmbeddedArtExtractionNoArt,
                       @"%@", name);
    }
}

#pragma mark - Formats

// The 38 frames of 1152 at 44.1 kHz that the Info frame counts. The count leaves the Info frame out.
static const NSTimeInterval kMP3Duration = 38 * 1152 / 44100.0;

- (void)testMP3WithID3v23 {
    [self assertFixture:VibeTagFixtureMP3ID3v23 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

- (void)testMP3WithID3v24 {
    [self assertFixture:VibeTagFixtureMP3ID3v24 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

- (void)testMP3WithID3v1Only {
    [self assertFixture:VibeTagFixtureMP3ID3v1 fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
    // TagLib divides the Info frame's bytes by the counted frames' time. The
    // bytes include the Info frame, so this 38-frame stream reads as 328.
    XCTAssertEqualWithAccuracy(Parse([_dir URLByAppendingPathComponent:@"id3v1.mp3"], NULL).bitrate.doubleValue, 320, 10);
}

// TagLib 2 reads an MPEG file's APE tag only under TAGLIB_WITH_APE, which
// the vendored taglib_config.h defines (MP3Gain writes one).
- (void)testMP3WithAnAPETag {
    [self assertFixture:VibeTagFixtureMP3APE fileType:VibeAudioFileFormatMP3 rate:44100 duration:kMP3Duration];
}

// AAC in M4A names its container. The key rides iTunes' freeform atom.
- (void)testM4A {
    [self assertFixture:VibeTagFixtureM4A fileType:VibeAudioFileFormatMP4 rate:44100 duration:0.5];
    XCTAssertGreaterThan(Parse([_dir URLByAppendingPathComponent:@"tagged.m4a"], NULL).bitrate.intValue, 0);
}

- (void)testFLACWithAVorbisCommentAndAPicture {
    [self assertFixture:VibeTagFixtureFLAC fileType:VibeAudioFileFormatFLAC rate:44100 duration:0.5];
}

// TagLib's save keeps the CUESHEET block, so the file still plays as rows.
- (void)testFLACWithAnEmbeddedCueSheet {
    [self assertFixture:VibeTagFixtureFLACCueSheet fileType:VibeAudioFileFormatFLAC rate:44100 duration:0.5];
    NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:
            [_dir URLByAppendingPathComponent:@"cuesheet.flac"]];
    XCTAssertEqual(rows.count, 2u);
}

- (void)testOggVorbis {
    [self assertFixture:VibeTagFixtureVorbis fileType:VibeAudioFileFormatVorbis rate:48000 duration:2];
}

- (void)testOpus {
    [self assertFixture:VibeTagFixtureOpus fileType:VibeAudioFileFormatOpus rate:48000 duration:2];
}

- (void)testWAVWithID3 {
    [self assertFixture:VibeTagFixtureWAVID3 fileType:VibeAudioFileFormatWAV rate:44100 duration:0.5];
}

- (void)testWAVWithRIFFInfo {
    [self assertFixture:VibeTagFixtureWAVInfo fileType:VibeAudioFileFormatWAV rate:44100 duration:0.5];
}

- (void)testAIFFWithID3 {
    [self assertFixture:VibeTagFixtureAIFF fileType:VibeAudioFileFormatAIFF rate:44100 duration:0.5];
}

// CoreAudio's facts: TagLib cannot read CAF, so the info chunk names it.
- (void)testCAF {
    [self assertFixture:VibeTagFixtureCAF fileType:VibeAudioFileFormatCAF rate:44100 duration:0.5];
}

// The fuzz's find, VIBE_FUZZ_SEED=34462054683540093: its flips forge the info
// chunk's size and set its entry count to 0xF90000EE, and CoreAudio's info
// parser never returned. The count alone does not hang it. The chunk is
// refused before CoreAudio reads it, and the format facts stay.
- (void)testCAFInfoChunkWithAnImpossibleCountIsSkipped {
    NSURL *url = [self write:VibeTagFixtureCAF art:nil];
    NSMutableData *data = [NSMutableData dataWithContentsOfURL:url];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    XCTAssertGreaterThan(data.length, 112u);
    XCTAssertEqual(memcmp(bytes + 52, "info", 4), 0, @"the fixture's layout moved");
    static const struct { NSUInteger at; uint8_t mask; } kFlips[] = {
            {85, 0xF6}, {63, 0xD8}, {64, 0xF9}, {70, 0x50}, {67, 0xEC}, {84, 0xE4}, {111, 0xE8}, {78, 0xF7}};
    for (const auto &flip : kFlips) bytes[flip.at] ^= flip.mask;
    XCTAssertEqual(CFSwapInt32BigToHost(*(const uint32_t *)(bytes + 64)), 0xF90000EEu);
    XCTAssertTrue([data writeToURL:url atomically:NO]);

    __block AudioTrackMetadata *metadata = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        metadata = Parse(url, NULL);
        dispatch_semaphore_signal(done);
    });
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                               (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))),
                   0, @"the parse never returned");
    XCTAssertTrue(metadata.parsedOK);
    XCTAssertEqualObjects(metadata.fileType, VibeAudioFileFormatCAF);
    XCTAssertEqualObjects(metadata.sampleRate, @44100);
    // The forged size hides the chunks after the info chunk, so CoreAudio
    // estimates no duration. That is the mutation's doing, not the guard's.
    XCTAssertEqualObjects(metadata.title, @"tagged", @"the filename stands in");
    XCTAssertNil(metadata.artist);
}

- (void)testW64 {
    [self assertFixture:VibeTagFixtureW64 fileType:VibeAudioFileFormatW64 rate:44100 duration:0.5];
}

#pragma mark - Tags beat analysis

- (void)testATaggedTempoAndKeyBeatAnalysis {
    AudioTrackMetadata *tagged = Parse([self write:VibeTagFixtureFLAC art:sArt], NULL);
    AudioTrackMetadata *untagged = Parse([self write:VibeTagFixtureWAVInfo art:nil], NULL);
    for (AudioTrackMetadata *metadata in @[tagged, untagged]) {
        AudioTrack *track = [[AudioTrack alloc] initWithURL:_dir];
        track.detectedBPM = 90;
        track.detectedKey = VibeMusicalKeyMake(0, NO);
        XCTAssertTrue([track installMetadataIfUnresolved:metadata]);
        BOOL isTagged = metadata == tagged;
        XCTAssertEqual(track.bpm, isTagged ? kVibeTagBPM : 90.0f);
        XCTAssertEqual(track.key, isTagged ? VibeMusicalKeyMake(9, YES) : VibeMusicalKeyMake(0, NO));
    }
}

// A tempo outside (0, 1000) and a key no spelling reads are untagged, so
// analysis fills both in.
- (void)testAnUnusableTempoOrKeyStaysUntagged {
    NSURL *url = [self write:VibeTagFixtureFLAC art:sArt];
    for (NSArray<NSString *> *values in @[@[@"5000", @"42"], @[@"-3", @"Q"], @[@"tempo", @""], @[@"0", @"13A"]]) {
        {
            TagLib::FLAC::File file(url.fileSystemRepresentation);
            TagLib::PropertyMap properties = file.properties();
            properties["BPM"] = TagLib::StringList(VibeTagString(values[0]));
            properties["INITIALKEY"] = TagLib::StringList(VibeTagString(values[1]));
            file.setProperties(properties);
            XCTAssertTrue(file.save());
        }
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertTrue(metadata.parsedOK, @"%@", values);
        XCTAssertEqual(metadata.bpm, 0.0f, @"%@", values);
        XCTAssertEqual(metadata.key, VibeMusicalKeyNone, @"%@", values);
    }
}

#pragma mark - Embedded art

// Art that cannot decode fails without a crash or a full-size allocation. The
// file still carries art, so the row is not artless; the bytes are marked
// undecodable, which lets the folder's cover stand in (Audio/Metadata/AGENTS.md).
- (void)assertArtFailsCleanly:(NSData *)art named:(NSString *)label {
    for (NSNumber *fixture in @[@(VibeTagFixtureMP3ID3v24), @(VibeTagFixtureFLAC)]) {
        NSURL *url = [self write:(VibeTagFixture)fixture.integerValue art:art];
        NSString *name = [NSString stringWithFormat:@"%@ in %@", label, url.lastPathComponent];
        NSData *displayArt = nil;
        AudioTrackMetadata *metadata = Parse(url, &displayArt);
        XCTAssertTrue(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@: not artless", name);
        XCTAssertNil(metadata.artwork.encodedThumbnailDataForStorage, @"%@", name);
        XCTAssertNil(displayArt, @"%@", name);
        XCTAssertNil([metadata.artwork loadArtBlocking], @"%@", name);
        XCTAssertFalse(metadata.artNeedsLoad, @"%@: undecodable bytes are not retried", name);

        // The archived entry still says the file has art.
        NSError *error = nil;
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:metadata requiringSecureCoding:YES
                                                                error:&error];
        AudioTrackMetadata *restored = [NSKeyedUnarchiver unarchivedObjectOfClass:AudioTrackMetadata.class
                                                                         fromData:archive error:&error];
        XCTAssertNotNil(restored, @"%@: %@", name, error);
        XCTAssertTrue(restored.artwork.hasEmbeddedArt, @"%@", name);

        NSData *extracted = nil;
        XCTAssertEqual(Extract(url, &extracted), VibeEmbeddedArtExtractionFoundArt, @"%@", name);
        XCTAssertEqualObjects(extracted, art, @"%@", name);
    }
}

- (void)testUndecodableArtFailsCleanly {
    [self assertArtFailsCleanly:VibeTagUndecodableArt() named:@"garbage after a JPEG header"];
}

- (void)testArtDeclaringAHugeImageFailsCleanly {
    [self assertArtFailsCleanly:VibeTagOversizeArt(60000) named:@"a JPEG declaring 60000px"];
}

// A header ImageIO accepts decodes at the bound, never at its declared size.
- (void)testArtDeclaringALargeImageDecodesAtTheBound {
    NSData *art = VibeTagOversizeArt(8000);
    XCTAssertEqual(VibeEncodedImagePixelSize(art).width, 8000);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse([self write:VibeTagFixtureFLAC art:art], &displayArt);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    CGSize thumbnail = VibeEncodedImagePixelSize(metadata.artwork.encodedThumbnailDataForStorage);
    XCTAssertEqual(thumbnail.width, kVibeThumbnailArtDimension);
    XCTAssertEqual(VibeEncodedImagePixelSize(displayArt).width, kVibeArchivedDisplayArtDimension);
    XCTAssertEqual([metadata.artwork loadArtBlocking].size.width, kVibeDisplayArtDimension);
}

// Larger art is downscaled for the rendition, aspect kept.
- (void)testLargeArtArchivesABoundedRendition {
    NSData *art = VibeImageOfColor(1500, 0.8, 0.2, 0.3, YES);
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = Parse([self write:VibeTagFixtureM4A art:art], &displayArt);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    CGSize size = VibeEncodedImagePixelSize(displayArt);
    XCTAssertEqual(size.width, kVibeArchivedDisplayArtDimension);
    XCTAssertEqual(size.height, kVibeArchivedDisplayArtDimension);
}

// A read that fails is unknown, never artless: the folder's cover must not
// replace art the file may still carry.
- (void)testAFailedArtReadIsNotArtless {
    NSData *art = nil;
    XCTAssertEqual(Extract([_dir URLByAppendingPathComponent:@"missing.flac"], &art),
                   VibeEmbeddedArtExtractionReadFailed);
    NSURL *locked = [self write:VibeTagFixtureFLAC art:sArt];
    XCTAssertTrue([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0}
                                                 ofItemAtPath:locked.path error:NULL]);
    XCTAssertEqual(Extract(locked, &art), VibeEmbeddedArtExtractionReadFailed);
    XCTAssertNil(art);

    // A cache hit whose file has since gone.
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc]
            initWithSourceFilePath:[_dir URLByAppendingPathComponent:@"missing.flac"].path
                         extractor:VibeTagLibArtExtractor()];
    artwork.folderArt = nil;
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];
    XCTAssertNil([artwork loadArtBlocking]);
    XCTAssertTrue(artwork.hasEmbeddedArt);
}

// A remote placeholder's tags and art come through its backend's read, by
// range. Its own direct open fails.
- (void)testARemotePlaceholderIsReadThroughItsBackend {
    NSURL *source = [self write:VibeTagFixtureFLAC art:sArt];
    NSData *bytes = [NSData dataWithContentsOfURL:source];
    NSURL *root = [_dir URLByAppendingPathComponent:@"remote" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    NSURL *placeholder = [root URLByAppendingPathComponent:source.lastPathComponent];
    int fd = open(placeholder.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    XCTAssertTrue(fd >= 0 && ftruncate(fd, (off_t)bytes.length) == 0 && fchmod(fd, 0) == 0);
    close(fd);
    __block NSUInteger reads = 0;
    [CloudFileMaterializer setRemoteRoot:root fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                                          void (^onCancel)(dispatch_block_t), NSError **error) {
        return NO;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        reads++;
        return offset + length <= bytes.length ? [bytes subdataWithRange:NSMakeRange(offset, length)] : nil;
    } availability:nil];
    AudioTrackMetadata *metadata = Parse(placeholder, NULL);
    NSData *art = nil;
    VibeEmbeddedArtExtractionResult extracted = Extract(placeholder, &art);
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];

    XCTAssertTrue(metadata.parsedOK);
    XCTAssertEqualObjects(metadata.title, kVibeTagTitle);
    XCTAssertTrue(metadata.artwork.hasEmbeddedArt);
    XCTAssertEqual(extracted, VibeEmbeddedArtExtractionFoundArt);
    XCTAssertEqualObjects(art, sArt);
    XCTAssertGreaterThanOrEqual(reads, 2u, @"one per parse at least");
}

#pragma mark - Detection

static VibeAudioFileFormat Detected(NSURL *url) {
    TagLibAudioFile file(url.fileSystemRepresentation);
    return file.isNull() ? nil : fileTypeForTagLibFile(file.file());
}

- (NSURL *)rename:(NSURL *)url to:(NSString *)name {
    NSURL *renamed = [_dir URLByAppendingPathComponent:name];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:url toURL:renamed error:NULL]);
    return renamed;
}

// The extension's parser refuses the file, so the content sniff decides.
- (void)testAWrongExtensionFallsBackToTheContent {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"m4a-as.flac": VibeAudioFileFormatMP4,
            @"wav-as.m4a": VibeAudioFileFormatWAV,
            @"wav-as.flac": VibeAudioFileFormatWAV,
            @"aiff-as.m4a": VibeAudioFileFormatAIFF,
            @"mp3-as.m4a": VibeAudioFileFormatMP3,
            @"flac-as.m4a": VibeAudioFileFormatFLAC,
    };
    NSDictionary<NSString *, NSNumber *> *sources = @{
            @"m4a-as.flac": @(VibeTagFixtureM4A), @"wav-as.m4a": @(VibeTagFixtureWAVID3),
            @"wav-as.flac": @(VibeTagFixtureWAVID3), @"aiff-as.m4a": @(VibeTagFixtureAIFF),
            @"mp3-as.m4a": @(VibeTagFixtureMP3ID3v24), @"flac-as.m4a": @(VibeTagFixtureFLAC),
    };
    for (NSString *name in cases) {
        NSURL *url = [self rename:[self write:(VibeTagFixture)sources[name].integerValue art:sArt] to:name];
        XCTAssertEqualObjects(Detected(url), cases[name], @"%@", name);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.fileType, cases[name], @"%@", name);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
    }
}

- (void)testNoExtensionSniffsTheContent {
    NSDictionary<NSNumber *, VibeAudioFileFormat> *cases = @{
            @(VibeTagFixtureFLAC): VibeAudioFileFormatFLAC, @(VibeTagFixtureMP3ID3v24): VibeAudioFileFormatMP3,
            @(VibeTagFixtureM4A): VibeAudioFileFormatMP4, @(VibeTagFixtureWAVID3): VibeAudioFileFormatWAV,
            @(VibeTagFixtureAIFF): VibeAudioFileFormatAIFF,
    };
    for (NSNumber *fixture in cases) {
        NSString *name = [VibeTagFixtureName((VibeTagFixture)fixture.integerValue)
                stringByReplacingOccurrencesOfString:@"." withString:@"-"];
        NSURL *url = [self rename:[self write:(VibeTagFixture)fixture.integerValue art:sArt] to:name];
        XCTAssertEqualObjects(Detected(url), cases[fixture], @"%@", name);
        XCTAssertEqualObjects(Parse(url, NULL).title, kVibeTagTitle, @"%@", name);
    }
}

// TagLib's FLAC reader skips a leading ID3v2 tag, and so does its sniff.
- (void)testAFLACWithAnID3v2PrefixReadsAsFLAC {
    NSURL *flac = [self write:VibeTagFixtureFLAC art:sArt];
    NSMutableData *bytes = [NSMutableData dataWithBytes:"ID3\x04\x00\x00\x00\x00\x00\x40" length:10];
    [bytes increaseLengthBy:64];
    [bytes appendData:[NSData dataWithContentsOfURL:flac]];
    for (NSString *name in @[@"prefixed.flac", @"prefixed"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        XCTAssertEqualObjects(Detected(url), VibeAudioFileFormatFLAC, @"%@", name);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertEqualObjects(metadata.title, kVibeTagTitle, @"%@", name);
        XCTAssertEqual(metadata.key, VibeMusicalKeyMake(9, YES), @"%@", name);
        XCTAssertEqualWithAccuracy(metadata.duration, 0.5, 0.06, @"%@", name);
        XCTAssertTrue(metadata.artwork.hasEmbeddedArt, @"%@", name);
    }
}

// FLAC in Ogg carries "fLaC" in its first page. Playback refuses it, so the
// parse must too, by extension and by content.
- (void)testFLACInOggIsAFailedParse {
    NSMutableData *bytes = [NSMutableData dataWithBytes:"OggS" length:4];
    [bytes increaseLengthBy:24];
    [bytes appendBytes:"\x7F" "FLAC\x01\x00\x00\x01" "fLaC\x80\x00\x00\x22" length:17];
    [bytes increaseLengthBy:34];
    for (NSString *name in @[@"ogg.flac", @"ogg.oga", @"ogg"]) {
        NSURL *url = [_dir URLByAppendingPathComponent:name];
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        XCTAssertNil(Detected(url), @"%@", name);
        AudioTrackMetadata *metadata = Parse(url, NULL);
        XCTAssertFalse(metadata.parsedOK, @"%@", name);
        XCTAssertEqualObjects(metadata.title, name.stringByDeletingPathExtension, @"%@", name);
    }
}

@end
