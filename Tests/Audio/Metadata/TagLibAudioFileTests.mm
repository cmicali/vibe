//
//  TagLibAudioFileTests.mm
//  VibeAudioTests
//
//  TagLibAudioFile's detection over the real TagLib: the extension's parser
//  first, then the content sniff, and FLAC in Ogg refused. The files are
//  AudioTrackMetadataTagFixtures.h's.
//

#import <XCTest/XCTest.h>

#import "AudioTrackMetadataTagFixtures.h"
#import "TagLibAudioFile.h"

@interface TagLibAudioFileTests : XCTestCase
@end

// Each fixture tagged with the class's art, written once for the class.
// A test gets a copy in its own directory, so it may change the copy.
static NSURL *sFixtureDir;
static NSDictionary<NSNumber *, NSURL *> *sFixtures;
static NSData *sArt;

@implementation TagLibAudioFileTests {
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
    }
}

@end
