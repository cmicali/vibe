//
//  FLACTagCopier.mm
//  Vibe
//

#import "FLACTagCopier.h"

#include <exception>
#include <memory>
#include <tfilestream.h>
#include <tpropertymap.h>
#include <flacfile.h>
#include <flacpicture.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <aifffile.h>
#include <wavfile.h>

namespace {

// The source is always one of the two uncompressed containers — the only case
// the menu enables — so extension dispatch plus isValid() is enough; no
// content sniffing.
std::unique_ptr<TagLib::File> openUncompressedSource(NSString *path, TagLib::IOStream *stream) {
    NSString *ext = path.pathExtension.uppercaseString;
    std::unique_ptr<TagLib::File> file;
    if ([ext isEqualToString:@"WAV"] || [ext isEqualToString:@"WAVE"] || [ext isEqualToString:@"BWF"]) {
        // All three spellings are plain RIFF WAVE; RIFF::WAV::File reads them.
        file = std::make_unique<TagLib::RIFF::WAV::File>(stream);
    } else if ([ext isEqualToString:@"AIF"] || [ext isEqualToString:@"AIFF"] ||
               [ext isEqualToString:@"AFC"] || [ext isEqualToString:@"AIFC"]) {
        file = std::make_unique<TagLib::RIFF::AIFF::File>(stream);
    }
    if (file && !file->isValid()) {
        return nullptr;
    }
    return file;
}

// The ID3v2 tag both RIFF containers store their metadata in, or null when
// the file carries none.
TagLib::ID3v2::Tag *id3v2TagOf(TagLib::File *file) {
    if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File *>(file)) {
        return wav->hasID3v2Tag() ? wav->ID3v2Tag() : nullptr;
    }
    if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File *>(file)) {
        return aiff->hasID3v2Tag() ? aiff->tag() : nullptr;
    }
    return nullptr;
}

// Front cover preferred, as in AudioTrackMetadata.mm: a file can carry a
// 32x32 FileIcon ahead of the cover, and taking the first picture blindly
// would carry that across instead.
TagLib::ID3v2::AttachedPictureFrame *frontCoverFrame(TagLib::ID3v2::Tag *tag) {
    const TagLib::ID3v2::FrameList &frames = tag->frameList("APIC");
    TagLib::ID3v2::AttachedPictureFrame *chosen = nullptr;
    for (auto it = frames.begin(); it != frames.end(); ++it) {
        auto frame = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(*it);
        if (!frame || frame->picture().isEmpty()) continue;
        if (frame->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) {
            return frame;
        }
        if (!chosen) chosen = frame; // first valid picture, any type
    }
    return chosen;
}

} // namespace

BOOL VibeCopyTagsToFLAC(NSString *sourcePath, NSString *flacPath) {
    // A malformed tag can make TagLib throw, and an uncaught C++ exception on
    // the converter queue is std::terminate; the barrier sits at the
    // ObjC-facing boundary.
    try {
        TagLib::FileStream sourceStream([sourcePath UTF8String], true); // read-only
        if (!sourceStream.isOpen()) {
            LogError(@"Tag copy: cannot open source %@", sourcePath);
            return NO;
        }
        std::unique_ptr<TagLib::File> source = openUncompressedSource(sourcePath, &sourceStream);
        if (!source) {
            LogError(@"Tag copy: TagLib did not recognize source %@", sourcePath);
            return NO;
        }

        TagLib::FileStream flacStream([flacPath UTF8String], false); // read-write
        if (!flacStream.isOpen()) {
            LogError(@"Tag copy: cannot open %@ for writing", flacPath);
            return NO;
        }
        TagLib::FLAC::File flac(&flacStream);
        if (!flac.isValid()) {
            LogError(@"Tag copy: TagLib rejected the encoded FLAC %@", flacPath);
            return NO;
        }

        // PropertyMap normalizes every format's keys — ID3's TBPM becomes
        // Vorbis's BPM — so one assignment carries all the scalars; tags with
        // no Vorbis spelling are dropped.
        flac.setProperties(source->properties());

        if (TagLib::ID3v2::Tag *sourceTag = id3v2TagOf(source.get())) {
            if (TagLib::ID3v2::AttachedPictureFrame *cover = frontCoverFrame(sourceTag)) {
                auto picture = std::make_unique<TagLib::FLAC::Picture>();
                picture->setType(TagLib::FLAC::Picture::FrontCover);
                picture->setMimeType(cover->mimeType());
                picture->setDescription(cover->description());
                picture->setData(cover->picture());
                flac.addPicture(picture.release()); // the file frees it
            }
        }

        if (!flac.save()) {
            LogError(@"Tag copy: TagLib failed to save %@", flacPath);
            return NO;
        }
        return YES;
    }
    catch (const std::exception &e) {
        LogError(@"Tag copy failed for %@: %s", sourcePath, e.what());
    }
    catch (...) {
        LogError(@"Tag copy failed for %@", sourcePath);
    }
    return NO;
}
