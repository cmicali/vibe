//
//  TagLibAudioFileTests.mm
//  VibeAudioTests
//
//  TagLibAudioFile's detection over the real TagLib: the extension's parser
//  first, then the content sniff, and FLAC in Ogg refused. The tests write
//  their own files, with AVFoundation's encoders and an MP3's frames. They
//  carry no tags, since detection never reads one.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "TagLibAudioFile.h"

@interface TagLibAudioFileTests : XCTestCase
@end

@implementation TagLibAudioFileTests {
    NSURL *_dir;
}

- (void)setUp {
    [super setUp];
    _dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                      isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_dir withIntermediateDirectories:YES attributes:nil
                                                 error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_dir error:NULL];
    [super tearDown];
}

// Half a second of stereo silence at 44.1 kHz in the format `extension`
// names. An MP3 is 38 frames of MPEG-1 Layer III at 320 kbps, since no Apple
// encoder writes MP3. The others go through AVAudioFile: AAC in M4A, FLAC,
// and 16-bit PCM in WAV and AIFF.
- (NSURL *)write:(NSString *)extension {
    NSURL *url = [_dir URLByAppendingPathComponent:[@"audio" stringByAppendingPathExtension:extension]];
    if ([extension isEqualToString:@"mp3"]) {
        NSMutableData *bytes = [NSMutableData dataWithLength:38 * 1044];
        for (NSUInteger frame = 0; frame < 38; frame++) {
            memcpy((uint8_t *)bytes.mutableBytes + frame * 1044, "\xFF\xFB\xE0\x00", 4);
        }
        XCTAssertTrue([bytes writeToURL:url atomically:YES]);
        return url;
    }
    NSDictionary<NSString *, NSNumber *> *codecs = @{@"m4a": @(kAudioFormatMPEG4AAC), @"flac": @(kAudioFormatFLAC),
                                                     @"wav": @(kAudioFormatLinearPCM), @"aif": @(kAudioFormatLinearPCM)};
    NSMutableDictionary *settings = [@{AVFormatIDKey: codecs[extension], AVSampleRateKey: @44100,
                                       AVNumberOfChannelsKey: @2} mutableCopy];
    if ([extension isEqualToString:@"flac"]) settings[AVEncoderBitDepthHintKey] = @16;
    if (codecs[extension].unsignedIntValue == kAudioFormatLinearPCM) {
        [settings addEntriesFromDictionary:@{AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO,
                                             AVLinearPCMIsBigEndianKey: @([extension isEqualToString:@"aif"])}];
    }
    NSError *error = nil;
    @autoreleasepool {
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings
                                                   commonFormat:AVAudioPCMFormatInt16 interleaved:YES error:&error];
        AVAudioPCMBuffer *silence = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                   frameCapacity:22050];
        silence.frameLength = 22050;
        memset(silence.int16ChannelData[0], 0, 22050 * 2 * sizeof(int16_t));
        XCTAssertTrue([file writeFromBuffer:silence error:&error], @"%@: %@", extension, error);
    }
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
    NSDictionary<NSString *, NSString *> *sources = @{
            @"m4a-as.flac": @"m4a", @"wav-as.m4a": @"wav", @"wav-as.flac": @"wav", @"aiff-as.m4a": @"aif",
            @"mp3-as.m4a": @"mp3", @"flac-as.m4a": @"flac",
    };
    for (NSString *name in cases) {
        NSURL *url = [self rename:[self write:sources[name]] to:name];
        XCTAssertEqualObjects(Detected(url), cases[name], @"%@", name);
    }
}

- (void)testNoExtensionSniffsTheContent {
    NSDictionary<NSString *, VibeAudioFileFormat> *cases = @{
            @"flac": VibeAudioFileFormatFLAC, @"mp3": VibeAudioFileFormatMP3, @"m4a": VibeAudioFileFormatMP4,
            @"wav": VibeAudioFileFormatWAV, @"aif": VibeAudioFileFormatAIFF,
    };
    for (NSString *extension in cases) {
        NSString *name = [@"audio-" stringByAppendingString:extension];
        NSURL *url = [self rename:[self write:extension] to:name];
        XCTAssertEqualObjects(Detected(url), cases[extension], @"%@", name);
    }
}

// TagLib's FLAC reader skips a leading ID3v2 tag, and so does its sniff.
- (void)testAFLACWithAnID3v2PrefixReadsAsFLAC {
    NSURL *flac = [self write:@"flac"];
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
