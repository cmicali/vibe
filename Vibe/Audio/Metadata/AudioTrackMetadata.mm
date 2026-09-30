//
//  AudioTrackMetadata.mm
//  Vibe
//

#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioFileHandle.h"
#import "AudioTrack.h"
#import "AudioTrackArtworkInternal.h"
#import "PlatformImage.h"
#import "NSString+CPPStrings.h"
#import "MusicalKey.h"
#import "Formatters.h"
#import "VibeStrings.h"

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

NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification =
        @"AudioTrackMetadataThumbnailDidLoadNotification";

namespace {

#if !defined(NDEBUG)

// TagLib's listener writes to std::cerr unsynchronized, so two workers race
// on the stream (TSan). App-side so a re-copy of TagLib cannot drop it.
// Release never gets here: NDEBUG makes TagLib::debug() a no-op.
class VibeTagLibDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &message) override {
        NSString *text = [NSString stringWithStdString:message.to8Bit(true)];
        LogWarn(@"%@", [text stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }
};

#endif

// Replaces TagLib::FileRef, whose detection links every parser in the
// library. Same order: extension, isValid(), then magic bytes.
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
    // MP4::ItemFactory builds its lookup maps lazily and unsynchronized, so
    // concurrent cold M4A parses race (a use-after-free). Build them once
    // before any parse. App-side so a TagLib re-copy cannot drop it.
    static void warmUpSharedFactories() {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            auto *factory = TagLib::MP4::ItemFactory::instance();
            factory->itemToProperty("\251nam", TagLib::MP4::Item());
            factory->nameForPropertyKey("TITLE");
        });
    }

    // FileRef::detectByExtension's mapping plus wave, bwf and qta (a QuickTime
    // container MP4::File parses).
    static std::unique_ptr<TagLib::File> openByExtension(const char *path, TagLib::IOStream *stream) {
        NSString *ext = [@(path) pathExtension].uppercaseString;
        if ([ext isEqualToString:@"MP3"] || [ext isEqualToString:@"MP2"] || [ext isEqualToString:@"AAC"])
            return std::make_unique<TagLib::MPEG::File>(stream);
        if ([ext isEqualToString:@"M4A"] || [ext isEqualToString:@"M4R"] || [ext isEqualToString:@"M4B"] ||
            [ext isEqualToString:@"M4P"] || [ext isEqualToString:@"MP4"] || [ext isEqualToString:@"M4V"] ||
            [ext isEqualToString:@"QTA"])
            return std::make_unique<TagLib::MP4::File>(stream);
        if ([ext isEqualToString:@"FLAC"])
            return std::make_unique<TagLib::FLAC::File>(stream);
        if ([ext isEqualToString:@"AIF"] || [ext isEqualToString:@"AIFF"] ||
            [ext isEqualToString:@"AFC"] || [ext isEqualToString:@"AIFC"])
            return std::make_unique<TagLib::RIFF::AIFF::File>(stream);
        if ([ext isEqualToString:@"WAV"] || [ext isEqualToString:@"WAVE"] || [ext isEqualToString:@"BWF"])
            return std::make_unique<TagLib::RIFF::WAV::File>(stream);
        return nullptr;
    }

    // FileRef::detectByContent's order.
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

static VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file);
static NSData *albumArtDataFromTagLibFile(TagLib::File *file);
static AudioTrackArtworkExtractor VibeTagLibArtExtractor(void);

// Atomic: built on a worker, read on main.
@interface AudioTrackMetadata ()
@property (copy, nullable, readwrite) NSString *title;
@property (copy, nullable, readwrite) NSString *artist;
@property (copy, nullable, readwrite) VibeAudioFileFormat fileType;
@property (copy, nullable, readwrite) NSNumber *bitrate;
@property (copy, nullable, readwrite) NSNumber *sampleRate;
@property (assign, readwrite) NSTimeInterval duration;
@property (assign, readwrite) float bpm;
@property (assign, readwrite) VibeMusicalKey key;
@property (assign) BOOL parsedOK;
// Never nil on a live instance. A property, not a bare ivar: written on a
// worker and read on main, an unlocked pair TSan reports.
@property (strong, nullable) AudioTrackArtwork *artwork;
@end

@implementation AudioTrackMetadata

#if !defined(NDEBUG)

// Every TagLib file is opened through this class, so this precedes any parse.
// Leaked by design: TagLib keeps the pointer.
+ (void)initialize {
    if (self != AudioTrackMetadata.class) {
        return; // +initialize runs for subclasses too
    }
    TagLib::setDebugListener(new VibeTagLibDebugListener());
}

#endif

- (VibeImage *)cachedArt {
    return [self.artwork cachedArt];
}

- (BOOL)artNeedsLoad {
    return [self.artwork artNeedsLoad];
}

- (BOOL)isArtLoadPending {
    return self.artwork.isArtLoadPending;
}

- (void)loadArtIfNeededStillWanted:(BOOL (^)(void))stillWanted
                        completion:(void (^)(VibeImage *_Nullable))completion {
    [self.artwork loadArtIfNeededWithLabel:self.title
                               stillWanted:stillWanted completion:completion];
}

- (void)discardDecodedArt {
    [self.artwork discardDecodedArt];
}

- (VibeImage *)cachedThumbnail {
    VibeImage *thumbnail = [self.artwork cachedThumbnail];
    if (thumbnail) {
        return thumbnail;
    }
    if (![self.artwork embeddedThumbnailDecodeHasSource]) {
        // Nothing to decode; a data transition's redraw re-asks.
        return nil;
    }

    __weak AudioTrackMetadata *weakMetadata = self;
    dispatch_block_t request = ^{
        AudioTrackMetadata *metadata = weakMetadata;
        if (!metadata) {
            return;
        }
        [metadata.artwork requestEmbeddedThumbnailDecodeWithCompletion:^(VibeImage *image) {
            AudioTrackMetadata *completedMetadata = weakMetadata;
            if (image && completedMetadata) {
                [NSNotificationCenter.defaultCenter
                        postNotificationName:AudioTrackMetadataThumbnailDidLoadNotification
                                      object:completedMetadata];
            }
        }];
    };
    if (NSThread.isMainThread) {
        request();
    }
    else {
        dispatch_async(dispatch_get_main_queue(), request);
    }
    return nil;
}

- (instancetype)initForCopy {
    self = [super init];
    if (self) {
        self.key = VibeMusicalKeyNone;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    AudioTrackMetadata *copy = [[[self class] allocWithZone:zone] initForCopy];
    copy.title = self.title;
    copy.artist = self.artist;
    copy.fileType = self.fileType;
    copy.bitrate = self.bitrate;
    copy.sampleRate = self.sampleRate;
    copy.duration = self.duration;
    copy.bpm = self.bpm;
    copy.key = self.key;
    copy.parsedOK = self.parsedOK;
    copy.artwork = [self.artwork copy];
    return copy;
}

// The thumbnail and scalars only, so the cache holds thousands of tracks;
// original art would blow its byte limit. hasEmbeddedArt is its own key: a
// file with art can archive no thumbnail (undecodable, or encode failed).
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.title forKey:@"title"];
    [coder encodeObject:self.artist forKey:@"artist"];
    [coder encodeObject:[self encodeThumbnailDataIfNeeded] forKey:@"thumbnailJPEG"];
    [coder encodeBool:self.artwork.hasEmbeddedArt forKey:@"hasEmbeddedArt"];
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
        // PINDiskCache unarchives without secure coding: any wrong class is a
        // miss, or a persistent bad entry crashes every launch.
        id title = [coder decodeObjectForKey:@"title"];
        id artist = [coder decodeObjectForKey:@"artist"];
        id encodedThumbnail = [coder decodeObjectForKey:@"thumbnailJPEG"];
        id sourceFilePath = [coder decodeObjectForKey:@"sourceFilePath"];
        id fileType = [coder decodeObjectForKey:@"fileType"];
        id bitrate = [coder decodeObjectForKey:@"bitrate"];
        id sampleRate = [coder decodeObjectForKey:@"sampleRate"];
        if (title && ![title isKindOfClass:[NSString class]]) return nil;
        if (artist && ![artist isKindOfClass:[NSString class]]) return nil;
        if (encodedThumbnail && ![encodedThumbnail isKindOfClass:[NSData class]]) return nil;
        if (sourceFilePath && ![sourceFilePath isKindOfClass:[NSString class]]) return nil;
        if (fileType && ![fileType isKindOfClass:[NSString class]]) return nil;
        if (bitrate && ![bitrate isKindOfClass:[NSNumber class]]) return nil;
        if (sampleRate && ![sampleRate isKindOfClass:[NSNumber class]]) return nil;
        self.title = title;
        self.artist = artist;
        self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:sourceFilePath
                                                               extractor:VibeTagLibArtExtractor()];
        // An entry without the key decodes NO; a thumbnail still proves art.
        BOOL hasEmbeddedArt = [coder decodeBoolForKey:@"hasEmbeddedArt"] || encodedThumbnail != nil;
        [self.artwork adoptArchivedThumbnailData:encodedThumbnail hasEmbeddedArt:hasEmbeddedArt];
        self.fileType = fileType;
        self.bitrate = bitrate;
        self.sampleRate = sampleRate;
        double duration = [coder decodeDoubleForKey:@"duration"];
        if (!isfinite(duration) || duration < 0) {
            return nil;
        }
        self.duration = duration;
        // The parse path's bounds; absent decodes as 0, untagged.
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = isfinite(bpm) && bpm > 0 && bpm < 1000 ? bpm : 0;
        id keyValue = [coder decodeObjectForKey:@"key"];
        if (keyValue && ![keyValue isKindOfClass:[NSNumber class]]) return nil;
        NSInteger key = keyValue ? [keyValue integerValue] : -1;
        self.key = (key >= 0 && key < 24) ? key : -1;
        // Only successful parses are cached.
        self.parsedOK = YES;
    }
    return self;
}

// PNG for alpha-bearing art, which JPEG would flatten; JPEG otherwise, far
// smaller for photos. ImageIO sniffs either on decode.
static NSData *VibeEncodedArtData(VibeImage *image) {
#if TARGET_OS_OSX
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
#else
    CGImageRef cgImage = image.CGImage;
#endif
    if (!cgImage) {
        return nil;
    }
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

- (NSData *)encodeThumbnailDataIfNeeded {
    NSData *stored = [self.artwork encodedThumbnailDataForStorage];
    if (stored) {
        return stored;
    }
    // The file's own art only; folder art is never archived.
    VibeImage *thumbnail = [self.artwork decodeThumbnailForArchiving];
    if (!thumbnail) {
        return nil;
    }
    NSData *encoded = VibeEncodedArtData(thumbnail);
    if (!encoded) {
        return nil;
    }
    [self.artwork storeEncodedThumbnailData:encoded];
    return encoded;
}

// Bytes within kVibeArchivedDisplayArtDimension verbatim, larger ones
// downscaled with aspect kept (the square crop is display-time policy). Must
// run while the original bytes exist.
- (nullable NSData *)archivedDisplayArtDataForStorage {
    NSData *original = [self.artwork artDataForArchivedDisplayArt];
    if (!original) {
        return nil;
    }
    CGSize pixels = VibeEncodedImagePixelSize(original);
    CGFloat maxDimension = MAX(pixels.width, pixels.height);
    if (maxDimension <= 0) {
        return nil;
    }
    if (maxDimension <= kVibeArchivedDisplayArtDimension) {
        return original;
    }
    VibeImage *scaled = VibeDecodedImageWithData(original, kVibeArchivedDisplayArtDimension);
    return scaled ? VibeEncodedArtData(scaled) : nil;
}

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        self.key = VibeMusicalKeyNone; // the zero-filled default is C major
        [self loadFromURL:url];
    }
    return self;
}

+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                          displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData {
    AudioTrackMetadata *metadata = [[AudioTrackMetadata alloc] initWithURL:url];
    // Encoded here, off the display cache; the originals are released below.
    NSData *encodedThumbnail = [metadata encodeThumbnailDataIfNeeded];
    if (!encodedThumbnail && metadata.artwork.hasEmbeddedArt) {
        // The row thumbnail must then come from the rendition.
        LogWarn(@"Thumbnail encode produced nothing for art-bearing %@",
                url.path.lastPathComponent);
    }
    // Before the discard. An out-param, never row state: a skipped cache
    // write must not leave the rendition pinned on the row.
    if (displayArtData) {
        *displayArtData = [metadata archivedDisplayArtDataForStorage];
    }
    [metadata.artwork discardArtData];
    return metadata;
}

- (void)loadFromURL:(NSURL*)url {

    self.artwork = [[AudioTrackArtwork alloc] initWithSourceFilePath:url.path
                                                           extractor:VibeTagLibArtExtractor()];
    self.title = [AudioTrack filenameTitleForURL:url];

    // A corrupt tag can make TagLib throw, and uncaught on a worker that is
    // std::terminate. A malformed file degrades to a failed parse instead.
    try {
        TagLibAudioFile fileRef([url.path UTF8String]);
        if (fileRef.isNull()) {
            return;
        }

        TagLib::File *file = fileRef.file();

        // Only artist and title come from the tag: a tagless file parses OK.
        if (TagLib::Tag *tag = fileRef.tag()) {
            NSString *tagArtist = [[NSString stringWithStdString:tag->artist().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *tagTitle = [[NSString stringWithStdString:tag->title().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (tagArtist.length > 0) self.artist = tagArtist;
            if (tagTitle.length > 0) self.title = tagTitle;
        }

        if (auto props = file->audioProperties()) {
            self.duration = static_cast<NSTimeInterval>(props->lengthInMilliseconds()) / 1000;
            // 0 is unknown; the codec line drops nil, not zero.
            if (props->bitrate() > 0) self.bitrate = @(props->bitrate());
            if (props->sampleRate() > 0) self.sampleRate = @(props->sampleRate());
        }
        // TagLib takes a FLAC's length from STREAMINFO alone, which may leave it
        // unknown (0); the handle's dr_flac finds it from the stream's last frames.
        if (self.duration == 0 && dynamic_cast<TagLib::FLAC::File *>(file)) {
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:NULL];
            if (handle.length > 0) {
                self.duration = handle.length / handle.processingFormat.sampleRate;
            }
        }

        // PropertyMap normalizes every format's tempo tag to "BPM".
        TagLib::StringList bpmValues = file->properties()["BPM"];
        if (!bpmValues.isEmpty()) {
            float tagBPM = [NSString stringWithStdString:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        // ID3 TKEY and Vorbis/FLAC INITIALKEY arrive as "INITIALKEY"; MP4 has
        // no mapping, so its iTunes freeform atom arrives as "initialkey". An
        // unparseable value stays None, so analysis fills in.
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
        self.parsedOK = YES;
    }
    catch (const std::exception &e) {
        LogError(@"TagLib parse failed for %@: %s", url.path, e.what());
    }
    catch (...) {
        LogError(@"TagLib parse failed for %@", url.path);
    }
}

static VibeAudioFileFormat _Nullable fileTypeForTagLibFile(TagLib::File *file) {
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
    return nil;
}

// Free functions, so the extractor block captures no metadata instance.
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

// A blocking read, called without the artwork monitor held. TagLib stays here
// so AudioTrackArtwork compiles as plain ObjC.
static AudioTrackArtworkExtractor VibeTagLibArtExtractor(void) {
    return ^VibeEmbeddedArtExtractionResult(NSString *path,
                                             NSData *__autoreleasing *artData) {
        if (!path) {
            return VibeEmbeddedArtExtractionReadFailed;
        }
        // loadFromURL:'s barrier; a throw is a failed read, not "no art".
        try {
            TagLibAudioFile fileRef([path UTF8String]);
            if (fileRef.isNull()) {
                return VibeEmbeddedArtExtractionReadFailed;
            }
            NSData *found = albumArtDataFromTagLibFile(fileRef.file());
            if (!found) {
                return VibeEmbeddedArtExtractionNoArt;
            }
            if (artData) {
                *artData = found;
            }
            return VibeEmbeddedArtExtractionFoundArt;
        }
        catch (const std::exception &e) {
            LogError(@"TagLib art extraction failed for %@: %s", path, e.what());
        }
        catch (...) {
            LogError(@"TagLib art extraction failed for %@", path);
        }
        return VibeEmbeddedArtExtractionReadFailed;
    };
}

- (bool)isLossless {
    if ([VibeAudioFileFormatFLAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatALAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatAIFF isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatWAV isEqualToString:self.fileType]) return YES;
    return NO;
}

- (NSString *)fileInfoLine {
    if (!self.fileType) {
        return @"";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:self.fileType];
    // A lossless bitrate is implied by the rate and depth: noise.
    if (!self.isLossless && self.bitrate != nil) {
        [parts addObject:[NSString stringWithFormat:STR_LABEL_BITRATE,
                [[Formatters sharedInstance] decimalString:self.bitrate.doubleValue
                                            fractionDigits:0]]];
    }
    if (self.sampleRate != nil) {
        [parts addObject:[[Formatters sharedInstance] sampleRateString:self.sampleRate.doubleValue]];
    }
    return [[Formatters sharedInstance] infoLineFromFields:parts];
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

static NSData *getAlbumArtFLAC(TagLib::FLAC::File *flacFile) {
    // FrontCover wins, as in getAlbumArtID3v2.
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
