//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "Util.h"
#import "NSString+CPPStrings.h"

#include <fileref.h>
#include <tag.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <mp4file.h>
#include <flacfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>

@implementation AudioTrackMetadata {
}

+ (AudioTrackMetadata *)getMetadataForURL:(NSURL *)url {

    auto m = [[AudioTrackMetadata alloc] init];

    const char *filename = [url.path UTF8String];

    auto fileRef = std::unique_ptr<TagLib::FileRef>();
    fileRef.reset(new TagLib::FileRef(filename, true));

    m.title = url.filePathURL.absoluteString.lastPathComponent;

    if (!fileRef->isNull()) {
        if (fileRef->tag()) {

            TagLib::Tag *tag = fileRef->tag();

            m.artist = [NSString stringWithstring:tag->artist().to8Bit(true)];
            m.title = [NSString stringWithstring:tag->title().to8Bit(true)];

            if (instanceof<TagLib::MPEG::File>(fileRef->file())) {
                auto mp3 = (TagLib::MPEG::File *) fileRef->file();
                m.albumArt = [self getAlbumArtMP3:mp3];
            }
            else if (instanceof<TagLib::FLAC::File>(fileRef->file())) {
                auto flac = (TagLib::FLAC::File *)fileRef->file();
                m.albumArt = [self getAlbumArtFLAC:flac];
            }
            else if (instanceof<TagLib::MP4::File>(fileRef->file())) {
                auto mp4 = (TagLib::MP4::File *)fileRef->file();
                m.albumArt = [self getAlbumArtMP4:mp4];
            }
        }
    }

    return m;
}

+ (NSImage *)getAlbumArtMP4:(TagLib::MP4::File *)mp4File {
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

+ (NSImage *)getAlbumArtFLAC:(TagLib::FLAC::File *)flacFile {
    const TagLib::List<TagLib::FLAC::Picture*>& picList = flacFile->pictureList();
    if (!picList.isEmpty()) {
        TagLib::FLAC::Picture* pic = picList[0];
        auto bytes = pic->data();
        NSData *data = [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
        return [[NSImage alloc] initWithData:data];
    }
    return nil;
}

+ (NSImage *)getAlbumArtMP3:(TagLib::MPEG::File *)mp3File {
    if (mp3File->hasID3v2Tag()) {
        TagLib::ID3v2::Tag *m_tag = mp3File->ID3v2Tag(false);
        TagLib::ID3v2::FrameList frameList = m_tag->frameList("APIC");
        if (!frameList.isEmpty()) {
            TagLib::ID3v2::AttachedPictureFrame *frame = (TagLib::ID3v2::AttachedPictureFrame *) frameList.front();
            auto bytes = frame->picture();
            NSData *data = [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
            return [[NSImage alloc] initWithData:data];
        }
    }
    return nil;
}

@end
