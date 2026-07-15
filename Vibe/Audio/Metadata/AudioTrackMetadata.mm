//
// Created by Christopher Micali on 12/17/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadata.h"
#import "NSString+CPPStrings.h"
#import "NSImage+Util.h"
#import <ImageIO/ImageIO.h>

// Pixel size for the playlist-cell thumbnail. Generous for Retina at typical
// row heights; original art is usually 1000×1000+, so this is ~50× smaller.
static const CGFloat kThumbnailDimension = 128.0;

// Cap for the "full-res" display image. Nothing renders art larger than the
// ~300px artwork panel / 512px dock icon, and ImageIO decodes straight to
// this size — the original-resolution bitmap (which can be 50MB+ decoded)
// never gets allocated.
static const CGFloat kDisplayArtMaxDimension = 1024.0;

// Decode image data directly at a bounded pixel size via ImageIO. Unlike
// NSImage initWithData: + resize, this never materializes the full-size
// bitmap.
static NSImage *VibeDecodeImageData(NSData *data, CGFloat maxPixelSize) {
    if (!data) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return nil;
    }
    NSDictionary *options = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (id)kCGImageSourceShouldCacheImmediately: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) {
        return nil;
    }
    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
    CGImageRelease(cgImage);
    return image;
}

#include <exception>
#include <memory>
#include <tfilestream.h>
#include <tpropertymap.h>
#include <mpegfile.h>
#include <mpegproperties.h>
#include <mp4file.h>
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

@implementation AudioTrackMetadata {
    NSImage *_thumbnailAlbumArt;
    NSImage *_albumArt;
    NSData *_albumArtData;
    NSString *_sourceFilePath;
    BOOL _albumArtExtractionAttempted;
    // The file carries art bytes ImageIO cannot decode (truncated/corrupt tag
    // frame). Permanent for this file's content, so it is set regardless of
    // _artGeneration and never cleared by the discard paths: without it,
    // albumArtNeedsLoad would stay YES and the UI would re-dispatch the same
    // doomed decode on every updateUI pass for as long as the track is current.
    BOOL _albumArtUndecodable;
    BOOL _parsedOK;
    // Bumped ONLY by discardDecodedAlbumArt (track changed — drop everything).
    // An albumArt load that was in flight when that discard ran must not store
    // its result back — the read/decode happens outside the lock (and can
    // block for minutes on a cloud placeholder), so without this a
    // skip-during-load re-pins the demoted track's art for the playlist's
    // lifetime. discardAlbumArtData deliberately does NOT bump it: it drops
    // the raw bytes to save memory, not the validity of a decode of those
    // same bytes (see the comment there).
    NSUInteger _artGeneration;
}

- (BOOL)parsedOK {
    return _parsedOK;
}

// Full-res art is decoded lazily so only tracks whose art is actually
// displayed pay the decode/memory cost. Cache-hit instances don't carry the
// art bytes at all (they're not archived — see encodeWithCoder:) and
// re-extract them from the audio file on demand; only the currently playing
// track ever takes that path.
- (NSImage *)albumArt {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
        if (_albumArt) {
            return _albumArt;
        }
        if (_albumArtData) {
            dataToDecode = _albumArtData;
            dataWasInMemory = YES;
        }
        // Attempt the file re-read at most once: artless or moved files
        // must not pay a synchronous TagLib parse on every access. Claim the
        // attempt under the lock so concurrent callers don't double-extract.
        else if (!_sourceFilePath || _albumArtExtractionAttempted || _albumArtUndecodable) {
            return nil;
        }
        else {
            _albumArtExtractionAttempted = YES;
            pathToExtract = _sourceFilePath;
        }
    }
    // Both the file I/O and the ImageIO decode happen OUTSIDE the lock: a
    // cloud placeholder can block the read until it downloads, and the
    // full-res decode is a 10-100ms hitch — holding @synchronized through
    // either stalls the main thread's albumArtIfLoaded/thumbnail accessors.
    // Worst case two callers decode concurrently; results are identical and
    // the first store wins.
    if (!dataToDecode && pathToExtract) {
        dataToDecode = [self extractAlbumArtDataFromFile:pathToExtract];
    }
    NSImage *decoded = dataToDecode ? VibeDecodeImageData(dataToDecode, kDisplayArtMaxDimension) : nil;
    @synchronized (self) {
        if (dataToDecode && !decoded) {
            // The bytes exist but can't be decoded — permanent for this file,
            // so mark it (generation-independent) and drop the bytes rather
            // than pinning undecodable data for the playlist's lifetime.
            _albumArtUndecodable = YES;
            _albumArtData = nil;
            return _albumArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard (discardDecodedAlbumArt)
        // ran while the load was in flight; otherwise return the result
        // transiently (the caller re-checks currency anyway) without
        // re-pinning a demoted track's art. discardAlbumArtData racing this
        // decode is fine — it only wants the raw bytes gone, and the decoded
        // image is exactly what the still-current track needs next.
        if (generation == _artGeneration) {
            // Cache the bytes only when they were just read from the file.
            // Bytes snapshotted from _albumArtData that are gone by now were
            // dropped by discardAlbumArtData mid-decode — restoring them
            // would undo its memory release.
            if (dataToDecode && !_albumArtData && !dataWasInMemory) {
                _albumArtData = dataToDecode;
            }
            if (!_albumArt && decoded) {
                _albumArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Not storing, but the file demonstrably has art: re-arm the
            // on-demand re-read (this load claimed the attempt flag on entry,
            // and a discard's early return leaves that claim in place —
            // without this the track could never load art again).
            _albumArtExtractionAttempted = NO;
        }
        return _albumArt ?: decoded;
    }
}

- (void)setAlbumArt:(NSImage *)albumArt {
    @synchronized (self) {
        _albumArt = albumArt;
    }
}

- (NSImage *)albumArtIfLoaded {
    // No decode work here: a full-res ImageIO decode is a 10-100ms hitch and
    // this is called from updateUI on the main thread. Decoding of in-memory
    // bytes happens on the background albumArt path (albumArtNeedsLoad).
    @synchronized (self) {
        return _albumArt;
    }
}

- (BOOL)albumArtNeedsLoad {
    @synchronized (self) {
        if (_albumArt || _albumArtUndecodable) {
            return NO;
        }
        // Either in-memory bytes still need decoding, or the file hasn't been
        // read yet — both are background work worth dispatching.
        return _albumArtData != nil || (!_albumArtExtractionAttempted && _sourceFilePath != nil);
    }
}

// Drop the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the session; afterward
// the instance behaves exactly like a cache hit — the albumArt getter re-reads
// the audio file on demand for the one track shown full-res.
- (void)discardAlbumArtData {
    @synchronized (self) {
        // Deliberately NO _artGeneration bump: this call only wants the raw
        // bytes released, not an in-flight decode of those same bytes thrown
        // away. The loader calls it right after publishing metadata, racing
        // the current track's first full-res decode — invalidating that
        // decode forced a second TagLib file read plus a second 1024px
        // decode. Only discardDecodedAlbumArt (track changed, drop
        // everything) invalidates decodes.
        if (!_albumArtData) {
            // Nothing to drop (an artless track, or already discarded). Do NOT
            // reset _albumArtExtractionAttempted: an artless track has it YES
            // from the parse, and resetting it would make albumArtNeedsLoad
            // re-trigger a full-file TagLib re-parse (a whole-file download for
            // cloud files) just to rediscover there is no art.
            return;
        }
        _albumArtData = nil;
        if (!_albumArt) {
            // Art existed but isn't decoded yet: reset the attempt flag so the
            // on-demand file re-read (albumArtNeedsLoad → albumArt) still fires
            // for the one track shown full-res.
            _albumArtExtractionAttempted = NO;
        }
    }
}

// Called by the UI (main thread) when this track stops being the current one.
- (void)discardDecodedAlbumArt {
    @synchronized (self) {
        // Invalidate before the early return: the demotion race this guards
        // against is precisely "nothing stored yet because the load is still
        // in flight".
        _artGeneration++;
        if (!_albumArt && !_albumArtData) {
            // Artless (or never loaded) — keep the attempted flag so we don't
            // re-parse the file just to rediscover there's no art.
            return;
        }
        _albumArt = nil;
        _albumArtData = nil;
        // Art exists in the file; re-arm the on-demand re-read for the next
        // time this track is shown full-res.
        _albumArtExtractionAttempted = NO;
    }
    self.albumArtLoadDispatched = NO;
}

- (NSImage *)thumbnailAlbumArt {
    NSData *dataToDecode = nil;
    NSImage *imageToScale = nil;
    @synchronized (self) {
        if (_thumbnailAlbumArt) return _thumbnailAlbumArt;
        if (_albumArtData) {
            dataToDecode = _albumArtData;
        }
        else if (_albumArt) {
            // Rare fallback: an injected image with no backing data.
            imageToScale = _albumArt;
        }
        else {
            return nil;
        }
    }
    // Decode/scale OUTSIDE the lock — this monitor is also taken by the main
    // thread's albumArtIfLoaded (every updateUI pass), which must never wait
    // behind a 10-50ms ImageIO decode on a loader worker. Worst case two callers
    // decode concurrently; results are identical and the first store wins.
    NSImage *thumbnail = nil;
    if (dataToDecode) {
        // ImageIO decodes straight to thumbnail size — the full-size
        // bitmap is never allocated.
        thumbnail = VibeDecodeImageData(dataToDecode, kThumbnailDimension);
    }
    else {
        NSSize originalSize = imageToScale.size;
        if (originalSize.width <= kThumbnailDimension && originalSize.height <= kThumbnailDimension) {
            thumbnail = imageToScale;
        } else {
            CGFloat scale = MIN(kThumbnailDimension / originalSize.width,
                                kThumbnailDimension / originalSize.height);
            NSSize target = NSMakeSize(MAX(1.0, round(originalSize.width * scale)),
                                       MAX(1.0, round(originalSize.height * scale)));
            // nil on bitmap/context allocation failure: store nothing (never
            // the full-size image — pinning it defeats the thumbnail's memory
            // point). _albumArt is still set, so the next access retries.
            thumbnail = [imageToScale resizedImage:target];
        }
    }
    @synchronized (self) {
        if (dataToDecode && !thumbnail) {
            // Same undecodable-bytes marking as the full-res path: without it
            // every playlist cell redraw retries this doomed decode.
            _albumArtUndecodable = YES;
            _albumArtData = nil;
        }
        if (!_thumbnailAlbumArt && thumbnail) {
            _thumbnailAlbumArt = thumbnail;
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
        if (thumbnailJPEG) {
            // Bounded decode: a tampered cache entry could carry a huge image;
            // initWithData: would defer a multi-GB decode to first cell draw.
            _thumbnailAlbumArt = VibeDecodeImageData(thumbnailJPEG, kThumbnailDimension);
        }
        // A track with embedded art always produced a thumbnail; a thumbnail-less
        // entry was artless. Mark artless entries as already-attempted so
        // albumArtNeedsLoad doesn't re-read the file for art that isn't there,
        // while art-bearing entries stay NO so the full-res image can be
        // re-read on demand for the track shown full-res.
        _albumArtExtractionAttempted = (thumbnailJPEG == nil);
        _sourceFilePath = sourceFilePath;
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
    // The thumbnail is either CGImage-backed (VibeDecodeImageData) or already
    // carries an NSBitmapImageRep (the resizedImage: fallback) — no need for
    // the TIFFRepresentation round-trip (encode → decode → encode) to reach
    // JPEG.
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

    _sourceFilePath = url.path;
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
            NSString *tagArtist = [[NSString stringWithstring:tag->artist().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *tagTitle = [[NSString stringWithstring:tag->title().to8Bit(true)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
            float tagBPM = [NSString stringWithstring:bpmValues.front().to8Bit(true)].floatValue;
            if (isfinite(tagBPM) && tagBPM > 0 && tagBPM < 1000) {
                self.bpm = tagBPM;
            }
        }

        self.fileType = fileTypeForTagLibFile(file);
        _albumArtData = [self albumArtDataFromTagLibFile:file];
        _albumArtExtractionAttempted = YES;
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

// Raw compressed art bytes (nil when the file has none).
- (NSData *)albumArtDataFromTagLibFile:(TagLib::File *)file {
    if (auto mp3 = dynamic_cast<TagLib::MPEG::File*>(file)) {
        return [self getAlbumArtMP3:mp3];
    }
    else if (auto flac = dynamic_cast<TagLib::FLAC::File*>(file)) {
        return [self getAlbumArtFLAC:flac];
    }
    else if (auto mp4 = dynamic_cast<TagLib::MP4::File*>(file)) {
        return [self getAlbumArtMP4:mp4];
    }
    else if (auto aiff = dynamic_cast<TagLib::RIFF::AIFF::File*>(file)) {
        return [self getAlbumArtAIFF:aiff];
    }
    else if (auto wav = dynamic_cast<TagLib::RIFF::WAV::File*>(file)) {
        return [self getAlbumArtWAV:wav];
    }
    return nil;
}

// Blocking file read — call without holding @synchronized (self).
- (NSData *)extractAlbumArtDataFromFile:(NSString *)path {
    if (!path) {
        return nil;
    }
    // Same barrier as loadFromURL: — this runs on a background art load and a
    // TagLib throw would terminate the process. A throw here just means no
    // art.
    try {
        TagLibAudioFile fileRef([path UTF8String]);
        if (fileRef.isNull()) {
            return nil;
        }
        return [self albumArtDataFromTagLibFile:fileRef.file()];
    }
    catch (const std::exception &e) {
        LogError(@"TagLib art extraction failed for %@: %s", path, e.what());
    }
    catch (...) {
        LogError(@"TagLib art extraction failed for %@", path);
    }
    return nil;
}

- (bool)isLossless {
    if ([FILETYPE_FLAC isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_ALAC isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_AIFF isEqualToString:self.fileType]) return YES;
    if ([FILETYPE_WAV isEqualToString:self.fileType]) return YES;
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

@end
