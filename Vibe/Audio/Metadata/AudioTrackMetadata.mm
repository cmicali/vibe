//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "NSString+CPPStrings.h"

#include <fileref.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <mp4file.h>
#include <flacfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <aifffile.h>
#include <wavfile.h>

@implementation AudioTrackMetadata {
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeObject:self.albumArt forKey:@"albumArt"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.title = [coder decodeObjectForKey:@"title"];
        self.artist = [coder decodeObjectForKey:@"artist"];
        self.albumArt = [coder decodeObjectForKey:@"albumArt"];
    }
    return self;
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

    auto fileRef = std::unique_ptr<TagLib::FileRef>();
    fileRef.reset(new TagLib::FileRef(filename, true));

    self.title = [url.path.lastPathComponent stringByDeletingPathExtension];
    self.title = [self.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!fileRef->isNull()) {
        if (fileRef->tag()) {

            TagLib::Tag *tag = fileRef->tag();
            TagLib::File *file = fileRef->file();

            self.artist = [NSString stringWithstring:tag->artist().to8Bit(true)];
            self.artist = [self.artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            self.title = [NSString stringWithstring:tag->title().to8Bit(true)];
            self.title = [self.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            self.duration = static_cast<NSTimeInterval>(file->audioProperties()->lengthInMilliseconds()) / 1000;

            if (auto mp3 = dynamic_cast<TagLib::MPEG::File*>(file)) {
                self.albumArt = [self getAlbumArtMP3:mp3];
            }
            else if (auto flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
                self.albumArt = [self getAlbumArtFLAC:flac];
            }
            else if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
                self.albumArt = [self getAlbumArtMP4:mp4];
            }
            else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
                self.albumArt = [self getAlbumArtAIFF:aiff];
            }
            else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
                self.albumArt = [self getAlbumArtWAV:wav];
            }
        }
    }

}

- (NSImage *)getAlbumArtMP4:(TagLib::MP4::File *)mp4File {
    if (!mp4File->tag()->isEmpty()) {
        auto tag = mp4File->tag();
        if (tag->contains("covr")) {
            auto item = tag->item("covr");
            auto list = item.toCoverArtList();
            if (!list.isEmpty()) {
                auto bytes = list.front().data();
                NSData *data = [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
                return [[NSImage alloc] initWithData:data];
            }
        }
    }
    return nil;
}

- (NSImage *)getAlbumArtFLAC:(TagLib::FLAC::File *)flacFile {
    const TagLib::List<TagLib::FLAC::Picture*>& picList = flacFile->pictureList();
    if (!picList.isEmpty()) {
        TagLib::FLAC::Picture* pic = picList[0];
        auto bytes = pic->data();
        NSData *data = [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
        return [[NSImage alloc] initWithData:data];
    }
    return nil;
}

- (NSImage *)getAlbumArtMP3:(TagLib::MPEG::File *)mp3File {
    if (mp3File->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:mp3File->ID3v2Tag(false)];
    }
    return nil;
}

- (NSImage *)getAlbumArtAIFF:(TagLib::RIFF::AIFF::File *)aiffFile {
    if (aiffFile->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:aiffFile->tag()];
    }
    return nil;
}

- (NSImage *)getAlbumArtWAV:(TagLib::RIFF::WAV::File *)wavFile {
    if (wavFile->hasID3v2Tag()) {
        return [self getAlbumArtID3v2:wavFile->tag()];
    }
    return nil;
}

- (NSImage *)getAlbumArtID3v2:(TagLib::ID3v2::Tag *)id3v2Tag {
    TagLib::ID3v2::FrameList frameList = id3v2Tag->frameList("APIC");
    if (!frameList.isEmpty()) {
        TagLib::ID3v2::AttachedPictureFrame *frame = (TagLib::ID3v2::AttachedPictureFrame *) frameList.front();
        auto bytes = frame->picture();
        NSData *data = [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
        return [[NSImage alloc] initWithData:data];
    }
    return nil;
}

@end