//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "NSString+CPPStrings.h"
#import "AudioTrackArtwork.h"

#include <exception>
#include <memory>
#include <tfilestream.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <mpegproperties.h>
#include <mp4file.h>
#include <mp4itemfactory.h>
#include <mp4properties.h>
#include <flacfile.h>
#include <id3v2tag.h>
#include <attachedpictureframe.h>
#include <aifffile.h>
#include <wavfile.h>

namespace {

// Replaces TagLib::FileRef so only the formats the app plays get linked in —
// FileRef's detection references every parser in the library (Ogg, ASF, MPC,
// tracker formats, ...) and would keep them all alive in the binary. Mirrors
// FileRef's behavior for our formats: extension dispatch, then isValid() as a
// content check, then magic-byte sniffing when the extension lies.
class TagLibAudioFile {
public:
    explicit TagLibAudioFile(const char *path)
        : _stream(std::make_unique<TagLib::FileStream>(path, true)) {
        warmUpSharedFactories();
        if (!_stream->isOpen()) {
            return;
        }
        _file = openByExtension(path, _stream.get());
        if (!_file || !_file->isValid()) {
            _file = openByContent(_stream.get());
        }
        if (_file && !_file->isValid()) {
            _file = nullptr;
        }
    }

    bool isNull() const { return _file == nullptr; }
    TagLib::File *file() const { return _file.get(); }
    TagLib::Tag *tag() const { return _file ? _file->tag() : nullptr; }

private:
    // The MP4::ItemFactory singleton lazily builds its three lookup maps with
    // no synchronization, so concurrent cold M4A parses (metadata loader ×4,
    // plus the art extractor's queue) race map assignment against reads —
    // use-after-free. Build all three maps once, before any parse; every
    // access afterwards is const. App-side rather than patching the vendored
    // TagLib so a re-copy can't silently drop the fix.
    static void warmUpSharedFactories() {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            auto *factory = TagLib::MP4::ItemFactory::instance();
            factory->itemToProperty("\251nam", TagLib::MP4::Item());
            factory->nameForPropertyKey("TITLE");
        });
    }

    // Extension → format mapping copied from FileRef::detectByExtension.
    static std::unique_ptr<TagLib::File> openByExtension(const char *path, TagLib::IOStream *stream) {
        NSString *ext = [@(path) pathExtension].uppercaseString;
        if ([ext isEqualToString:@"MP3"] || [ext isEqualToString:@"MP2"] || [ext isEqualToString:@"AAC"])
            return std::make_unique<TagLib::MPEG::File>(stream);
        if ([ext isEqualToString:@"M4A"] || [ext isEqualToString:@"M4R"] || [ext isEqualToString:@"M4B"] ||
            [ext isEqualToString:@"M4P"] || [ext isEqualToString:@"MP4"] || [ext isEqualToString:@"M4V"])
            return std::make_unique<TagLib::MP4::File>(stream);
        if ([ext isEqualToString:@"FLAC"])
            return std::make_unique<TagLib::FLAC::File>(stream);
        if ([ext isEqualToString:@"AIF"] || [ext isEqualToString:@"AIFF"] ||
            [ext isEqualToString:@"AFC"] || [ext isEqualToString:@"AIFC"])
            return std::make_unique<TagLib::RIFF::AIFF::File>(stream);
        if ([ext isEqualToString:@"WAV"])
            return std::make_unique<TagLib::RIFF::WAV::File>(stream);
        return nullptr;
    }

    // Same sniff order FileRef::detectByContent uses for these formats.
    static std::unique_ptr<TagLib::File> openByContent(TagLib::IOStream *stream) {
        if (TagLib::MPEG::File::isSupported(stream))
            return std::make_unique<TagLib::MPEG::File>(stream);
        if (TagLib::FLAC::File::isSupported(stream))
            return std::make_unique<TagLib::FLAC::File>(stream);
        if (TagLib::MP4::File::isSupported(stream))
            return std::make_unique<TagLib::MP4::File>(stream);
        if (TagLib::RIFF::AIFF::File::isSupported(stream))
            return std::make_unique<TagLib::RIFF::AIFF::File>(stream);
        if (TagLib::RIFF::WAV::File::isSupported(stream))
            return std::make_unique<TagLib::RIFF::WAV::File>(stream);
        return nullptr;
    }

    std::unique_ptr<TagLib::FileStream> _stream; // declared first: must outlive _file
    std::unique_ptr<TagLib::File> _file;
};

} // namespace

static NSString *fileTypeForTagLibFile(TagLib::File *file);
static NSData *albumArtDataFromTagLibFile(TagLib::File *file);
static AudioTrackArtworkExtractor VibeTagLibArtExtractor(void);

@implementation AudioTrackMetadata {
    // The whole art lifecycle lives in AudioTrackArtwork; the art API below
    // delegates to it 1:1. Both initializers create it — never nil on a live
    // instance.
    AudioTrackArtwork *_artwork;
    BOOL _parsedOK;
}

- (BOOL)parsedOK {
    return _parsedOK;
}

// Art accessors delegate to AudioTrackArtwork, which owns the lazy
// decode/discard/re-read state machine; contracts are documented in
// AudioTrackMetadata.h.
- (NSImage *)albumArt {
    return [_artwork albumArt];
}

- (void)setAlbumArt:(NSImage *)albumArt {
    [_artwork setAlbumArt:albumArt];
}

- (NSImage *)albumArtIfLoaded {
    return [_artwork albumArtIfLoaded];
}

- (BOOL)albumArtNeedsLoad {
    return [_artwork albumArtNeedsLoad];
}

- (void)discardAlbumArtData {
    [_artwork discardAlbumArtData];
}

- (void)discardDecodedAlbumArt {
    [_artwork discardDecodedAlbumArt];
    // UI-side dispatch flag, main-thread only — stays out of AudioTrackArtwork.
    self.albumArtLoadDispatched = NO;
}

- (NSImage *)thumbnailAlbumArt {
    return [_artwork thumbnailAlbumArt];
}

// Archive stays small (~5-20KB/track) so the disk cache holds thousands of
// tracks: only the thumbnail as compressed JPEG plus scalar fields. Art bytes
// are deliberately NOT archived — at original sizes they blow the cache's
// byte limit and every launch becomes a full TagLib re-parse of the library.
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeObject:[self thumbnailJPEGData] forKey:@"thumbnailJPEG"];
    [coder encodeObject:_artwork.sourceFilePath forKey:@"sourceFilePath"];
    [coder encodeObject:self.fileType forKey:@"fileType"];
    [coder encodeObject:self.bitrate forKey:@"bitrate"];
    [coder encodeObject:self.sampleRate forKey:@"sampleRate"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeFloat:self.bpm forKey:@"bpm"];
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // PINDiskCache unarchives with requiresSecureCoding = NO, so a corrupt
        // or tampered entry can hand back the wrong class. Validate every field
        // and treat any mismatch as a cache miss (return nil) rather than
        // crashing later on the main thread; a persistent bad entry would
        // otherwise crash on every launch (it's never evicted). nil is allowed —
        // these are all optional fields.
        id title = [coder decodeObjectForKey:@"title"];
        id artist = [coder decodeObjectForKey:@"artist"];
        id thumbnailJPEG = [coder decodeObjectForKey:@"thumbnailJPEG"];
        id sourceFilePath = [coder decodeObjectForKey:@"sourceFilePath"];
        id fileType = [coder decodeObjectForKey:@"fileType"];
        id bitrate = [coder decodeObjectForKey:@"bitrate"];
        id sampleRate = [coder decodeObjectForKey:@"sampleRate"];
        if (title && ![title isKindOfClass:[NSString class]]) return nil;
        if (artist && ![artist isKindOfClass:[NSString class]]) return nil;
        if (thumbnailJPEG && ![thumbnailJPEG isKindOfClass:[NSData class]]) return nil;
        if (sourceFilePath && ![sourceFilePath isKindOfClass:[NSString class]]) return nil;
        if (fileType && ![fileType isKindOfClass:[NSString class]]) return nil;
        if (bitrate && ![bitrate isKindOfClass:[NSNumber class]]) return nil;
        if (sampleRate && ![sampleRate isKindOfClass:[NSNumber class]]) return nil;
        self.title = title;
        self.artist = artist;
        // Decodes the thumbnail at a bounded size and derives the
        // extraction-attempted flag (see adoptArchivedThumbnailJPEG:).
        _artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:sourceFilePath
                                                            extractor:VibeTagLibArtExtractor()];
        [_artwork adoptArchivedThumbnailJPEG:thumbnailJPEG];
        self.fileType = fileType;
        self.bitrate = bitrate;
        self.sampleRate = sampleRate;
        double duration = [coder decodeDoubleForKey:@"duration"];
        if (!isfinite(duration)) {
            return nil; // corrupt/tampered entry — treat as a cache miss
        }
        self.duration = duration;
        // Absent in pre-BPM entries (decodes as 0 = untagged) — no version
        // bump needed.
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = isfinite(bpm) && bpm > 0 ? bpm : 0;
        // A cache-hit instance represents a successful prior parse.
        _parsedOK = YES;
    }
    return self;
}

- (NSData *)thumbnailJPEGData {
    NSImage *thumbnail = self.thumbnailAlbumArt;
    if (!thumbnail) {
        return nil;
    }
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *candidate in thumbnail.representations) {
        if ([candidate isKindOfClass:[NSBitmapImageRep class]]) {
            rep = (NSBitmapImageRep *)candidate;
            break;
        }
    }
    if (!rep) {
        // CGImageForProposedRect returns the backing CGImage directly for
        // CGImage-backed reps (and rasterizes anything else).
        CGImageRef cgImage = [thumbnail CGImageForProposedRect:NULL context:nil hints:nil];
        if (!cgImage) {
            return nil;
        }
        rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    }
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                             properties:@{NSImageCompressionFactor: @0.85}];
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

    _artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:url.path
                                                        extractor:VibeTagLibArtExtractor()];
    self.title = [url.path.lastPathComponent stringByDeletingPathExtension];
    self.title = [self.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // C++ exception barrier: a corrupt tag declaring a huge frame size can
    // make TagLib throw (std::bad_alloc, std::length_error), and this runs on
    // an NSOperationQueue worker where an uncaught C++ exception is
    // std::terminate. Catch here — the outermost ObjC-facing boundary — so a
    // malformed file degrades to a failed parse (_parsedOK stays NO, nothing
    // is cached) instead of unwinding into ObjC frames.
    try {
        TagLibAudioFile fileRef([url.path UTF8String]);
        if (fileRef.isNull()) {
            return;
        }

        TagLib::File *file = fileRef.file();

        // Artist/title are the only tag-derived fields; everything below
        // (audio properties, fileType, art) comes from the file itself, so a
        // valid tagless file still parses OK with the filename-derived title.
        if (TagLib::Tag *tag = fileRef.tag()) {
            NSString *tagArtist = [[NSString stringWithStdString:tag->artist().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *tagTitle = [[NSString stringWithStdString:tag->title().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (tagArtist.length > 0) self.artist = tagArtist;
            if (tagTitle.length > 0) self.title = tagTitle;
        }

        if (auto props = file->audioProperties()) {
            self.duration = static_cast<NSTimeInterval>(props->lengthInMilliseconds()) / 1000;
            self.bitrate = @(props->bitrate());
            self.sampleRate = @(props->sampleRate());
        }

        // TagLib's PropertyMap normalizes every format's tempo tag (ID3
        // TBPM, MP4 tmpo, Vorbis/FLAC BPM) to the "BPM" key.
        TagLib::StringList bpmValues = file->properties()["BPM"];
        if (!bpmValues.isEmpty()) {
            float tagBPM = [NSString stringWithStdString:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        self.fileType = fileTypeForTagLibFile(file);
        [_artwork adoptParsedArtData:albumArtDataFromTagLibFile(file)];
        // TagLib opened and recognized the file — this is real metadata, safe
        // to persist. A null FileRef (dataless cloud placeholder, transient
        // I/O error) leaves this NO so loadOneTrack won't cache the
        // filename-only fallback and shadow the real tags for months.
        _parsedOK = YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib parse failed for %@: %s", url.path, e.what());
    }
    catch (...) {
        LogError(@"TagLib parse failed for %@", url.path);
    }
}

// Codec label for the format dispatch. Free function (not a method) so it
// can't touch instance state: the on-demand art re-read shares the dispatch
// and must never mutate the displayed fileType.
static NSString *fileTypeForTagLibFile(TagLib::File *file) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
        // .mp2/.aac open as MPEG::File too — the header distinguishes them
        // (ADTS is AAC; layer 2 is MP2; layer 3 is MP3).
        if (auto props = mpeg->audioProperties()) {
            if (props->isADTS()) return FILETYPE_AAC;
            if (props->layer() == 2) return FILETYPE_MP2;
        }
        return FILETYPE_MP3;
    }
    if (dynamic_cast<TagLib::FLAC::File*>(file)) {
        return FILETYPE_FLAC;
    }
    if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        auto props = mp4->audioProperties();
        if (props && props->codec() == TagLib::MP4::Properties::ALAC) {
            return FILETYPE_ALAC;
        }
        return FILETYPE_MP4;
    }
    if (dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        return FILETYPE_AIFF;
    }
    if (dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        return FILETYPE_WAV;
    }
    return nil;
}

// Raw compressed art bytes (nil when the file has none). Free functions like
// fileTypeForTagLibFile: no instance state, so the extractor block below can
// use them without capturing a metadata instance.
static NSData *getAlbumArtMP3(TagLib::MPEG::File *mp3File);
static NSData *getAlbumArtFLAC(TagLib::FLAC::File *flacFile);
static NSData *getAlbumArtMP4(TagLib::MP4::File *mp4File);
static NSData *getAlbumArtAIFF(TagLib::RIFF::AIFF::File *aiffFile);
static NSData *getAlbumArtWAV(TagLib::RIFF::WAV::File *wavFile);

static NSData *albumArtDataFromTagLibFile(TagLib::File *file) {
    if (auto mp3 = dynamic_cast<TagLib::MPEG::File*>(file)) {
        return getAlbumArtMP3(mp3);
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
        return getAlbumArtFLAC(flac);
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

// Blocking file read, invoked by AudioTrackArtwork without its monitor held.
// Captures nothing (a global block, no lifetime coupling); TagLib stays here
// so AudioTrackArtwork compiles as plain ObjC.
static AudioTrackArtworkExtractor VibeTagLibArtExtractor(void) {
    return ^NSData *(NSString *path) {
        if (!path) {
            return nil;
        }
        // Same barrier as loadFromURL: — this runs on a background art load
        // and a TagLib throw would terminate the process. A throw here just
        // means no art.
        try {
            TagLibAudioFile fileRef([path UTF8String]);
            if (fileRef.isNull()) {
                return nil;
            }
            return albumArtDataFromTagLibFile(fileRef.file());
        }
        catch (const std::exception &e) {
            LogError(@"TagLib art extraction failed for %@: %s", path, e.what());
        }
        catch (...) {
            LogError(@"TagLib art extraction failed for %@", path);
        }
        return nil;
    };
}

- (bool)isLossless {
    if ([FILETYPE_FLAC isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_ALAC isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_AIFF isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_WAV isEqualToString:self.fileType]) return YES;
    return NO;
}

static NSData *getAlbumArtID3v2(TagLib::ID3v2::Tag *id3v2Tag) {
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

static NSData *getAlbumArtFLAC(TagLib::FLAC::File *flacFile) {
    const TagLib::List<TagLib::FLAC::Picture*>& picList = flacFile->pictureList();
    if (!picList.isEmpty()) {
        TagLib::FLAC::Picture* pic = picList[0];
        auto bytes = pic->data();
        return [[NSData alloc] initWithBytes:bytes.data() length:bytes.size()];
    }
    return nil;
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

@end
