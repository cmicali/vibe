//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "NSString+CPPStrings.h"
#import "NSImage+Util.h"

// Pixel size for the playlist-cell thumbnail. Generous for Retina at typical
// row heights; original art is usually 1000×1000+, so this is ~50× smaller.
static const CGFloat kThumbnailDimension = 128.0;

#include <fileref.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <mp4file.h>
#include <flacfile.h>
#include <oggfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <aifffile.h>
#include <wavfile.h>

@implementation AudioTrackMetadata {
    NSImage *_thumbnailAlbumArt;
    NSImage *_albumArt;
    NSData *_albumArtData;
    NSString *_sourceFilePath;
}

// Full-res art is decoded lazily so only tracks whose art is actually
// displayed pay the decode/memory cost. Cache-hit instances don't carry the
// art bytes at all (they're not archived — see encodeWithCoder:) and
// re-extract them from the audio file on demand; only the currently playing
// track ever takes that path.
- (NSImage *)albumArt {
    @synchronized (self) {
        if (!_albumArt) {
            if (!_albumArtData && _sourceFilePath) {
                _albumArtData = [self extractAlbumArtDataFromSourceFile];
            }
            if (_albumArtData) {
                _albumArt = [[NSImage alloc] initWithData:_albumArtData];
            }
        }
        return _albumArt;
    }
}

- (void)setAlbumArt:(NSImage *)albumArt {
    @synchronized (self) {
        _albumArt = albumArt;
    }
}

- (NSImage *)thumbnailAlbumArt {
    @synchronized (self) {
        if (_thumbnailAlbumArt) return _thumbnailAlbumArt;
        NSImage *full = _albumArt;
        if (!full && _albumArtData) {
            // Transient decode for the resize; don't pin the full-res image.
            full = [[NSImage alloc] initWithData:_albumArtData];
        }
        if (!full) return nil;
        NSSize originalSize = full.size;
        if (originalSize.width <= kThumbnailDimension && originalSize.height <= kThumbnailDimension) {
            // Already small — skip the resize.
            _thumbnailAlbumArt = full;
        } else {
            CGFloat scale = MIN(kThumbnailDimension / originalSize.width,
                                kThumbnailDimension / originalSize.height);
            NSSize target = NSMakeSize(MAX(1.0, round(originalSize.width * scale)),
                                       MAX(1.0, round(originalSize.height * scale)));
            _thumbnailAlbumArt = [full resizedImage:target];
        }
        return _thumbnailAlbumArt;
    }
}

// Archive stays small (~5-20KB/track) so the disk cache holds thousands of
// tracks: only the thumbnail as compressed JPEG plus scalar fields. Art bytes
// are deliberately NOT archived — at original sizes they blow the cache's
// byte limit and every launch becomes a full TagLib re-parse of the library.
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeObject:[self thumbnailJPEGData] forKey:@"thumbnailJPEG"];
    [coder encodeObject:_sourceFilePath forKey:@"sourceFilePath"];
    [coder encodeObject:self.fileType forKey:@"fileType"];
    [coder encodeObject:self.bitrate forKey:@"bitrate"];
    [coder encodeObject:self.sampleRate forKey:@"sampleRate"];
    [coder encodeDouble:self.duration forKey:@"duration"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.title = [coder decodeObjectForKey:@"title"];
        self.artist = [coder decodeObjectForKey:@"artist"];
        NSData *thumbnailJPEG = [coder decodeObjectForKey:@"thumbnailJPEG"];
        if (thumbnailJPEG) {
            _thumbnailAlbumArt = [[NSImage alloc] initWithData:thumbnailJPEG];
        }
        _sourceFilePath = [coder decodeObjectForKey:@"sourceFilePath"];
        self.fileType = [coder decodeObjectForKey:@"fileType"];
        self.bitrate = [coder decodeObjectForKey:@"bitrate"];
        self.sampleRate = [coder decodeObjectForKey:@"sampleRate"];
        self.duration = [coder decodeDoubleForKey:@"duration"];
    }
    return self;
}

- (NSData *)thumbnailJPEGData {
    NSImage *thumbnail = self.thumbnailAlbumArt;
    if (!thumbnail) {
        return nil;
    }
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:thumbnail.TIFFRepresentation];
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                             properties:@{NSImageCompressionFactor: @0.85}];
}

- (instancetype)init {
    self = [super init];
    return self;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        [self loadFromURL:url];
    }
    return self;
}

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url {
    return [[AudioTrackMetadata alloc] initWithURL:url];
}

- (void)loadFromURL:(NSURL*)url {

    const char *filename = [url.path UTF8String];

    TagLib::FileRef fileRef(filename);

    _sourceFilePath = url.path;
    self.title = [url.path.lastPathComponent stringByDeletingPathExtension];
    self.title = [self.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!fileRef.isNull()) {
        if (fileRef.tag()) {

            TagLib::Tag *tag = fileRef.tag();

            self.fileType = @"";

            NSString *tagArtist = [[NSString stringWithstring:tag->artist().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *tagTitle = [[NSString stringWithstring:tag->title().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (tagArtist.length > 0) self.artist = tagArtist;
            if (tagTitle.length > 0) self.title = tagTitle;

            TagLib::File *file = fileRef.file();

            auto props = file->audioProperties();

            if (props) {
                self.duration = static_cast<NSTimeInterval>(props->lengthInMilliseconds()) / 1000;
                self.bitrate = @(props->bitrate());
                self.sampleRate = @(props->sampleRate());
            }

            _albumArtData = [self readFileTypeAndAlbumArtFromTagLibFile:file];
        }
    }
}

// Sets fileType as a side effect of the format dispatch; returns the raw
// compressed art bytes (nil when the file has none).
- (NSData *)readFileTypeAndAlbumArtFromTagLibFile:(TagLib::File *)file {
    if (auto mp3 = dynamic_cast<TagLib::MPEG::File*>(file)) {
        self.fileType = FILETYPE_MP3;
        return [self getAlbumArtMP3:mp3];
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
        self.fileType = FILETYPE_FLAC;
        return [self getAlbumArtFLAC:flac];
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        self.fileType = FILETYPE_MP4;
        return [self getAlbumArtMP4:mp4];
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        self.fileType = FILETYPE_AIFF;
        return [self getAlbumArtAIFF:aiff];
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        self.fileType = FILETYPE_WAV;
        return [self getAlbumArtWAV:wav];
    }
    else if (auto ogg = dynamic_cast<TagLib::Ogg::File*>(file)) {
        self.fileType = FILETYPE_OGG;
        return [self getAlbumArtOgg:ogg];
    }
    return nil;
}

- (NSData *)extractAlbumArtDataFromSourceFile {
    if (!_sourceFilePath) {
        return nil;
    }
    TagLib::FileRef fileRef([_sourceFilePath UTF8String]);
    if (fileRef.isNull() || !fileRef.file()) {
        return nil;
    }
    return [self readFileTypeAndAlbumArtFromTagLibFile:fileRef.file()];
}

- (bool)isLossless {
    if ([FILETYPE_MP3 isEqualToString:self.fileType]) return NO;
    if ([FILETYPE_FLAC isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_MP4 isEqualToString:self.fileType]) return NO;
    if ([FILETYPE_AIFF isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_WAV isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_OGG isEqualToString:self.fileType]) return NO;
    return NO;
}

- (NSData *)getAlbumArtMP4:(TagLib::MP4::File *)mp4File {
    if (!mp4File->tag()->isEmpty()) {
        auto tag = mp4File->tag();
        if (tag->contains("covr")) {
            auto item = tag->item("covr");
            auto list = item.toCoverArtList();
            if (!list.isEmpty()) {
                auto bytes = list.front().data();
                return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
            }
        }
    }
    return nil;
}

- (NSData *)getAlbumArtFLAC:(TagLib::FLAC::File *)flacFile {
    const TagLib::List<TagLib::FLAC::Picture*>& picList = flacFile->pictureList();
    if (!picList.isEmpty()) {
        TagLib::FLAC::Picture* pic = picList[0];
        auto bytes = pic->data();
        return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
    }
    return nil;
}

- (NSData *)getAlbumArtMP3:(TagLib::MPEG::File *)mp3File {
    if (mp3File->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:mp3File->ID3v2Tag(false)];
    }
    return nil;
}

- (NSData *)getAlbumArtAIFF:(TagLib::RIFF::AIFF::File *)aiffFile {
    if (aiffFile->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:aiffFile->tag()];
    }
    return nil;
}

- (NSData *)getAlbumArtWAV:(TagLib::RIFF::WAV::File *)wavFile {
    if (wavFile->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:wavFile->ID3v2Tag()];
    }
    return nil;
}

- (NSData *)getAlbumArtID3v2:(TagLib::ID3v2::Tag *)id3v2Tag {
    // TagLib hands back UnknownFrame for frames it couldn't parse (e.g.
    // compressed/corrupt APIC), so take the first frame that actually casts.
    const TagLib::ID3v2::FrameList &frameList = id3v2Tag->frameList("APIC");
    for (auto it = frameList.begin(); it != frameList.end(); ++it) {
        auto frame = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(*it);
        if (!frame) continue;
        auto bytes = frame->picture();
        if (bytes.isEmpty()) continue;
        return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
    }
    return nil;
}

- (NSData *)getAlbumArtOgg:(TagLib::Ogg::File *)oggFile {
//    if (aiffFile->hasID3v2Tag()) {
//        return [self getAlbumArtID3v2:aiffFile->tag()];
//    }
    return nil;
}

@end
