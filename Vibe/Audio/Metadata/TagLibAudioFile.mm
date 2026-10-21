//
//  TagLibAudioFile.mm
//  Vibe
//

#import "TagLibAudioFile.h"

#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <tfilestream.h>
#include <mpegfile.h>
#include <mpegproperties.h>
#include <mp4file.h>
#include <mp4properties.h>
#include <flacfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <aifffile.h>
#include <wavfile.h>
#include <vorbisfile.h>
#include <opusfile.h>
#include <tdebuglistener.h>
#include <tagutils.h>

namespace {

#if !defined(NDEBUG)

// TagLib's listener writes to std::cerr unsynchronized, so two workers race
// on the stream (TSan). App-side so a re-copy of TagLib cannot drop it.
// Release never gets here: NDEBUG makes TagLib::debug() a no-op.
class VibeTagLibDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &message) override {
        NSString *text = @(message.toCString(true));
        LogWarn(@"%@", [text stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
};

#endif

// A file read through the caller's byte-range reader. The parse fetches the
// blocks TagLib reads instead of the whole file. A remote reader's server must
// honor ranges to avoid skipped bytes. Fetched in aligned blocks, one request per run of missing blocks, cached for
// the stream's life. TRAP: a failed fetch THROWS, and loadFromURL:'s barrier
// turns that into a failed parse; returning short would let TagLib build a
// tag from bytes that were never read.
class VibeRangedStream : public TagLib::IOStream {
public:
    VibeRangedStream(NSURL *url, VibeTagByteRangeRead read, TagLib::offset_t length)
        : _url(url), _read(read), _length(length), _name(url.path.UTF8String ?: "") {}

    ~VibeRangedStream() override {
        if (_requests > 0) {
            LogInfo(@"Remote tag read %@: %u requests, %llu KB",
                    _url.lastPathComponent, _requests, _bytesFetched / 1024);
        }
    }

    TagLib::FileName name() const override { return _name.c_str(); }

    TagLib::ByteVector readBlock(size_t length) override {
        if (_position >= _length || length == 0) {
            return TagLib::ByteVector();
        }
        length = (size_t)MIN((TagLib::offset_t)length, _length - _position);
        fetchRange(_position, length);
        TagLib::ByteVector result;
        result.resize((unsigned int)length);
        TagLib::offset_t at = _position;
        size_t filled = 0;
        while (filled < length) {
            TagLib::offset_t block = at / kBlockSize;
            const TagLib::ByteVector &bytes = _blocks.at(block);
            size_t within = (size_t)(at - block * kBlockSize);
            size_t take = MIN(length - filled, (size_t)bytes.size() - within);
            ::memcpy(result.data() + filled, bytes.data() + within, take);
            filled += take;
            at += take;
        }
        _position += length;
        return result;
    }

    void writeBlock(const TagLib::ByteVector &) override {}
    void insert(const TagLib::ByteVector &, TagLib::offset_t, size_t) override {}
    void removeBlock(TagLib::offset_t, size_t) override {}
    bool readOnly() const override { return true; }
    bool isOpen() const override { return true; }

    void seek(TagLib::offset_t offset, Position p) override {
        TagLib::offset_t base = p == Beginning ? 0 : (p == Current ? _position : _length);
        _position = MAX((TagLib::offset_t)0, base + offset);
    }

    TagLib::offset_t tell() const override { return _position; }
    TagLib::offset_t length() override { return _length; }
    void truncate(TagLib::offset_t) override {}

private:
    static constexpr TagLib::offset_t kBlockSize = 64 * 1024;
    // Fetch the first 384 KiB together to avoid another request for nearby art.
    static constexpr TagLib::offset_t kHeadBlocks = 6;

    // One request from the first missing block to the last, so a tag read
    // in one readBlock is one round trip.
    void fetchRange(TagLib::offset_t start, size_t length) {
        TagLib::offset_t first = start / kBlockSize;
        TagLib::offset_t last = (start + (TagLib::offset_t)length - 1) / kBlockSize;
        while (first <= last && _blocks.count(first)) first++;
        while (last >= first && _blocks.count(last)) last--;
        if (first > last) {
            return;
        }
        if (first == 0) {
            last = MAX(last, MIN(kHeadBlocks, (_length + kBlockSize - 1) / kBlockSize) - 1);
        }
        TagLib::offset_t from = first * kBlockSize;
        TagLib::offset_t to = MIN((last + 1) * kBlockSize, _length);
        NSError *error = nil;
        NSData *data = _read(_url, (uint64_t)from, (uint64_t)(to - from), &error);
        _requests++;
        if (!data || (TagLib::offset_t)data.length < to - from) {
            throw std::runtime_error(std::string("remote read failed: ")
                    + (error.localizedDescription.UTF8String ?: "short read"));
        }
        _bytesFetched += data.length;
        for (TagLib::offset_t block = first; block <= last; block++) {
            TagLib::offset_t at = block * kBlockSize - from;
            TagLib::offset_t size = MIN(kBlockSize, to - block * kBlockSize);
            _blocks[block] = TagLib::ByteVector((const char *)data.bytes + at, (unsigned int)size);
        }
    }

    NSURL *_url;
    VibeTagByteRangeRead _read;
    TagLib::offset_t _length;
    std::string _name;
    TagLib::offset_t _position = 0;
    std::map<TagLib::offset_t, TagLib::ByteVector> _blocks;
    unsigned _requests = 0;
    uint64_t _bytesFetched = 0;
};

// The stream a parse reads: the file, or its bytes through the caller's reader.
static std::unique_ptr<TagLib::IOStream> VibeOpenTagStream(const char *path, VibeTagByteRangeRead rangeRead,
                                                           uint64_t rangeLength) {
    if (rangeRead) {
        NSURL *url = [NSURL fileURLWithPath:@(path) isDirectory:NO];
        return std::make_unique<VibeRangedStream>(url, rangeRead, (TagLib::offset_t)rangeLength);
    }
    return std::make_unique<TagLib::FileStream>(path, true);
}

} // namespace

#if !defined(NDEBUG)

// Leaked by design: TagLib keeps the pointer.
void VibeInstallTagLibDebugListener(void) {
    TagLib::setDebugListener(new VibeTagLibDebugListener());
}

#endif

TagLibAudioFile::TagLibAudioFile(const char *path, bool readProperties, VibeTagByteRangeRead rangeRead,
                                 uint64_t rangeLength)
    : _stream(VibeOpenTagStream(path, rangeRead, rangeLength)) {
    if (!_stream->isOpen()) {
        return;
    }
    _file = openByExtension(path, _stream.get(), readProperties);
    if (!_file || !_file->isValid()) {
        // TRAP: the refused parser leaves the stream anywhere, and RIFF reads
        // from tell(). Without the rewind a .m4a WAV parses with no tags.
        _stream->seek(0);
        _file = openByContent(_stream.get(), readProperties);
    }
    if (_file && !_file->isValid()) {
        _file = nullptr;
    }
}

// TRAP: FLAC::File takes a stream with "fLaC" anywhere near its start,
// which FLAC in Ogg carries in its first page. Playback refuses that
// file at the parser open (AudioFileHandle.m), so it must never parse as
// FLAC here: it is a failed parse, as its play is.
bool TagLibAudioFile::isOgg(TagLib::IOStream *stream) {
    return TagLib::Utils::readHeader(stream, 4, false).startsWith("OggS");
}

// FileRef::detectByExtension's mapping plus wave, bwf and qta (a QuickTime
// container MP4::File parses). .ogg and .oga hold Vorbis or Opus, told
// apart by a cheap sniff; FLAC in Ogg has no vendored parser.
std::unique_ptr<TagLib::File> TagLibAudioFile::openByExtension(const char *path, TagLib::IOStream *stream,
                                                              bool readProperties) {
    NSString *ext = [@(path) pathExtension].uppercaseString;
    if ([ext isEqualToString:@"MP3"] || [ext isEqualToString:@"MP2"] || [ext isEqualToString:@"AAC"])
        return std::make_unique<TagLib::MPEG::File>(stream, readProperties);
    if ([ext isEqualToString:@"M4A"] || [ext isEqualToString:@"M4R"] || [ext isEqualToString:@"M4B"] ||
        [ext isEqualToString:@"M4P"] || [ext isEqualToString:@"MP4"] || [ext isEqualToString:@"M4V"] ||
        [ext isEqualToString:@"QTA"])
        return std::make_unique<TagLib::MP4::File>(stream, readProperties);
    if ([ext isEqualToString:@"FLAC"])
        return isOgg(stream) ? nullptr : std::make_unique<TagLib::FLAC::File>(stream, readProperties);
    if ([ext isEqualToString:@"OGG"] || [ext isEqualToString:@"OGA"])
        return TagLib::Ogg::Opus::File::isSupported(stream)
                ? std::unique_ptr<TagLib::File>(std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties))
                : std::make_unique<TagLib::Ogg::Vorbis::File>(stream, readProperties);
    if ([ext isEqualToString:@"OPUS"])
        return std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties);
    if ([ext isEqualToString:@"AIF"] || [ext isEqualToString:@"AIFF"] ||
        [ext isEqualToString:@"AFC"] || [ext isEqualToString:@"AIFC"])
        return std::make_unique<TagLib::RIFF::AIFF::File>(stream, readProperties);
    if ([ext isEqualToString:@"WAV"] || [ext isEqualToString:@"WAVE"] || [ext isEqualToString:@"BWF"])
        return std::make_unique<TagLib::RIFF::WAV::File>(stream, readProperties);
    return nullptr;
}

// FileRef::detectByContent's order. MPEG is last: its sniff takes frame
// sync bytes inside other formats for MP3.
std::unique_ptr<TagLib::File> TagLibAudioFile::openByContent(TagLib::IOStream *stream, bool readProperties) {
    if (TagLib::Ogg::Vorbis::File::isSupported(stream))
        return std::make_unique<TagLib::Ogg::Vorbis::File>(stream, readProperties);
    if (!isOgg(stream) && TagLib::FLAC::File::isSupported(stream))
        return std::make_unique<TagLib::FLAC::File>(stream, readProperties);
    if (TagLib::Ogg::Opus::File::isSupported(stream))
        return std::make_unique<TagLib::Ogg::Opus::File>(stream, readProperties);
    if (TagLib::MP4::File::isSupported(stream))
        return std::make_unique<TagLib::MP4::File>(stream, readProperties);
    if (TagLib::RIFF::AIFF::File::isSupported(stream))
        return std::make_unique<TagLib::RIFF::AIFF::File>(stream, readProperties);
    if (TagLib::RIFF::WAV::File::isSupported(stream))
        return std::make_unique<TagLib::RIFF::WAV::File>(stream, readProperties);
    if (TagLib::MPEG::File::isSupported(stream))
        return std::make_unique<TagLib::MPEG::File>(stream, readProperties);
    return nullptr;
}

VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
        // .mp2 and .aac open as MPEG::File too; the header tells them apart.
        if (auto props = mpeg->audioProperties()) {
            if (props->isADTS()) return VibeAudioFileFormatAAC;
            if (props->layer() == 2) return VibeAudioFileFormatMP2;
        }
        return VibeAudioFileFormatMP3;
    }
    if (dynamic_cast<TagLib::FLAC::File*>(file)) {
        return VibeAudioFileFormatFLAC;
    }
    if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        auto props = mp4->audioProperties();
        if (props && props->codec() == TagLib::MP4::Properties::ALAC) {
            return VibeAudioFileFormatALAC;
        }
        return VibeAudioFileFormatMP4;
    }
    if (dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        return VibeAudioFileFormatAIFF;
    }
    if (dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        return VibeAudioFileFormatWAV;
    }
    if (dynamic_cast<TagLib::Ogg::Vorbis::File*>(file)) {
        return VibeAudioFileFormatVorbis;
    }
    if (dynamic_cast<TagLib::Ogg::Opus::File*>(file)) {
        return VibeAudioFileFormatOpus;
    }
    return nil;
}

static NSData *getAlbumArtMP3(TagLib::MPEG::File *mp3File);
static NSData *getAlbumArtPictures(const TagLib::List<TagLib::FLAC::Picture *> &pictures);
static NSData *getAlbumArtMP4(TagLib::MP4::File *mp4File);
static NSData *getAlbumArtAIFF(TagLib::RIFF::AIFF::File *aiffFile);
static NSData *getAlbumArtWAV(TagLib::RIFF::WAV::File *wavFile);

NSData *albumArtDataFromTagLibFile(TagLib::File *file) {
    if (auto mp3 = dynamic_cast<TagLib::MPEG::File*>(file)) {
        return getAlbumArtMP3(mp3);
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
        return getAlbumArtPictures(flac->pictureList());
    }
    // Vorbis and Opus, both tagged with a Xiph comment.
    else if (auto xiph = dynamic_cast<TagLib::Ogg::XiphComment*>(file->tag())) {
        return getAlbumArtPictures(xiph->pictureList());
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        return getAlbumArtMP4(mp4);
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        return getAlbumArtAIFF(aiff);
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        return getAlbumArtWAV(wav);
    }
    return nil;
}

BOOL VibeTagLibReadEmbeddedArt(NSString *path, VibeTagByteRangeRead rangeRead, uint64_t rangeLength,
                               NSData *__autoreleasing *art) {
    *art = nil;
    // The parse's barrier; a throw is a failed read, not "no art".
    try {
        TagLibAudioFile fileRef(path.UTF8String, false, rangeRead, rangeLength);
        if (fileRef.isNull()) {
            return NO;
        }
        *art = albumArtDataFromTagLibFile(fileRef.file());
        return YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib art extraction failed for %@: %s", path, e.what());
    }
    catch (...) {
        LogError(@"TagLib art extraction failed for %@", path);
    }
    return NO;
}

static NSData *getAlbumArtID3v2(TagLib::ID3v2::Tag *id3v2Tag) {
    // Unparsed frames come back as UnknownFrame, so only those that cast
    // count. FrontCover wins: a 32x32 FileIcon can precede the cover.
    const TagLib::ID3v2::FrameList &frameList = id3v2Tag->frameList("APIC");
    TagLib::ID3v2::AttachedPictureFrame *fallback = nullptr;
    for (auto it = frameList.begin(); it != frameList.end(); ++it) {
        auto frame = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(*it);
        if (!frame || frame->picture().isEmpty()) continue;
        if (frame->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) {
            fallback = frame;
            break;
        }
        if (!fallback) fallback = frame;
    }
    if (!fallback) {
        return nil;
    }
    auto bytes = fallback->picture();
    return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
}

static NSData *getAlbumArtMP4(TagLib::MP4::File *mp4File) {
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

// A FLAC file's picture blocks, or a Vorbis comment's METADATA_BLOCK_PICTURE.
static NSData *getAlbumArtPictures(const TagLib::List<TagLib::FLAC::Picture *> &pictures) {
    // FrontCover wins, as in getAlbumArtID3v2.
    TagLib::FLAC::Picture *chosen = nullptr;
    for (auto it = pictures.begin(); it != pictures.end(); ++it) {
        TagLib::FLAC::Picture *pic = *it;
        if (!pic || pic->data().isEmpty()) continue;
        if (pic->type() == TagLib::FLAC::Picture::FrontCover) {
            chosen = pic;
            break;
        }
        if (!chosen) chosen = pic;
    }
    if (!chosen) {
        return nil;
    }
    auto bytes = chosen->data();
    return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
}

static NSData *getAlbumArtMP3(TagLib::MPEG::File *mp3File) {
    if (mp3File->hasID3v2Tag()) {
        return getAlbumArtID3v2(mp3File->ID3v2Tag(false));
    }
    return nil;
}

static NSData *getAlbumArtAIFF(TagLib::RIFF::AIFF::File *aiffFile) {
    if (aiffFile->hasID3v2Tag()) {
        return getAlbumArtID3v2(aiffFile->tag());
    }
    return nil;
}

static NSData *getAlbumArtWAV(TagLib::RIFF::WAV::File *wavFile) {
    if (wavFile->hasID3v2Tag()) {
        return getAlbumArtID3v2(wavFile->ID3v2Tag());
    }
    return nil;
}
