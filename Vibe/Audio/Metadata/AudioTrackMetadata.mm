//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "NSString+CPPStrings.h"
#import "AudioTrackArtwork.h"
#import "MusicalKey.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
#include <tdebuglistener.h>

namespace {

#if !defined(NDEBUG)

// TagLib's own listener writes each message straight to std::cerr, which libc++
// does not synchronize: two metadata workers hitting files TagLib dislikes at
// once race on the stream's state, which TSan flags as a data race in basic_ios.
// Route the messages into the unified log instead.
//
// App-side rather than a patch to the vendored source, for the same reason
// warmUpSharedFactories below is: a re-copy of TagLib cannot silently drop it.
// Release never gets here — NDEBUG makes TagLib::debug() a no-op macro.
class VibeTagLibDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &message) override {
        NSString *text = [NSString stringWithStdString:message.to8Bit(true)];
        // TagLib terminates its messages with a newline, which os_log keeps.
        LogWarn(@"%@", [text stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
};

#endif

// Replaces TagLib::FileRef so that only the formats the app plays are linked
// in. FileRef's detection references every parser in the library — Ogg, ASF,
// MPC, the tracker formats and the rest — and would keep them all alive in the
// binary. This mirrors FileRef's behavior for our formats: extension dispatch,
// then isValid() as a content check, then magic-byte sniffing when the
// extension lies.
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
    // no synchronization, so concurrent cold M4A parses — four metadata
    // loaders, plus the art extractor's queue — race map assignment against
    // reads, which is a use-after-free. Build all three maps once, before any
    // parse; every access afterwards is const. The fix lives app-side rather
    // than in the vendored TagLib, so that a re-copy cannot silently drop it.
    static void warmUpSharedFactories() {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            auto *factory = TagLib::MP4::ItemFactory::instance();
            factory->itemToProperty("\251nam", TagLib::MP4::Item());
            factory->nameForPropertyKey("TITLE");
        });
    }

    // The extension-to-format mapping, copied from
    // FileRef::detectByExtension.
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

    // The same sniff order FileRef::detectByContent uses for these formats.
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

// Writable inside the class, and atomic like every other field here, since it
// is built on a worker thread and read from main.
@interface AudioTrackMetadata ()
@property (assign) BOOL parsedOK;
// The whole art lifecycle lives in AudioTrackArtwork, and the art API below
// delegates to it one for one. Both initializers create it, so it is never nil
// on a live instance.
//
// It is an atomic property, not the bare ivar it began as, for the same reason
// as every other field: an instance is built on a metadata worker — the
// unarchive in initWithCoder: included — and read on main from the moment it
// is published. The handle is written once and never reassigned, so a bare
// ivar is safe on the hardware, but the publish and the read then share no
// lock the way the other fields do, and ThreadSanitizer reports the pair as a
// race (found by a stress run, main's albumArtIfLoaded against a worker's
// initWithCoder:). AudioTrackArtwork guards its own mutable state.
@property (strong, nullable) AudioTrackArtwork *artwork;
@end

@implementation AudioTrackMetadata

#if !defined(NDEBUG)

// The seam that guarantees the listener is installed before any parse: every
// TagLib file in the app is opened through this class. The listener is a leaked
// global by design — TagLib keeps the pointer for the life of the process.
+ (void)initialize {
    if (self != AudioTrackMetadata.class) {
        return; // +initialize runs for subclasses too
    }
    TagLib::setDebugListener(new VibeTagLibDebugListener());
}

#endif

// The art accessors delegate to AudioTrackArtwork, which owns the lazy
// decode, discard and re-read state machine. AudioTrackMetadata.h documents
// the contracts.
- (NSImage *)albumArt {
    return [self.artwork albumArt];
}

- (NSImage *)albumArtIfLoaded {
    return [self.artwork albumArtIfLoaded];
}

- (BOOL)albumArtNeedsLoad {
    return [self.artwork albumArtNeedsLoad];
}

- (void)discardAlbumArtData {
    [self.artwork discardAlbumArtData];
}

- (void)discardDecodedAlbumArt {
    [self.artwork discardDecodedAlbumArt];
    // A UI-side dispatch flag, main thread only, which stays out of
    // AudioTrackArtwork.
    self.albumArtLoadDispatched = NO;
}

- (NSImage *)thumbnailAlbumArt {
    return [self.artwork thumbnailAlbumArt];
}

- (void)prewarmEmbeddedThumbnailAlbumArt {
    [self.artwork prewarmEmbeddedThumbnailAlbumArt];
}

// The archive stays small, at roughly 5-20KB per track, so that the disk cache
// holds thousands of tracks: it carries only the thumbnail as a compressed
// JPEG, plus the scalar fields. The art bytes are deliberately not archived,
// because at their original sizes they blow the cache's byte limit and turn
// every launch into a full TagLib re-parse of the library.
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeObject:[self thumbnailJPEGData] forKey:@"thumbnailJPEG"];
    [coder encodeObject:self.artwork.sourceFilePath forKey:@"sourceFilePath"];
    [coder encodeObject:self.fileType forKey:@"fileType"];
    [coder encodeObject:self.bitrate forKey:@"bitrate"];
    [coder encodeObject:self.sampleRate forKey:@"sampleRate"];
    [coder encodeDouble:self.duration forKey:@"duration"];
    [coder encodeFloat:self.bpm forKey:@"bpm"];
    // As an object, not encodeInteger: an absent integer decodes as 0, which
    // as a key means C major, whereas an absent object is unambiguously nil.
    [coder encodeObject:@(self.key) forKey:@"key"];
}

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // PINDiskCache unarchives with requiresSecureCoding = NO, so a corrupt
        // or tampered entry can hand back the wrong class. Validate every
        // field and treat any mismatch as a cache miss, returning nil, rather
        // than crashing later on the main thread. A persistent bad entry is
        // never evicted and would otherwise crash on every launch. nil is
        // allowed, since these are all optional fields.
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
        // This decodes the thumbnail at a bounded size and derives the
        // extraction-attempted flag; see adoptArchivedThumbnailJPEG:.
        self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:sourceFilePath
                                                               extractor:VibeTagLibArtExtractor()];
        [self.artwork adoptArchivedThumbnailJPEG:thumbnailJPEG];
        self.fileType = fileType;
        self.bitrate = bitrate;
        self.sampleRate = sampleRate;
        double duration = [coder decodeDoubleForKey:@"duration"];
        // The parse path can only produce non-negative durations, so a
        // negative one is as corrupt as a non-finite one.
        if (!isfinite(duration) || duration < 0) {
            return nil; // corrupt/tampered entry — treat as a cache miss
        }
        self.duration = duration;
        // Absent in entries written before BPM support, where it decodes as 0,
        // meaning untagged. No version bump is needed. Same bounds as the
        // fresh-parse path, so a doctored entry cannot smuggle in an absurd BPM.
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = isfinite(bpm) && bpm > 0 && bpm < 1000 ? bpm : 0;
        id keyValue = [coder decodeObjectForKey:@"key"];
        if (keyValue && ![keyValue isKindOfClass:[NSNumber class]]) return nil;
        NSInteger key = keyValue ? [keyValue integerValue] : -1;
        self.key = (key >= 0 && key < 24) ? key : -1;
        // A cache-hit instance represents a successful prior parse.
        self.parsedOK = YES;
    }
    return self;
}

- (NSData *)thumbnailJPEGData {
    // The file's own art only. Folder art must never be archived; see
    // AudioTrackArtwork.archivableThumbnail.
    NSImage *thumbnail = [self.artwork archivableThumbnail];
    if (!thumbnail) {
        return nil;
    }
    // CGImageForProposedRect returns the backing CGImage directly for
    // CGImage-backed images, and rasterizes anything else.
    CGImageRef cgImage = [thumbnail CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        return nil;
    }
    // JPEG cannot store alpha, so transparent art such as a PNG cover would
    // render composited in the fresh-parse session but flattened in every
    // cache-hit session afterwards. Keep alpha-bearing thumbnails as PNG;
    // everything else stays JPEG, which is far smaller for photographic
    // covers. ImageIO sniffs the bytes on the decode side, so the
    // "thumbnailJPEG" archive key keeps reading both.
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(cgImage);
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                      alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    NSString *type = hasAlpha ? UTTypePNG.identifier : UTTypeJPEG.identifier;
    NSMutableData *encoded = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded,
                                         (__bridge CFStringRef)type, 1, NULL);
    if (!destination) {
        return nil;
    }
    NSDictionary *options = hasAlpha ? @{} : @{(id)kCGImageDestinationLossyCompressionQuality: @0.85};
    CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)options);
    BOOL finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return finalized ? encoded : nil;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        self.key = VibeMusicalKeyNone; // the zero-filled default is C major
        [self loadFromURL:url];
    }
    return self;
}

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url {
    return [[AudioTrackMetadata alloc] initWithURL:url];
}

- (void)loadFromURL:(NSURL*)url {

    self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:url.path
                                                           extractor:VibeTagLibArtExtractor()];
    self.title = [url.path.lastPathComponent stringByDeletingPathExtension];
    self.title = [self.title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // A C++ exception barrier. A corrupt tag declaring a huge frame size can
    // make TagLib throw std::bad_alloc or std::length_error, and this runs on
    // an NSOperationQueue worker, where an uncaught C++ exception means
    // std::terminate. Catch it here, at the outermost ObjC-facing boundary, so
    // that a malformed file degrades to a failed parse — parsedOK stays NO and
    // nothing is cached — rather than unwinding into ObjC frames.
    try {
        TagLibAudioFile fileRef([url.path UTF8String]);
        if (fileRef.isNull()) {
            return;
        }

        TagLib::File *file = fileRef.file();

        // Artist and title are the only tag-derived fields. Everything below —
        // the audio properties, fileType and art — comes from the file itself,
        // so a valid tagless file still parses OK, with the filename-derived
        // title.
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

        // TagLib's PropertyMap normalizes every format's tempo tag — ID3 TBPM,
        // MP4 tmpo, Vorbis and FLAC BPM — to the "BPM" key.
        TagLib::StringList bpmValues = file->properties()["BPM"];
        if (!bpmValues.isEmpty()) {
            float tagBPM = [NSString stringWithStdString:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        // The tagged key. ID3 TKEY normalizes to "INITIALKEY", and Vorbis and
        // FLAC INITIALKEY fields arrive under the same name — but MP4 has no
        // item-factory mapping, so the common `----:com.apple.iTunes:initialkey`
        // freeform atom passes through with its name verbatim; check it
        // second. An unparseable value leaves key at -1 by the parser's own
        // contract, so analysis fills in rather than a bad tag blanking it.
        TagLib::StringList keyValues = file->properties()["INITIALKEY"];
        if (keyValues.isEmpty()) {
            keyValues = file->properties()["initialkey"];
        }
        if (!keyValues.isEmpty()) {
            self.key = VibeMusicalKeyFromString(
                    [NSString stringWithStdString:keyValues.front().to8Bit(true)]);
        }

        self.fileType = fileTypeForTagLibFile(file);
        [self.artwork adoptParsedArtData:albumArtDataFromTagLibFile(file)];
        // TagLib opened and recognized the file, so this is real metadata and
        // safe to persist. A null FileRef, from a dataless cloud placeholder
        // or a transient I/O error, leaves this NO, so the loaders will not
        // cache the filename-only fallback and shadow the real tags for months.
        self.parsedOK = YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib parse failed for %@: %s", url.path, e.what());
    }
    catch (...) {
        LogError(@"TagLib parse failed for %@", url.path);
    }
}

// The codec label for the format dispatch. It is a free function rather than a
// method so that it cannot touch instance state: the on-demand art re-read
// shares the dispatch and must never mutate the displayed fileType.
static NSString *fileTypeForTagLibFile(TagLib::File *file) {
    if (auto mpeg = dynamic_cast<TagLib::MPEG::File*>(file)) {
        // .mp2 and .aac open as MPEG::File too, and the header tells them
        // apart: ADTS is AAC, layer 2 is MP2 and layer 3 is MP3.
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

// The raw compressed art bytes, or nil when the file has none. These are free
// functions, like fileTypeForTagLibFile, and hold no instance state, so the
// extractor block below can use them without capturing a metadata instance.
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

// A blocking file read, invoked by AudioTrackArtwork without its monitor held.
// It captures nothing, being a global block with no lifetime coupling, and
// TagLib stays here so that AudioTrackArtwork compiles as plain ObjC.
static AudioTrackArtworkExtractor VibeTagLibArtExtractor(void) {
    return ^NSData *(NSString *path) {
        if (!path) {
            return nil;
        }
        // The same barrier as loadFromURL:. This runs on a background art
        // load, where a TagLib throw would terminate the process. A throw here
        // simply means no art.
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
    // TagLib hands back UnknownFrame for frames it could not parse, so only
    // frames that actually cast count. Prefer the FrontCover-typed picture: a
    // file can carry a 32x32 FileIcon ahead of the cover, and taking the first
    // blindly puts that icon on the 300px header and the dock.
    const TagLib::ID3v2::FrameList &frameList = id3v2Tag->frameList("APIC");
    TagLib::ID3v2::AttachedPictureFrame *fallback = nullptr;
    for (auto it = frameList.begin(); it != frameList.end(); ++it) {
        auto frame = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(*it);
        if (!frame || frame->picture().isEmpty()) continue;
        if (frame->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) {
            fallback = frame;
            break;
        }
        if (!fallback) fallback = frame; // first valid picture, any type
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

static NSData *getAlbumArtFLAC(TagLib::FLAC::File *flacFile) {
    // The same picture-type preference as getAlbumArtID3v2: the front cover
    // beats whatever picture happens to be stored first.
    const TagLib::List<TagLib::FLAC::Picture*>& picList = flacFile->pictureList();
    TagLib::FLAC::Picture *chosen = nullptr;
    for (auto it = picList.begin(); it != picList.end(); ++it) {
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

@end
