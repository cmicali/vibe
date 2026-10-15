//
//  AudioTrackMetadataTagFixtures.h
//  VibeAudioTests
//
//  Tagged files for the tag and fuzz tests. The audio comes from
//  AudioFixtures.h or a stock Apple encoder. The tags come from TagLib's own
//  writers, except APE, which the vendored TagLib cannot write to MPEG. Ogg
//  has no Apple encoder. So Vorbis and Opus start from the render suite's
//  generated fixtures, and are nil without them. C++, so only .mm files
//  import it.
//

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AudioFixtures.h"
#import "TestFilesystemGuard.h"

#include <attachedpictureframe.h>
#include <aifffile.h>
#include <flacfile.h>
#include <flacpicture.h>
#include <id3v1tag.h>
#include <id3v2tag.h>
#include <infotag.h>
#include <mp4file.h>
#include <mpegfile.h>
#include <opusfile.h>
#include <tpropertymap.h>
#include <vorbisfile.h>
#include <wavfile.h>

static NSString *const kVibeTagTitle = @"Tagged Title";
static NSString *const kVibeTagArtist = @"Tagged Artist";
static const float kVibeTagBPM = 128.5f;
// Am, which VibeMusicalKeyFromString reads as pitch class 9, minor.
static NSString *const kVibeTagKey = @"Am";

typedef NS_ENUM(NSInteger, VibeTagFixture) {
    VibeTagFixtureMP3ID3v23,
    VibeTagFixtureMP3ID3v24,
    VibeTagFixtureMP3ID3v1,
    VibeTagFixtureMP3APE,
    VibeTagFixtureM4A,
    VibeTagFixtureFLAC,
    VibeTagFixtureFLACCueSheet,
    VibeTagFixtureVorbis,
    VibeTagFixtureOpus,
    VibeTagFixtureWAVID3,
    VibeTagFixtureWAVInfo,
    VibeTagFixtureAIFF,
    VibeTagFixtureCAF,
    VibeTagFixtureW64,
    VibeTagFixtureCount,
};

static inline NSString *VibeTagFixtureName(VibeTagFixture fixture) {
    static NSString *const names[VibeTagFixtureCount] = {
            @"id3v23.mp3", @"id3v24.mp3", @"id3v1.mp3", @"ape.mp3", @"tagged.m4a", @"tagged.flac",
            @"cuesheet.flac", @"tagged.ogg", @"tagged.opus", @"id3.wav", @"info.wav", @"tagged.aif",
            @"tagged.caf", @"plain.w64"};
    return names[fixture];
}

// The formats whose tag carries a tempo and a key, and the ones carrying art.
static inline BOOL VibeTagFixtureHasBPMAndKey(VibeTagFixture fixture) {
    return fixture != VibeTagFixtureMP3ID3v1 && fixture != VibeTagFixtureWAVInfo
            && fixture != VibeTagFixtureCAF && fixture != VibeTagFixtureW64;
}

static inline BOOL VibeTagFixtureHasArt(VibeTagFixture fixture) {
    return VibeTagFixtureHasBPMAndKey(fixture) && fixture != VibeTagFixtureMP3APE;
}

// A fresh directory inside TestFilesystemGuard's per-process root, which the
// guard removes at exit and a later run removes after a crash.
static inline NSURL *VibeTagFixtureDirectory(void) {
    NSURL *dir = [NSURL fileURLWithPath:[VibeTestProcessRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                            isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES
                                            attributes:nil error:NULL];
    return dir;
}

// A side x side image of one color, PNG or JPEG.
static inline NSData *VibeTagArtImage(size_t side, BOOL jpeg) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, 0.8, 0.2, 0.3, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data,
            (__bridge CFStringRef)(jpeg ? UTTypeJPEG : UTTypePNG).identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}

// A JPEG's start-of-image and APP0 marker, then bytes no decoder reads.
static inline NSData *VibeTagUndecodableArt(void) {
    NSMutableData *data = [NSMutableData dataWithBytes:"\xFF\xD8\xFF\xE0\x00\x10JFIF\x00" length:11];
    for (uint32_t i = 0; i < 2048; i++) {
        uint8_t byte = (uint8_t)(i * 2654435761u >> 24);
        [data appendBytes:&byte length:1];
    }
    return data;
}

// A 16px JPEG whose frame header declares `side` x `side`. ImageIO refuses
// the header past about 10000px. Below that it decodes, filling what the
// bytes lack, so only the bounded decode keeps the bitmap small.
static inline NSData *VibeTagOversizeArt(uint16_t side) {
    NSMutableData *data = [VibeTagArtImage(16, YES) mutableCopy];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    for (NSUInteger i = 0; i + 9 < data.length; i++) {
        if (bytes[i] == 0xFF && (bytes[i + 1] == 0xC0 || bytes[i + 1] == 0xC2)) {
            bytes[i + 5] = bytes[i + 7] = (uint8_t)(side >> 8);
            bytes[i + 6] = bytes[i + 8] = (uint8_t)side;
            break;
        }
    }
    return data;
}

static inline void VibeAppendLE32(NSMutableData *data, uint32_t value) {
    uint32_t little = CFSwapInt32HostToLittle(value);
    [data appendBytes:&little length:4];
}

// An APEv2 tag of UTF-8 items and a footer, no header, as written at a file's
// end.
static inline NSData *VibeAPETag(NSArray<NSArray<NSString *> *> *items) {
    NSMutableData *tag = [NSMutableData data];
    for (NSArray<NSString *> *item in items) {
        NSData *value = [item[1] dataUsingEncoding:NSUTF8StringEncoding];
        VibeAppendLE32(tag, (uint32_t)value.length);
        VibeAppendLE32(tag, 0);
        [tag appendData:[item[0] dataUsingEncoding:NSASCIIStringEncoding]];
        [tag increaseLengthBy:1];
        [tag appendData:value];
    }
    uint32_t size = (uint32_t)tag.length + 32;
    [tag appendBytes:"APETAGEX" length:8];
    VibeAppendLE32(tag, 2000);
    VibeAppendLE32(tag, size);
    VibeAppendLE32(tag, (uint32_t)items.count);
    VibeAppendLE32(tag, 0);
    [tag increaseLengthBy:8];
    return tag;
}

// Half a second of a 440 Hz tone, 16-bit stereo at 44.1 kHz.
static inline AVAudioPCMBuffer *VibeTagFixtureTone(void) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                             sampleRate:44100 channels:2 interleaved:YES];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:22050];
    buffer.frameLength = 22050;
    int16_t *samples = buffer.int16ChannelData[0];
    for (NSUInteger i = 0; i < 22050; i++) {
        samples[2 * i] = samples[2 * i + 1] = (int16_t)(8000 * sin(2 * M_PI * 440 * i / 44100.0));
    }
    return buffer;
}

// AAC in M4A or FLAC through AVAudioFile, so the container is Apple's own.
static inline NSURL *VibeTagFixtureEncode(NSURL *url, AudioFormatID codec) {
    NSError *error = nil;
    @autoreleasepool {
        NSMutableDictionary *settings = [@{AVFormatIDKey: @(codec), AVSampleRateKey: @44100,
                                           AVNumberOfChannelsKey: @2} mutableCopy];
        if (codec == kAudioFormatFLAC) settings[AVEncoderBitDepthHintKey] = @16;
        AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings
                                                   commonFormat:AVAudioPCMFormatInt16
                                                    interleaved:YES error:&error];
        if (![file writeFromBuffer:VibeTagFixtureTone() error:&error]) {
            return nil;
        }
    }
    return url;
}

// Inserts a metadata block right after STREAMINFO.
static inline BOOL VibeInsertFLACBlock(NSURL *url, uint8_t type, NSData *block) {
    NSMutableData *file = [NSMutableData dataWithContentsOfURL:url];
    if (file.length < 8 || memcmp(file.bytes, "fLaC", 4) != 0) {
        return NO;
    }
    uint8_t *bytes = (uint8_t *)file.mutableBytes;
    BOOL wasLast = (bytes[4] & 0x80) != 0;
    bytes[4] &= 0x7F;
    NSUInteger after = 8 + ((NSUInteger)bytes[5] << 16 | (NSUInteger)bytes[6] << 8 | bytes[7]);
    NSUInteger length = block.length;
    uint8_t header[4] = {(uint8_t)(type | (wasLast ? 0x80 : 0)), (uint8_t)(length >> 16),
                         (uint8_t)(length >> 8), (uint8_t)length};
    NSMutableData *insert = [NSMutableData dataWithBytes:header length:4];
    [insert appendData:block];
    [file replaceBytesInRange:NSMakeRange(after, 0) withBytes:insert.bytes length:insert.length];
    return [file writeToURL:url atomically:YES];
}

static inline TagLib::String VibeTagString(NSString *string) {
    return TagLib::String(string.UTF8String, TagLib::String::UTF8);
}

static inline TagLib::ByteVector VibeTagBytes(NSData *data) {
    return TagLib::ByteVector((const char *)data.bytes, (unsigned int)data.length);
}

static inline TagLib::PropertyMap VibeTagProperties(BOOL bpmAndKey) {
    TagLib::PropertyMap properties;
    properties["TITLE"] = TagLib::StringList(VibeTagString(kVibeTagTitle));
    properties["ARTIST"] = TagLib::StringList(VibeTagString(kVibeTagArtist));
    if (bpmAndKey) {
        properties["BPM"] = TagLib::StringList(VibeTagString([NSString stringWithFormat:@"%g", kVibeTagBPM]));
        properties["INITIALKEY"] = TagLib::StringList(VibeTagString(kVibeTagKey));
    }
    return properties;
}

static inline void VibeAddAPIC(TagLib::ID3v2::Tag *tag, NSData *art) {
    auto frame = new TagLib::ID3v2::AttachedPictureFrame();
    frame->setMimeType("image/png");
    frame->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
    frame->setPicture(VibeTagBytes(art));
    tag->addFrame(frame);
}

static inline TagLib::FLAC::Picture *VibeFLACPicture(NSData *art) {
    auto picture = new TagLib::FLAC::Picture();
    picture->setType(TagLib::FLAC::Picture::FrontCover);
    picture->setMimeType("image/png");
    picture->setData(VibeTagBytes(art));
    return picture;
}

// Writes `fixture` into `dir`, its audio first and then its tags, with `art`
// as its picture where the format carries one. `untagged` receives a copy
// from before the tags, which the fuzz diffs to find the tag's bytes. nil
// when the format's source is unavailable.
static inline NSURL *VibeWriteTagFixture(NSURL *dir, VibeTagFixture fixture, NSData *art,
                                         NSURL *__autoreleasing *untagged) {
    NSString *name = VibeTagFixtureName(fixture);
    NSURL *url = [dir URLByAppendingPathComponent:name];
    NSError *error = nil;
    switch (fixture) {
        case VibeTagFixtureMP3ID3v23: case VibeTagFixtureMP3ID3v24:
        case VibeTagFixtureMP3ID3v1: case VibeTagFixtureMP3APE:
            if (![VibeMP3WithInfoFrame(38, NO) writeToURL:url atomically:YES]) return nil;
            break;
        case VibeTagFixtureM4A:
            if (!VibeTagFixtureEncode(url, kAudioFormatMPEG4AAC)) return nil;
            break;
        case VibeTagFixtureFLAC: case VibeTagFixtureFLACCueSheet:
            if (!VibeTagFixtureEncode(url, kAudioFormatFLAC)) return nil;
            break;
        case VibeTagFixtureVorbis: case VibeTagFixtureOpus: {
            NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_AUDIO_FIXTURES"];
            NSString *source = [root stringByAppendingPathComponent:
                    fixture == VibeTagFixtureVorbis ? @"lossy.ogg" : @"lossy.opus"];
            if (!root || ![NSFileManager.defaultManager copyItemAtPath:source toPath:url.path error:NULL]) {
                return nil;
            }
            break;
        }
        case VibeTagFixtureWAVID3: case VibeTagFixtureWAVInfo: case VibeTagFixtureAIFF:
        case VibeTagFixtureCAF: case VibeTagFixtureW64:
            if (!VibeWriteFixture(url, VibeTagFixtureTone(), &error)) return nil;
            break;
        case VibeTagFixtureCount:
            return nil;
    }
    if (fixture == VibeTagFixtureFLACCueSheet) {
        NSData *sheet = VibeFLACCueSheetBlock(@[@[@1, @0, @0, @NO], @[@2, @(11025), @0, @NO]], 22050);
        if (!VibeInsertFLACBlock(url, 5, sheet)) return nil;
    }
    if (untagged) {
        NSURL *copy = [dir URLByAppendingPathComponent:[@"untagged-" stringByAppendingString:name]];
        [NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:NULL];
        *untagged = copy;
    }

    const char *path = url.fileSystemRepresentation;
    BOOL bpmAndKey = VibeTagFixtureHasBPMAndKey(fixture);
    TagLib::PropertyMap properties = VibeTagProperties(bpmAndKey);
    bool saved = true;
    switch (fixture) {
        case VibeTagFixtureMP3ID3v23: case VibeTagFixtureMP3ID3v24: {
            TagLib::MPEG::File file(path);
            file.ID3v2Tag(true)->setProperties(properties);
            VibeAddAPIC(file.ID3v2Tag(), art);
            saved = file.save(TagLib::MPEG::File::ID3v2, TagLib::File::StripOthers,
                              fixture == VibeTagFixtureMP3ID3v23 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4,
                              TagLib::File::DoNotDuplicate);
            break;
        }
        case VibeTagFixtureMP3ID3v1: {
            TagLib::MPEG::File file(path);
            file.ID3v1Tag(true)->setProperties(properties);
            saved = file.save(TagLib::MPEG::File::ID3v1, TagLib::File::StripOthers,
                              TagLib::ID3v2::v4, TagLib::File::DoNotDuplicate);
            break;
        }
        case VibeTagFixtureMP3APE: {
            // Written by hand: the vendored TagLib has no APE writer for MPEG.
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
            [handle seekToEndReturningOffset:NULL error:NULL];
            saved = [handle writeData:VibeAPETag(@[@[@"Title", kVibeTagTitle], @[@"Artist", kVibeTagArtist],
                                                   @[@"BPM", [NSString stringWithFormat:@"%g", kVibeTagBPM]],
                                                   @[@"INITIALKEY", kVibeTagKey]])
                                error:NULL] && [handle closeAndReturnError:NULL];
            break;
        }
        case VibeTagFixtureM4A: {
            TagLib::MP4::File file(path);
            file.setProperties(properties);
            // No property maps a key in MP4: iTunes' freeform atom carries it.
            file.tag()->setItem("----:com.apple.iTunes:initialkey",
                                TagLib::MP4::Item(TagLib::StringList(VibeTagString(kVibeTagKey))));
            TagLib::MP4::CoverArtList covers;
            covers.append(TagLib::MP4::CoverArt(TagLib::MP4::CoverArt::PNG, VibeTagBytes(art)));
            file.tag()->setItem("covr", TagLib::MP4::Item(covers));
            saved = file.save();
            break;
        }
        case VibeTagFixtureFLAC: case VibeTagFixtureFLACCueSheet: {
            TagLib::FLAC::File file(path);
            file.setProperties(properties);
            file.addPicture(VibeFLACPicture(art));
            saved = file.save();
            break;
        }
        case VibeTagFixtureVorbis: {
            TagLib::Ogg::Vorbis::File file(path);
            file.setProperties(properties);
            file.tag()->addPicture(VibeFLACPicture(art));
            saved = file.save();
            break;
        }
        case VibeTagFixtureOpus: {
            TagLib::Ogg::Opus::File file(path);
            file.setProperties(properties);
            file.tag()->addPicture(VibeFLACPicture(art));
            saved = file.save();
            break;
        }
        case VibeTagFixtureWAVID3: {
            TagLib::RIFF::WAV::File file(path);
            file.ID3v2Tag()->setProperties(properties);
            VibeAddAPIC(file.ID3v2Tag(), art);
            saved = file.save(TagLib::RIFF::WAV::File::ID3v2);
            break;
        }
        case VibeTagFixtureWAVInfo: {
            TagLib::RIFF::WAV::File file(path);
            file.InfoTag()->setProperties(properties);
            saved = file.save(TagLib::RIFF::WAV::File::Info);
            break;
        }
        case VibeTagFixtureAIFF: {
            TagLib::RIFF::AIFF::File file(path);
            file.tag()->setProperties(properties);
            VibeAddAPIC(file.tag(), art);
            saved = file.save();
            break;
        }
        case VibeTagFixtureCAF: {
            // CoreAudio's own info chunk: TagLib has no CAF writer.
            AudioFileID file = NULL;
            if (AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadWritePermission, kAudioFileCAFType,
                                 &file) != noErr) {
                return nil;
            }
            CFDictionaryRef info = (__bridge CFDictionaryRef)@{@kAFInfoDictionary_Title: kVibeTagTitle,
                                                               @kAFInfoDictionary_Artist: kVibeTagArtist};
            saved = AudioFileSetProperty(file, kAudioFilePropertyInfoDictionary, sizeof info, &info) == noErr;
            AudioFileClose(file);
            break;
        }
        case VibeTagFixtureW64: case VibeTagFixtureCount:
            break;
    }
    return saved ? url : nil;
}
