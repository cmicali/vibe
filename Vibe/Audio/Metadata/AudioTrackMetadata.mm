//
//  AudioTrackMetadata.mm
//  Vibe
//

#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioFileHandle.h"
#import "AudioTrack.h"
#import "AudioTrackArtwork.h"
#import "TagLibAudioFile.h"
#import "PlatformImage.h"
#import "NSString+CPPStrings.h"
#import "MusicalKey.h"
#import "Formatters.h"
#import "VibeStrings.h"

#import <AudioToolbox/AudioToolbox.h>

#include <exception>
#include <audioproperties.h>
#include <tpropertymap.h>
#include <flacfile.h>

NSNotificationName const AudioTrackMetadataThumbnailDidLoadNotification =
        @"AudioTrackMetadataThumbnailDidLoadNotification";

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

// A tag's text without surrounding whitespace, or nil when that leaves none.
static NSString * _Nullable trimmedTagText(id _Nullable value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
}

@implementation AudioTrackMetadata

#if !defined(NDEBUG)

// Install the listener before this class starts its first metadata parse.
+ (void)initialize {
    if (self != AudioTrackMetadata.class) {
        return; // +initialize runs for subclasses too
    }
    VibeInstallTagLibDebugListener();
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
    NSData *encoded = VibeEncodedImageData(thumbnail);
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
    return scaled ? VibeEncodedImageData(scaled) : nil;
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
    // Encoding must not populate the display cache during a playlist scan.
    NSData *encodedThumbnail = [metadata encodeThumbnailDataIfNeeded];
    if (!encodedThumbnail && metadata.artwork.hasEmbeddedArt) {
        // The fresh row keeps its originals. Cache hits use the rendition.
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
            [self loadCoreAudioFactsFromURL:url];
            return;
        }

        TagLib::File *file = fileRef.file();

        // A valid file without tags still supplies audio properties.
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
            AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url interleaved:NO
                                                                   interrupted:VibeNeverWaitsForAStream error:NULL];
            if (handle.length > 0) {
                self.duration = handle.length / handle.processingFormat.sampleRate;
            }
        }

        // Built once: properties() converts every frame of every tag. It
        // normalizes each format's tempo tag to "BPM", and its keys are
        // case-insensitive.
        const TagLib::PropertyMap properties = file->properties();
        TagLib::StringList bpmValues = properties.value("BPM");
        if (!bpmValues.isEmpty()) {
            float tagBPM = [NSString stringWithStdString:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        // ID3 TKEY and Vorbis/FLAC INITIALKEY arrive as "INITIALKEY"; MP4 has
        // no mapping, so its iTunes freeform atom arrives as "initialkey",
        // which the same lookup finds. An unparseable value stays None, so
        // analysis fills in.
        TagLib::StringList keyValues = properties.value("INITIALKEY");
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

// CoreAudio's facts for a file TagLib cannot read (Audio/Metadata/AGENTS.md).
- (void)loadCoreAudioFactsFromURL:(NSURL *)url {
    // The parser open playback makes for a file its own decoders refuse.
    // TRAP: the handle closes the parser when released, which ARC may do
    // right after its last message unless its lifetime is pinned to the scope.
    NS_VALID_UNTIL_END_OF_SCOPE AudioFileHandle *handle = [[AudioFileHandle alloc] initParserForReading:url
                                                                                            interrupted:VibeNeverWaitsForAStream error:NULL];
    AudioFileID file = handle.parser;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    if (!file || AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) != noErr || format.mSampleRate <= 0) {
        return;
    }
    AudioFileTypeID container = 0;
    size = sizeof(container);
    AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &container);
    Float64 duration = 0;
    size = sizeof(duration);
    if (AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration) == noErr
            && isfinite(duration) && duration > 0) {
        self.duration = duration;
    }
    UInt32 bitsPerSecond = 0;
    size = sizeof(bitsPerSecond);
    if (AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitsPerSecond) == noErr && bitsPerSecond >= 1000) {
        self.bitrate = @(bitsPerSecond / 1000); // TagLib's unit
    }
    self.sampleRate = @((int)format.mSampleRate);
    CFDictionaryRef infoDictionary = NULL;
    size = sizeof(infoDictionary);
    if (handle.infoDictionaryReadable
            && AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &infoDictionary) == noErr
            && infoDictionary) {
        NSDictionary *tags = CFBridgingRelease(infoDictionary);
        NSString *artist = trimmedTagText(tags[@kAFInfoDictionary_Artist]);
        NSString *title = trimmedTagText(tags[@kAFInfoDictionary_Title]);
        if (artist) self.artist = artist;
        if (title) self.title = title;
    }
    // PCM is never WAV or AIFF, which would offer Convert to FLAC a container
    // its tag copy cannot open.
    if (format.mFormatID != kAudioFormatLinearPCM) self.fileType = VibeAudioFileFormatForCodec(format.mFormatID);
    else if (container == kAudioFileWave64Type) self.fileType = VibeAudioFileFormatW64;
    else if (container == kAudioFileCAFType) self.fileType = VibeAudioFileFormatCAF;
    [self.artwork adoptParsedArtData:nil];
    self.parsedOK = YES;
}

- (bool)isLossless {
    if ([VibeAudioFileFormatFLAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatALAC isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatAIFF isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatWAV isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatW64 isEqualToString:self.fileType]) return YES;
    if ([VibeAudioFileFormatCAF isEqualToString:self.fileType]) return YES;
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

@end
