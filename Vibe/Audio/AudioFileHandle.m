//
//  AudioFileHandle.m
//  Vibe
//

#import "AudioFileHandle.h"
#import "CloudFileMaterializer.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>

#include "dr_flac/dr_flac.h"
#include "dr_mp3/dr_mp3.h"
#include "dr_wav/dr_wav.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

static atomic_bool sAppleMPEGDecoder;

// Packets decoded and dropped before a seek's own, so a seek decodes exactly
// what reading from the start would: the packet before the target, whose
// second granule the target's first overlaps and whose last 480 frames are
// the filterbank's history, and the payload its main_data_begin reaches back
// over, 511 bytes, which is nine packets at MPEG-1's smallest (32 kbps at
// 48 kHz, stereo, with a CRC: 58 bytes each). MPEG-2's frames can be far
// smaller, so seekToFrame: walks back further for those, never less far: on
// a damaged stream it takes that long for the reservoir to fall into step.
static const SInt64 kVibeMPEGSeekPrerollPackets = 10;

// dr_mp3 never clamps, and one damaged frame can decode past +90 dBFS: the
// FX's reverb and delay then ring at full scale for seconds, the equalizer's
// reference stays up for half a minute, and the track's detected tempo moves.
// The bound, +12 dBFS, sits well above any real master's overs
// (docs/audio-quality.md).
static const float kVibeMPEGSampleBound = 4.0f;

// Packets asked of the parser at once, sparing it about four small reads
// per MP3 frame, which were a tenth of the whole decode's time.
enum { kVibeMPEGReadPackets = 16 };

// A stream's packet count until it is settled (VibeUncountedMPEGPackets).
static const SInt64 kVibeMPEGPacketsUncounted = INT64_MAX;

// The head a stream's frames are walked in: what is on disk of its first MB of
// audio, so the open never waits for it. At the 256 KB a stream opens on, 7 to
// 20 s of a 128 to 320 kbps stream, a few hundred frames; the average of every
// one of them, since more is a better guess and the walk costs one read. Fewer
// than kVibeMPEGEstimateFrames whole frames is no guess at all.
enum { kVibeMPEGEstimateBytes = 1024 * 1024, kVibeMPEGEstimateFrames = 16 };

// Small reads go through one block: the parser's under kVibeReadBlock, filling
// all of it — Apple's Ogg reader asks for about 200 bytes at a time on Opus,
// 18,000 reads for three minutes — and dr_flac's 4 KB ones, filling a quarter:
// a seek's bisection probes a few KB at each position it tries, and dr_wav's
// larger reads gain nothing from a copy. Anything bigger is read straight
// through.
enum { kVibeReadBlock = 64 * 1024, kVibeStreamReadSmall = 4096, kVibeStreamReadFill = 16 * 1024 };

// CoreAudio's Ogg reader (.ogg, .oga, .opus). The SDK names no constant.
static const AudioFileTypeID kVibeOggFileType = 'Oggf';

// The status of an interrupted read, seek or open (+isInterruption:).
static const OSStatus kVibeReadInterrupted = 'intr';

// An ID3v2 tag's whole length from the file's first 10 bytes: the syncsafe
// size in bytes 6-9 excludes the header and a footer. 0 for no tag.
static uint32_t VibeID3v2TagBytes(const uint8_t header[10]) {
    if (memcmp(header, "ID3", 3) != 0) {
        return 0;
    }
    return 10 + (header[5] & 0x10 ? 10 : 0)
            + ((header[6] & 0x7F) << 21 | (header[7] & 0x7F) << 14 | (header[8] & 0x7F) << 7 | (header[9] & 0x7F));
}

@implementation AudioFileHandle {
    // What the parser's callbacks read, and dr_flac's and dr_wav's: valid from open until
    // dealloc has closed both. -1 once closed, or for a QuickTime container
    // (below), whose parser reads through its own descriptor.
    int _descriptor;
    SInt64 _size;
    // Written by the decode of a stream counting its MPEG packets as it
    // goes, and read on any thread, hence the getter's atomic load.
    AVAudioFramePosition _length;
    AudioFileID _parser;
    AudioFileTypeID _container; // the parser's kAudioFilePropertyFileFormat
    // The last block a small read filled: its bytes from _readBlockStart,
    // _readBlockLength of them. Allocated by the first.
    uint8_t *_readBlock;
    SInt64 _readBlockStart;
    UInt32 _readBlockLength;
    ExtAudioFileRef _codec; // NULL while dr_mp3, dr_flac or dr_wav decodes
    UInt32 _bytesPerFrame; // of the processing format, per buffer
    BOOL _writing;
    BOOL _mpegChoiceApplies; // an MPEG file
    BOOL _openedUnderApple;  // the choice when it opened
    // dr_mp3's decode: the parser's packets on a timeline of packet ×
    // framesPerPacket, with _mpegSkip frames before logical frame 0.
    drmp3dec *_mpeg;
    // Up to kVibeMPEGReadPackets packets as the parser read them, from
    // packet _mpegReadFirst on; _mpegPacket is the one decoded last.
    uint8_t *_mpegRead;
    UInt32 _mpegReadCapacity;
    AudioStreamPacketDescription _mpegReadPackets[kVibeMPEGReadPackets];
    SInt64 _mpegReadFirst;
    UInt32 _mpegReadCount;
    uint8_t *_mpegPacket;
    UInt32 _mpegPacketBytes; // 0 when none is held
    UInt32 _mpegBytesPerPacket; // nonzero for fixed-size packets, which have no descriptions
    UInt32 _mpegFramesPerPacket;
    UInt32 _mpegDelay;       // the synthesis filterbank's, in frames
    SInt64 _mpegSkip;
    SInt64 _mpegPacketCount;
    SInt64 _mpegEstimate;    // an uncounted stream's packets at open, for the settle's log
    _Atomic bool _lengthEstimated;
    SInt64 _mpegNextPacket;
    SInt64 _mpegPosition; // logical frame the next read delivers
    float *_mpegPCM;      // one packet's frames, interleaved
    UInt32 _mpegPCMFrames;
    UInt32 _mpegPCMOffset;
    // dr_flac's or dr_wav's decode, at most one: the stream read through the
    // descriptor at a cursor of its own.
    drflac *_flac;
    drwav *_wav; // &_wavState once drwav_init has succeeded
    drwav _wavState;
    SInt64 _streamCursor;
    BOOL _streamReadFailed; // a pread failed, which neither decoder can tell from the end
    // A file still streaming: every read past the bytes written waits for
    // them. Set by the open and fixed from then on; nil for a whole file.
    CloudFileAvailability *_availability;
    BOOL _holdsStream; // one of _availability's readers (holdStream)
    _Atomic bool _readsInterrupted;
    _Atomic bool _waitingForBytes;
    BOOL (^_openInterrupted)(void); // the open's caller's, while it runs
    // Latched by the wait that answered no, so each decoder sees one clean
    // end of data, never bytes after a gap, and its read or seek reports why:
    // the transfer's error, for good, or an interruption, until the next seek.
    NSError *_waitError;
}

+ (BOOL)appleMPEGDecoder {
    return atomic_load(&sAppleMPEGDecoder);
}

+ (void)setAppleMPEGDecoder:(BOOL)appleMPEGDecoder {
    atomic_store(&sAppleMPEGDecoder, appleMPEGDecoder);
}

- (NSString *)decoderName {
    return _mpeg ? @"dr_mp3" : _flac ? @"dr_flac" : _wav ? @"dr_wav" : @"apple";
}

- (AudioFileID)parser {
    return _parser;
}

- (AVAudioFramePosition)length {
    return __atomic_load_n(&_length, __ATOMIC_RELAXED);
}

// Acquire, pairing with the settle's release: a reader that sees NO then
// reads the settled length.
- (BOOL)lengthIsEstimated {
    return atomic_load_explicit(&_lengthEstimated, memory_order_acquire);
}

- (AVAudioFramePosition)lengthEstimated:(BOOL *)estimated {
    *estimated = self.lengthIsEstimated;
    return self.length;
}

- (BOOL)decoderChoiceIsStale {
    return _mpegChoiceApplies && _openedUnderApple != atomic_load(&sAppleMPEGDecoder);
}

static NSError *VibeHandleError(OSStatus status, NSString *description) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// A streaming handle's wait for the bytes a read asked for, before it reads
// them. Once one answers no, every wait does until a seek clears an
// interruption; a failure stays. With a buffer, bytes the tail window holds
// past the download's edge are copied into it, up to `capacity`, their count
// in *copied; 0 means they are on disk.
static BOOL VibeHandleAwait(AudioFileHandle *handle, SInt64 position, SInt64 count,
                            void *window, uint64_t capacity, uint64_t *copied) {
    if (handle->_waitError) {
        return NO;
    }
    _Atomic bool *interrupted = &handle->_readsInterrupted;
    _Atomic bool *waiting = &handle->_waitingForBytes;
    BOOL (^openInterrupted)(void) = handle->_openInterrupted;
    NSError *error = nil;
    // Asked only when the wait is about to block, so the flag is up for a
    // wait and never for bytes already readable.
    CloudFileAvailabilityWait wait = [handle->_availability waitForBytesAt:(uint64_t)MAX(0, position)
                                                                    length:(uint64_t)MAX(0, count)
                                                                windowInto:window
                                                                  capacity:capacity
                                                                    copied:copied
                                                               interrupted:^BOOL{
        if (atomic_load(interrupted) || (openInterrupted && openInterrupted())) {
            return YES;
        }
        atomic_store(waiting, true);
        return NO;
    } deadline:nil error:&error];
    atomic_store(waiting, false);
    if (wait == CloudFileAvailabilityReady) {
        return YES;
    }
    handle->_waitError = wait == CloudFileAvailabilityFailed && error ? error
            : VibeHandleError(kVibeReadInterrupted, [NSString stringWithFormat:@"Reading %@ was interrupted",
                                                                               handle.url.lastPathComponent]);
    return NO;
}

// YES once the whole file is readable: the transfer complete, or every byte
// written. Waiting, it waits as a read does and latches what ends the wait;
// otherwise it never waits and latches nothing.
static BOOL VibeHandleAwaitWhole(AudioFileHandle *handle, BOOL wait) {
    uint64_t size = handle->_availability.size;
    if (wait) {
        return VibeHandleAwait(handle, 0, (SInt64)size, NULL, 0, NULL);
    }
    return [handle->_availability waitForBytesAt:0 length:size windowInto:NULL capacity:0 copied:NULL
                                     interrupted:^BOOL { return YES; } deadline:nil error:NULL] == CloudFileAvailabilityReady;
}

// The `requested` bytes at `position` a read asked for, once there, and as
// many more as are, up to `capacity`, from one source: the tail window when it
// holds them past the download's edge, else the disk, where the part file
// ends at the bytes written (appended to, never extended, so a read comes up
// short there rather than reading zeros). -1 for a wait that answered no,
// latched on the handle, or a failed pread.
static ssize_t VibeHandleFetch(AudioFileHandle *handle, SInt64 position, SInt64 requested, void *buffer, size_t capacity) {
    uint64_t fromWindow = 0;
    if (handle->_availability && !VibeHandleAwait(handle, position, requested, buffer, capacity, &fromWindow)) {
        return -1;
    }
    if (fromWindow) {
        return (ssize_t)fromWindow;
    }
    ssize_t got;
    do {
        got = pread(handle->_descriptor, buffer, capacity, position);
    } while (got < 0 && errno == EINTR);
    return got;
}

// The status of a fetch that answered -1: a lost wait is no I/O error.
static OSStatus VibeHandleFetchFailure(AudioFileHandle *handle) {
    return handle->_waitError ? kAudioFileUnspecifiedError : kAudioFilePositionError;
}

// A read inside the block, filling it from `position` first when the read is
// not all in it already: a streaming fill waits for the bytes asked for, not
// the block, and takes whatever more is there.
static OSStatus VibeHandleReadBlock(AudioFileHandle *handle, SInt64 position, UInt32 requestCount, UInt32 fill,
                                    void *buffer, UInt32 *actualCount) {
    if (!handle->_readBlock && !(handle->_readBlock = malloc(kVibeReadBlock))) {
        *actualCount = 0;
        return kAudioFilePositionError;
    }
    if (position < handle->_readBlockStart
            || position + requestCount > handle->_readBlockStart + handle->_readBlockLength) {
        ssize_t filled = VibeHandleFetch(handle, position, requestCount, handle->_readBlock, fill);
        if (filled < 0) {
            handle->_readBlockLength = 0;
            *actualCount = 0;
            return VibeHandleFetchFailure(handle);
        }
        handle->_readBlockStart = position;
        handle->_readBlockLength = (UInt32)filled;
    }
    UInt32 got = (UInt32)MIN((SInt64)requestCount, handle->_readBlockStart + handle->_readBlockLength - position);
    memcpy(buffer, handle->_readBlock + (position - handle->_readBlockStart), got);
    *actualCount = got;
    return (got == 0 && requestCount > 0) ? kAudioFileEndOfFileError : noErr;
}

// Short reads answered as such, and a read at or past EOF as the end-of-file
// status: the shape CoreAudio's own file reader gives its parsers, which keeps
// the verdicts AudioFileOpenURL would give.
static OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)clientData;
    if (requestCount < kVibeReadBlock && position >= 0) {
        return VibeHandleReadBlock(handle, position, requestCount, kVibeReadBlock, buffer, actualCount);
    }
    ssize_t got = VibeHandleFetch(handle, position, requestCount, buffer, requestCount);
    if (got < 0) {
        *actualCount = 0;
        return VibeHandleFetchFailure(handle);
    }
    *actualCount = (UInt32)got;
    return (got == 0 && requestCount > 0) ? kAudioFileEndOfFileError : noErr;
}

static SInt64 VibeHandleSize(void *clientData) {
    return ((__bridge AudioFileHandle *)clientData)->_size;
}

// dr_flac's and dr_wav's reads, over the parser's descriptor at their own
// cursor. Both take a short read for the end of the stream, so a read is filled
// but at the end. TRAP: a failed read ends it short too, so it is remembered
// here and reported by the read or seek it happened in: a read error must never
// become a clean end. A wait that answers no reads nothing: the decoder's
// position stays where the stream's is.
static size_t VibeStreamRead(void *user, void *buffer, size_t count) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    if (count <= kVibeStreamReadSmall) {
        UInt32 got;
        if (VibeHandleReadBlock(handle, handle->_streamCursor, (UInt32)count, kVibeStreamReadFill, buffer, &got)
                == kAudioFilePositionError) {
            handle->_streamReadFailed = YES;
        }
        handle->_streamCursor += got;
        return got;
    }
    ssize_t got = VibeHandleFetch(handle, handle->_streamCursor, (SInt64)count, buffer, count);
    if (got < 0) {
        if (!handle->_waitError) {
            handle->_streamReadFailed = YES;
        }
        return 0;
    }
    handle->_streamCursor += got;
    return (size_t)got;
}

// A position past the end is refused: nothing is there to read, and a damaged
// seek table's offset or chunk size can be exabytes out.
static drflac_bool32 VibeStreamSeek(void *user, int offset, int origin) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    SInt64 base = origin == 0 ? 0 : origin == 1 ? handle->_streamCursor : handle->_size;
    SInt64 target;
    if (__builtin_add_overflow(base, (SInt64)offset, &target) || target < 0 || target > handle->_size) {
        return DRFLAC_FALSE;
    }
    handle->_streamCursor = target;
    return DRFLAC_TRUE;
}

static drflac_bool32 VibeFLACSeek(void *user, int offset, drflac_seek_origin origin) {
    _Static_assert(DRFLAC_SEEK_SET == 0 && DRFLAC_SEEK_CUR == 1 && DRFLAC_SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, offset, (int)origin);
}

static drwav_bool32 VibeWAVSeek(void *user, int offset, drwav_seek_origin origin) {
    _Static_assert(DRWAV_SEEK_SET == 0 && DRWAV_SEEK_CUR == 1 && DRWAV_SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, offset, (int)origin);
}

// One tell for both: their tell procs are the same type.
static drflac_bool32 VibeStreamTell(void *user, drflac_int64 *cursor) {
    *cursor = ((__bridge AudioFileHandle *)user)->_streamCursor;
    return DRFLAC_TRUE;
}

// Interleaved frames into a planar buffer from frame `offset` on.
static void VibeDeinterleave(const float *from, UInt32 channels, float *const *planes, AVAudioFrameCount offset, UInt32 frames) {
    if (channels == 2) {
        DSPSplitComplex planar = {planes[0] + offset, planes[1] + offset};
        vDSP_ctoz((const DSPComplex *)from, 2, &planar, 1, frames);
        return;
    }
    for (UInt32 c = 0; c < channels; c++) {
        for (UInt32 f = 0; f < frames; f++) {
            planes[c][offset + f] = from[(size_t)f * channels + c];
        }
    }
}

// The type CoreAudio registers for an extension: the hint AudioFileOpenURL
// takes from a path. 0 when none is registered.
static AudioFileTypeID VibeFileTypeForExtension(NSString *extension) {
    // A strong local, not a bridged temporary: ARC frees that at the end of
    // its statement, leaving the lookup below reading freed memory.
    NSString *lowered = extension.lowercaseString;
    CFStringRef key = (__bridge CFStringRef)lowered;
    UInt32 size = 0;
    if (lowered.length == 0
            || AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size) != noErr
            || size < sizeof(AudioFileTypeID)) {
        return 0;
    }
    AudioFileTypeID types[8] = {0};
    size = MIN(size, (UInt32)sizeof(types));
    if (AudioFileGetGlobalInfo(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size, types) != noErr) {
        return 0;
    }
    return types[0];
}

static UInt32 VibeLayoutSize(const AudioChannelLayout *layout) {
    return (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions)
                    + layout->mNumberChannelDescriptions * sizeof(AudioChannelDescription));
}

// A layout the file states, or none: CoreAudio answers a layout with no tag,
// no bitmap and no descriptions for a WAV that carries none.
static AVAudioChannelLayout *VibeFileChannelLayout(ExtAudioFileRef reader) {
    UInt32 size = 0;
    Boolean writable = false;
    if (ExtAudioFileGetPropertyInfo(reader, kExtAudioFileProperty_FileChannelLayout, &size, &writable) != noErr || size == 0) {
        return nil;
    }
    AudioChannelLayout *layout = calloc(1, size);
    AVAudioChannelLayout *result = nil;
    if (ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileChannelLayout, &size, layout) == noErr
            && (layout->mChannelLayoutTag || layout->mChannelBitmap || layout->mNumberChannelDescriptions)) {
        result = [[AVAudioChannelLayout alloc] initWithLayout:layout];
    }
    free(layout);
    return result;
}

#if VIBE_VERBOSE_LOGGING
// A refusal names both statuses and how the file starts, so a report says why
// without the file itself.
static void VibeLogOpenRefusal(NSURL *url, int descriptor, SInt64 size, AudioFileTypeID hint, OSStatus hinted, OSStatus sniffed) {
    uint8_t head[16] = {0};
    ssize_t got = pread(descriptor, head, sizeof(head), 0);
    uint32_t tag = got >= 10 ? VibeID3v2TagBytes(head) : 0;
    NSString *start;
    if (tag) {
        start = [NSString stringWithFormat:@"an ID3v2.%u tag of %u bytes", head[3], tag];
    } else {
        NSMutableString *hex = [NSMutableString string];
        for (ssize_t i = 0; i < got; i++) {
            [hex appendFormat:@"%02x", head[i]];
        }
        start = [NSString stringWithFormat:@"the bytes %@", hex];
    }
    LogWarn(@"Open: CoreAudio refused %@ as its extension's type (%@) and by content (%d); %lld bytes, starting with %@",
            url.lastPathComponent, hint ? [NSString stringWithFormat:@"%d", (int)hinted] : @"none registered",
            (int)sniffed, size, start);
}
#endif

- (instancetype)initForReading:(NSURL *)url error:(NSError **)error {
    return [self initForReading:url interleaved:NO error:error];
}

- (instancetype)initForReading:(NSURL *)url interleaved:(BOOL)interleaved error:(NSError **)error {
    return [self initForReading:url interleaved:interleaved interrupted:nil error:error];
}

- (instancetype)initParserForReading:(NSURL *)url error:(NSError **)error {
    return [self initParserForReading:url interrupted:nil error:error];
}

+ (BOOL)isInterruption:(NSError *)error {
    return error.code == kVibeReadInterrupted && [error.domain isEqualToString:NSOSStatusErrorDomain];
}

- (void)interruptReads {
    atomic_store(&_readsInterrupted, true);
    [_availability wakeWaiters];
}

- (void)allowReads {
    atomic_store(&_readsInterrupted, false);
}

- (BOOL)waitingForBytes {
    return atomic_load(&_waitingForBytes);
}

- (uint64_t)bytesWritten {
    return _availability ? _availability.writtenBytes : (uint64_t)MAX(0, _size);
}

- (void)holdStream {
    if (_availability && !_holdsStream) {
        _holdsStream = YES;
        [_availability addReader]; // removed by dealloc
    }
}

- (instancetype)initParserForReading:(NSURL *)url interrupted:(BOOL (^)(void))interrupted error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _url = url;
    _descriptor = -1;
    _openInterrupted = interrupted;
    NSString *name = url.lastPathComponent;
    if (!url.isFileURL) {
        return [self failWithError:error status:kAudioFileUnsupportedFileTypeError
                       description:[NSString stringWithFormat:@"%@ is not a file", name]];
    }
    // TRAP: nonblocking, so a FIFO with no writer returns at once for fstat
    // to refuse, instead of parking an uncancellable open worker. A regular
    // file's pread ignores the flag.
    int flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC;
    _availability = [CloudFileMaterializer availabilityForURL:url];
    _descriptor = open((_availability ? _availability.partURL : url).fileSystemRepresentation, flags);
    if (_descriptor < 0 && _availability && errno == ENOENT) {
        // TRAP: the transfer can finish and rename its part over url between
        // the lookup and the open. Once it has finished, url is the whole file.
        if (!VibeHandleAwaitWhole(self, YES)) {
            return [self failWithError:error status:noErr description:@""];
        }
        _availability = nil;
        _descriptor = open(url.fileSystemRepresentation, flags);
    }
    if (_descriptor < 0) {
        int code = errno;
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open %@: %s", name, strerror(code)]}];
        }
        return nil;
    }
    // A part file is the size it will have, not the size it has.
    struct stat info;
    if (fstat(_descriptor, &info) != 0 || !S_ISREG(info.st_mode)
            || (_availability ? _availability.size : (uint64_t)info.st_size) == 0) {
        return [self failWithError:error status:kAudioFileUnsupportedFileTypeError
                       description:[NSString stringWithFormat:@"%@ holds no audio data", name]];
    }
    _size = _availability ? (SInt64)_availability.size : info.st_size;
    // TRAP: parse as the extension's type first, as AudioFileOpenURL does:
    // sniffing alone refuses an MP3 with stray bytes between its ID3 tag and
    // first frame, which the hinted parse plays. A refusal falls back to
    // sniffing, so a misnamed file is judged by what it holds.
    AudioFileTypeID hint = VibeFileTypeForExtension(url.pathExtension);
    void *context = (__bridge void *)self;
    OSStatus hinted = hint ? AudioFileOpenWithCallbacks(context, VibeHandleRead, NULL, VibeHandleSize, NULL, hint, &_parser)
                           : kAudioFileUnsupportedFileTypeError;
    OSStatus status = hinted;
    if (status != noErr) {
        [self closeParser];
        status = AudioFileOpenWithCallbacks(context, VibeHandleRead, NULL, VibeHandleSize, NULL, 0, &_parser);
    }
    if (status != noErr && !_availability
            && (status == kAudio_UnimplementedError || hinted == kAudio_UnimplementedError)) {
        // TRAP: CoreAudio's QuickTime reader (MooV, Voice Memos' .qta) has no
        // callback open and answers kAudio_UnimplementedError, so this parse
        // goes through the URL. Safe: the URL open leaks only on the empty
        // files and directories already refused above. iOS has no such
        // reader, and a streaming file's URL is not yet the file.
        [self closeParser];
        close(_descriptor);
        _descriptor = -1;
        status = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, hint, &_parser);
    }
    if (status != noErr) {
#if VIBE_VERBOSE_LOGGING
        if (_descriptor >= 0 && !_waitError) {
            VibeLogOpenRefusal(url, _descriptor, _size, hint, hinted, status);
        }
#endif
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"CoreAudio refused %@ (%d)", name, (int)status]];
    }
    // TRAP: CoreAudio's Ogg reader opens FLAC in Ogg but reports no length
    // and decodes only its first page (macOS 27), so the file would play for
    // a second and end as if whole. Refused here, where playback and the
    // metadata fallback both open, it fails as any undecodable file does.
    // Vorbis and Opus in Ogg read in full.
    UInt32 size = sizeof(_container);
    AudioFileGetProperty(_parser, kAudioFilePropertyFileFormat, &size, &_container);
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    if (_container == kVibeOggFileType
            && AudioFileGetProperty(_parser, kAudioFilePropertyDataFormat, &size, &format) == noErr
            && format.mFormatID == kAudioFormatFLAC) {
        return [self failWithError:error status:kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ is FLAC in Ogg, which CoreAudio truncates", name]];
    }
    return [self openedWithError:error];
}

- (instancetype)initForReading:(NSURL *)url interleaved:(BOOL)interleaved interrupted:(BOOL (^)(void))interrupted
                         error:(NSError **)error {
    self = [self initParserForReading:url interrupted:interrupted error:error];
    if (!self) {
        return nil;
    }
    // Again: the parser's open let it go, and the decoders' opens read too.
    _openInterrupted = interrupted;
    NSString *name = url.lastPathComponent;
    OSStatus status = ExtAudioFileWrapAudioFileID(_parser, false, &_codec);
    if (status != noErr) {
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"No decoder for %@ (%d)", name, (int)status]];
    }
    AudioStreamBasicDescription fileDescription = {0};
    UInt32 size = sizeof(fileDescription);
    status = ExtAudioFileGetProperty(_codec, kExtAudioFileProperty_FileDataFormat, &size, &fileDescription);
    if (status != noErr || fileDescription.mChannelsPerFrame == 0 || fileDescription.mSampleRate <= 0) {
        return [self failWithError:error status:status ?: kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ reports no audio format", name]];
    }
    // The processing format carries the file's layout when it states one, and
    // a discrete layout for a wider file that does not: a converter between
    // more than two channels is refused without one.
    AVAudioChannelLayout *layout = VibeFileChannelLayout(_codec);
    if (!layout && fileDescription.mChannelsPerFrame > 2) {
        layout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | fileDescription.mChannelsPerFrame];
    }
    _fileFormat = [[AVAudioFormat alloc] initWithStreamDescription:&fileDescription channelLayout:layout];
    _processingFormat = layout
            ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:fileDescription.mSampleRate interleaved:interleaved channelLayout:layout]
            : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:fileDescription.mSampleRate
                                                 channels:fileDescription.mChannelsPerFrame interleaved:interleaved];
    if (!_fileFormat || !_processingFormat) {
        return [self failWithError:error status:kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ has a format this player cannot decode", name]];
    }
    UInt32 formatID = fileDescription.mFormatID;
    _mpegChoiceApplies = formatID == kAudioFormatMPEGLayer1 || formatID == kAudioFormatMPEGLayer2 || formatID == kAudioFormatMPEGLayer3;
    _openedUnderApple = atomic_load(&sAppleMPEGDecoder);
    if (_mpegChoiceApplies && !_openedUnderApple && [self openMPEGWithDescription:fileDescription]) {
        return [self openedWithError:error];
    }
    // Before the client format below, which Apple's FLAC codec refuses for
    // some legal streams dr_flac plays: block sizes of 16 and 65535, rates
    // past 655 kHz, 32-bit samples.
    if (_descriptor >= 0 && ((formatID == kAudioFormatFLAC && [self openFLAC])
                             || [self openWAV])) {
        return [self openedWithError:error];
    }
    status = [self decodeToProcessingFormatInLayout:layout];
    if (status != noErr) {
        // What AVAudioFile reported for a file its decoder cannot produce:
        // an MP2 on a platform without the codec opens and fails here.
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"No decoder for %@'s format (%d)", name, (int)status]];
    }
    _bytesPerFrame = _processingFormat.streamDescription->mBytesPerFrame;
    SInt64 length = 0;
    size = sizeof(length);
    if (ExtAudioFileGetProperty(_codec, kExtAudioFileProperty_FileLengthFrames, &size, &length) != noErr) {
        length = 0;
    }
    // For a fixed frame size the length is the audio bytes the file holds —
    // the header's count, clamped to what lies past the data offset, since a
    // truncated download declares more than it has — over the frame size.
    // The packet count CoreAudio derives answers 0 for a WAV of one or two
    // frames.
    UInt64 bytes = 0;
    SInt64 offset = 0;
    size = sizeof(bytes);
    UInt32 offsetSize = sizeof(offset);
    if (fileDescription.mBytesPerFrame > 0
            && AudioFileGetProperty(_parser, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr
            && AudioFileGetProperty(_parser, kAudioFilePropertyDataOffset, &offsetSize, &offset) == noErr
            && offset >= 0 && offset <= _size) {
        length = (SInt64)(MIN(bytes, (UInt64)(_size - offset)) / fileDescription.mBytesPerFrame);
    }
    _length = length;
    return [self openedWithError:error];
}

- (instancetype)initForWriting:(NSURL *)url fileType:(AudioFileTypeID)fileType fileFormat:(AVAudioFormat *)fileFormat
              processingFormat:(AVAudioFormat *)processingFormat error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _url = url;
    _descriptor = -1;
    _writing = YES;
    _fileFormat = fileFormat;
    _processingFormat = processingFormat;
    NSString *name = url.lastPathComponent;
    OSStatus status = ExtAudioFileCreateWithURL((__bridge CFURLRef)url, fileType, fileFormat.streamDescription,
                                                fileFormat.channelLayout.layout, kAudioFileFlags_EraseFile, &_codec);
    if (status != noErr) {
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"Could not create %@ (%d)", name, (int)status]];
    }
    const AudioStreamBasicDescription *client = processingFormat.streamDescription;
    status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientDataFormat, sizeof(*client), client);
    if (status == noErr && processingFormat.channelLayout) {
        const AudioChannelLayout *layout = processingFormat.channelLayout.layout;
        status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientChannelLayout, VibeLayoutSize(layout), layout);
    }
    if (status != noErr) {
        // The container already exists and is left; the caller removes its
        // temp.
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"No encoder from that format into %@ (%d)", name, (int)status]];
    }
    _bytesPerFrame = client->mBytesPerFrame;
    return self;
}

- (OSStatus)decodeToProcessingFormatInLayout:(AVAudioChannelLayout *)layout {
    const AudioStreamBasicDescription *client = _processingFormat.streamDescription;
    OSStatus status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientDataFormat, sizeof(*client), client);
    if (status == noErr && layout) {
        status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientChannelLayout, VibeLayoutSize(layout.layout), layout.layout);
    }
    return status;
}

// TRAP: an MP3 with no Xing, Info or VBRI frame states no packet count, and
// CoreAudio's parser finds one by reading every frame header to the end:
// ExtAudioFile's length, the packet count and the maximum packet size each
// ask it (measured; the bit rate, the data offset and size, the packet table
// and the packet size bound read a few frames at most), so a stream of one
// opened only once downloaded. This is the count it opens on instead, from
// the frames of its head on disk (kVibeMPEGEstimateBytes): every one at the
// first's rate gives the packets its audio bytes hold at that rate; any
// other, the packets they hold at the walked frames' average size. Either is
// an estimate: a head at one rate proves nothing of the rest, which can
// change rate after an intro. 0 for the whole count: a VBR header, which
// states it, or a head that does not walk. dr_mp3's parser walks it,
// synthesizing nothing.
static SInt64 VibeUncountedMPEGPackets(AudioFileHandle *handle, AudioStreamBasicDescription description) {
    SInt64 offset = 0;
    UInt64 bytes = 0;
    UInt32 got = 0;
    UInt32 offsetSize = sizeof(offset), bytesSize = sizeof(bytes);
    if (AudioFileGetProperty(handle->_parser, kAudioFilePropertyDataOffset, &offsetSize, &offset) != noErr
            || AudioFileGetProperty(handle->_parser, kAudioFilePropertyAudioDataByteCount, &bytesSize, &bytes) != noErr) {
        return 0;
    }
    // From the ID3v2 tag's end: a VBR header frame the parser skips lies
    // between it and the first audio frame, or is that frame.
    uint8_t tag[10] = {0};
    SInt64 start = 0;
    if (VibeHandleRead((__bridge void *)handle, 0, sizeof(tag), tag, &got) == noErr && got == sizeof(tag)) {
        start = VibeID3v2TagBytes(tag);
    }
    const SInt64 span = 48; // a header, a CRC, side information and a header's tag
    if (start > offset || offset - start + span > kVibeReadBlock) {
        return 0;
    }
    // The frames walked are waited for as any read is: a header's worth
    // first, then, their size known, sixteen. TRAP: a tag past the readable
    // edge, cover art's, left too few frames on disk to walk, and the open
    // went to the parser's whole-file count, which waits for the entire
    // download.
    UInt32 frames = 0, walked = 0, first = 0;
    BOOL constant = YES;
    SInt64 need = span;
    for (int pass = 0; pass < 2; pass++) {
        if (!VibeHandleAwait(handle, offset, MIN(need, handle->_size - offset), NULL, 0, NULL)) {
            return 0;
        }
        SInt64 onDisk = MIN(handle->_size, (SInt64)handle->_availability.writtenBytes);
        if (onDisk < offset + span) {
            return 0;
        }
        UInt32 length = (UInt32)(offset - start + MIN(onDisk - offset, (SInt64)kVibeMPEGEstimateBytes));
        uint8_t *region = malloc(length);
        UInt32 header = (UInt32)(offset - start + span);
        frames = walked = first = 0;
        constant = YES;
        if (region && VibeHandleRead((__bridge void *)handle, start, length, region, &got) == noErr && got == length
                && !memmem(region, header, "Xing", 4) && !memmem(region, header, "Info", 4) && !memmem(region, header, "VBRI", 4)) {
            const uint8_t *head = region + (offset - start);
            UInt32 available = length - (UInt32)(offset - start);
            int layer = description.mFormatID == kAudioFormatMPEGLayer1 ? 1 : description.mFormatID == kAudioFormatMPEGLayer2 ? 2 : 3;
            drmp3dec parser;
            drmp3dec_init(&parser);
            for (;;) {
                drmp3dec_frame_info info = {0};
                drmp3dec_decode_frame(&parser, head + walked, (int)(available - walked), NULL, &info);
                // A whole frame of this stream exactly here, its header the one
                // parsed (the parser skips what is not a frame, and forgets its
                // header on a damaged one); free format, no bit rate, is counted
                // at open. A frame layer III's reservoir cannot decode still counts.
                if (info.frame_bytes <= 0 || memcmp(parser.header, head + walked, sizeof(parser.header)) != 0
                        || info.layer != layer || info.sample_rate != description.mSampleRate || info.bitrate_kbps == 0) {
                    break;
                }
                first = frames++ ? first : (UInt32)info.bitrate_kbps;
                constant = constant && (UInt32)info.bitrate_kbps == first;
                walked += (UInt32)info.frame_bytes;
            }
        }
        free(region);
        if (frames == 0 || frames >= kVibeMPEGEstimateFrames || onDisk >= handle->_size) {
            break;
        }
        need = walked + (SInt64)(kVibeMPEGEstimateFrames - frames) * (walked / frames) + span;
    }
    if (frames < kVibeMPEGEstimateFrames) {
        return 0;
    }
    if (!constant) {
        return (SInt64)((bytes * frames + walked / 2) / walked);
    }
    // The nearest count: a frame a fraction of a byte long is padded to the
    // rate on average, and the bytes past the last whole frame are not one.
    UInt64 scale = (UInt64)description.mFramesPerPacket * first * 1000;
    return (SInt64)((bytes * 8 * (UInt64)description.mSampleRate + scale / 2) / scale);
}

// Takes the file over for dr_mp3, or leaves it to ExtAudioFile when the
// parser cannot serve its packets. ExtAudioFile answers the length, priming
// and padding excluded, exactly as for its own decode, and is disposed without
// decoding; the parser answers the priming and serves the packets. A stream
// with no VBR header goes uncounted, its length meanwhile the estimate
// VibeUncountedMPEGPackets makes, which the decode keeps ahead of its cursor
// and settles (settleMPEGPacketCount:).
- (BOOL)openMPEGWithDescription:(AudioStreamBasicDescription)description {
    SInt64 length = 0;
    UInt64 packets = 0;
    UInt32 upperBound = 0;
    UInt32 lengthSize = sizeof(length), packetsSize = sizeof(packets), boundSize = sizeof(upperBound);
    if (description.mFramesPerPacket == 0 || description.mFramesPerPacket > DRMP3_MAX_PCM_FRAMES_PER_MP3_FRAME
            || description.mChannelsPerFrame > 2
            || AudioFileGetProperty(_parser, kAudioFilePropertyPacketSizeUpperBound, &boundSize, &upperBound) != noErr) {
        return NO;
    }
    SInt64 estimate = _availability ? VibeUncountedMPEGPackets(self, description) : 0;
    if (estimate > 0) {
        packets = kVibeMPEGPacketsUncounted;
        _mpegEstimate = estimate;
        atomic_store(&_lengthEstimated, true);
        LogInfo(@"MP3 stream: %@ has no VBR header; opens on %lld packets estimated from its head's frames",
                _url.lastPathComponent, estimate);
    }
    else if (ExtAudioFileGetProperty(_codec, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length) != noErr
            || AudioFileGetProperty(_parser, kAudioFilePropertyAudioDataPacketCount, &packetsSize, &packets) != noErr) {
        return NO;
    }
    // An untagged file has no packet table, and no priming.
    AudioFilePacketTableInfo table = {0};
    UInt32 size = sizeof(table);
    AudioFileGetProperty(_parser, kAudioFilePropertyPacketTableInfo, &size, &table);
    if (estimate > 0) {
        // Priming excluded, as settleMPEGPacketCount: excludes it, or a right
        // packet estimate still settles to a different length.
        length = estimate * description.mFramesPerPacket - MAX(0, table.mPrimingFrames);
    }
    ExtAudioFileDispose(_codec);
    _codec = NULL;
    // At least 4096 bytes, more than any MPEG audio frame, so the parser can
    // always return one whatever its upper bound says.
    _mpegReadCapacity = MAX(kVibeMPEGReadPackets * upperBound, 4096u);
    _mpeg = calloc(1, sizeof(*_mpeg));
    _mpegRead = malloc(_mpegReadCapacity);
    _mpegPCM = calloc(DRMP3_MAX_SAMPLES_PER_FRAME, sizeof(float));
    _mpegFramesPerPacket = description.mFramesPerPacket;
    _mpegBytesPerPacket = description.mBytesPerPacket;
    // The parser's priming is the encoder's alone: Apple's decoder removes its
    // own synthesis delay itself, tagged or not, so the same frames are
    // skipped here.
    _mpegDelay = description.mFormatID == kAudioFormatMPEGLayer3 ? 529 : 241;
    _mpegSkip = MAX(0, table.mPrimingFrames) + _mpegDelay;
    _mpegPacketCount = (SInt64)packets;
    _length = MAX(0, length);
    return YES;
}

// An uncounted stream's count, the parser's own, settling its length: free
// where the reads reached the stream's end, since the parser has read every
// frame header to find it, or counted from disk once the download is
// complete. A failed count leaves the stream uncounted.
- (void)settleMPEGPacketCount:(SInt64)packets when:(NSString *)when {
    _mpegPacketCount = packets;
    // TRAP: the length, then the flag, released: a reader on another thread
    // that sees the flag clear (lengthIsEstimated, acquire) then reads the
    // settled length. The other order let the player see NO, read the
    // estimate, take it as final and never republish the true duration.
    __atomic_store_n(&_length, MAX(0, packets * _mpegFramesPerPacket - (_mpegSkip - _mpegDelay)), __ATOMIC_RELAXED);
    atomic_store_explicit(&_lengthEstimated, false, memory_order_release);
    LogInfo(@"MP3 stream: %@ settled %@ at %lld packets; its estimate was %+.2f%% off", _url.lastPathComponent, when,
            packets, packets > 0 ? 100.0 * (_mpegEstimate - packets) / packets : 0.0);
}

// The parser reads every frame header it has not yet read, the rest of the
// file, which takes a long mix tens of milliseconds from disk and a stream
// the rest of its download, so it is paid only once downloaded.
- (void)countMPEGPacketsOnDisk {
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    SInt64 packets = 0;
    UInt32 size = sizeof(packets);
    if (AudioFileGetProperty(_parser, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr && packets > 0) {
        [self settleMPEGPacketCount:packets when:[NSString stringWithFormat:@"once downloaded, counted from disk in %.1f ms",
                                                  (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6]];
    }
}

- (BOOL)awaitExactLength:(NSError **)error {
    if (!atomic_load(&_lengthEstimated)) {
        return YES;
    }
    if (!VibeHandleAwaitWhole(self, YES)) {
        return [self reportWaitFault:error];
    }
    [self countMPEGPacketsOnDisk];
    if (atomic_load(&_lengthEstimated)) {
        if (error) {
            *error = VibeHandleError(kAudioFileInvalidFileError, [NSString stringWithFormat:@"%@ could not be counted", _url.lastPathComponent]);
        }
        return NO;
    }
    return YES;
}

// Takes the file over for dr_flac, or leaves it to ExtAudioFile when dr_flac
// cannot open it, finds no frame in it or reads it differently. dr_flac
// answers the length, STREAMINFO's or, for a stream that leaves it unknown,
// the end of its last frame (ThirdParty/AGENTS.md).
- (BOOL)openFLAC {
    _streamCursor = 0;
    _streamReadFailed = NO;
    _flac = drflac_open(VibeStreamRead, VibeFLACSeek, VibeStreamTell, (__bridge void *)self, NULL);
    if (!_flac || ![self adoptStreamDecoderWithChannels:_flac->channels rate:_flac->sampleRate length:_flac->totalPCMFrameCount]) {
        [self closeStreamDecoder];
        return NO;
    }
    return YES;
}

// What dr_wav decodes, in two halves. Its containers, as CoreAudio's parser
// names them, decide whether it is tried at all, so no other file pays its
// read and failed parse; BW64 is not one. Its codings, which only its own
// parse can tell (a WAVE_FORMAT_EXTENSIBLE's subformat, an AIFF-C's
// compression type), decide whether it keeps the file.
static BOOL VibeDrWAVReadsContainer(AudioFileTypeID container) {
    return container == kAudioFileWAVEType || container == kAudioFileWave64Type || container == kAudioFileRF64Type
            || container == kAudioFileAIFFType || container == kAudioFileAIFCType;
}

static BOOL VibeDrWAVDecodesCoding(const drwav *wav) {
    drwav_uint16 tag = wav->translatedFormatTag;
    return tag == DR_WAVE_FORMAT_PCM || tag == DR_WAVE_FORMAT_ALAW || tag == DR_WAVE_FORMAT_MULAW
            || tag == DR_WAVE_FORMAT_ADPCM || tag == DR_WAVE_FORMAT_DVI_ADPCM
            || (tag == DR_WAVE_FORMAT_IEEE_FLOAT && (wav->bitsPerSample == 32 || wav->bitsPerSample == 64));
}

// Takes a file of a container dr_wav reads over for it, as openFLAC does for
// dr_flac, when it holds a coding dr_wav decodes; one it does not, or reads
// differently, is left to ExtAudioFile. dr_wav answers the length: the frames
// the data holds, a COMM or fact count only when it is no more.
- (BOOL)openWAV {
    if (!VibeDrWAVReadsContainer(_container)) {
        return NO;
    }
    _streamCursor = 0;
    _streamReadFailed = NO;
    if (!drwav_init(&_wavState, VibeStreamRead, VibeWAVSeek, VibeStreamTell, (__bridge void *)self, NULL)) {
        return NO;
    }
    _wav = &_wavState;
    if (!VibeDrWAVDecodesCoding(_wav)
            || ![self adoptStreamDecoderWithChannels:_wav->channels rate:_wav->sampleRate length:_wav->totalPCMFrameCount]) {
        [self closeStreamDecoder];
        return NO;
    }
    // TRAP: CoreAudio's parser describes a sowt AIFF-C as 16-bit whatever its
    // COMM says, so a 24 or 32-bit one would report 16 as its depth and have
    // bit-perfect output choose 16 bits, and Apple's decoder reads it 1.5 or 2
    // times as long, so only dr_wav reads one right. The file's description
    // takes the width dr_wav decodes wherever the two disagree on a sample's
    // size in bytes; a 20-bit sample in 3 is both's.
    const AudioStreamBasicDescription *parsed = _fileFormat.streamDescription;
    UInt32 bytesPerFrame = (_wav->bitsPerSample + 7) / 8 * _wav->channels;
    if (parsed->mFormatID == kAudioFormatLinearPCM && parsed->mBytesPerFrame != bytesPerFrame) {
        AudioStreamBasicDescription described = *parsed;
        described.mBitsPerChannel = _wav->bitsPerSample;
        described.mBytesPerFrame = described.mBytesPerPacket = bytesPerFrame;
        _fileFormat = [[AVAudioFormat alloc] initWithStreamDescription:&described channelLayout:_fileFormat.channelLayout] ?: _fileFormat;
    }
    return YES;
}

// Keeps the dr_flac or dr_wav decode just opened when it reads the file as
// the parser does; the caller closes one refused. A kept one reads the stream
// through the descriptor itself, so ExtAudioFile is disposed without decoding
// and the parser closed.
- (BOOL)adoptStreamDecoderWithChannels:(UInt32)channels rate:(UInt32)rate length:(UInt64)length {
    if (_streamReadFailed || _waitError || length == 0 || channels != _processingFormat.channelCount
            || rate != _processingFormat.sampleRate) {
        return NO;
    }
    ExtAudioFileDispose(_codec);
    _codec = NULL;
    [self closeParser];
    _length = (SInt64)length;
    return YES;
}

- (void)closeStreamDecoder {
    drflac_close(_flac);
    _flac = NULL;
    if (_wav) {
        drwav_uninit(_wav);
        _wav = NULL;
    }
}

- (instancetype)failWithError:(NSError **)error status:(OSStatus)status description:(NSString *)description {
    if (error) {
        // A wait that answered no says why better than what CoreAudio made of
        // the reads it lost.
        *error = _waitError ?: VibeHandleError(status, description);
    }
    // dealloc releases the descriptor and whatever parser was left.
    return nil;
}

// A reading open's last word: one a wait ended opened nothing, whatever the
// decoders made of the reads it lost.
- (instancetype)openedWithError:(NSError **)error {
    _openInterrupted = nil;
    return _waitError ? [self failWithError:error status:noErr description:@""] : self;
}

- (void)closeParser {
    if (_parser) {
        AudioFileClose(_parser);
        _parser = NULL;
    }
}

// The decoder before the parser, the parser before the descriptor its
// callbacks read.
- (void)dealloc {
    if (_codec) {
        ExtAudioFileDispose(_codec);
        _codec = NULL;
    }
    free(_readBlock);
    free(_mpeg);
    free(_mpegRead);
    free(_mpegPCM);
    [self closeStreamDecoder];
    [self closeParser];
    if (_descriptor >= 0) {
        close(_descriptor);
        _descriptor = -1;
    }
    if (_holdsStream) {
        [_availability removeReader];
    }
}

#pragma mark - The cursor

- (AVAudioFramePosition)framePosition {
    if (_mpeg) {
        return _mpegPosition;
    }
    if (_flac) {
        return (AVAudioFramePosition)_flac->currentPCMFrame;
    }
    if (_wav) {
        return (AVAudioFramePosition)_wav->readCursorInPCMFrames;
    }
    SInt64 position = 0;
    return ExtAudioFileTell(_codec, &position) == noErr ? position : 0;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if ([AudioFileHandle isInterruption:_waitError]) {
        _waitError = nil;
        if (_flac) {
            // TRAP: dr_flac skips a seek to the frame it believes it is at,
            // and moves within the FLAC frame it holds without reading, but
            // an interrupted read leaves its bitstream inside the next one.
            // From a frame it cannot be at, a seek to 0 restarts it at the
            // first frame.
            _flac->currentPCMFrame = UINT64_MAX;
            drflac_seek_to_pcm_frame(_flac, 0);
        }
        if (_codec) {
            // TRAP: ExtAudioFile keeps the packets a lost read fetched and
            // serves them after a later seek, as if they were the target's.
            // A fresh one over the same parser starts clean.
            ExtAudioFileDispose(_codec);
            if (ExtAudioFileWrapAudioFileID(_parser, false, &_codec) != noErr) {
                _codec = NULL; // the seek below refuses
            } else if ([self decodeToProcessingFormatInLayout:_processingFormat.channelLayout] != noErr) {
                ExtAudioFileDispose(_codec);
                _codec = NULL;
            }
        }
    }
    if (_mpeg) {
        // A fresh decoder a preroll before the target; the reads drop the
        // preroll's frames, as they drop the priming.
        // An uncounted stream's estimate is not the end: a seek past it is
        // kept, its length raised ahead of the cursor as a read raises it.
        BOOL uncounted = _mpegPacketCount == kVibeMPEGPacketsUncounted;
        _mpegPosition = uncounted ? MAX(0, frame) : MIN(MAX(0, frame), _length);
        if (uncounted && _mpegPosition >= _length) {
            __atomic_store_n(&_length, _mpegPosition + 1, __ATOMIC_RELAXED);
        }
        SInt64 packet = (_mpegPosition + _mpegSkip) / _mpegFramesPerPacket;
        _mpegNextPacket = MAX(0, packet - kVibeMPEGSeekPrerollPackets);
        memset(_mpeg, 0, sizeof(*_mpeg));
        _mpegPCMFrames = _mpegPCMOffset = _mpegPacketBytes = _mpegReadCount = 0;
        if (_mpegFramesPerPacket == 576) {
            // MPEG-2 Layer III, a granule a packet: the target's output
            // depends on the two packets before it, and the first of those on
            // 255 bytes of payload before it, which at 8 kbps can be 255
            // packets. A packet's header, a CRC and its side info are not
            // payload.
            SInt64 reach = 255, overhead = 4 + 2 + (_processingFormat.channelCount == 1 ? 9 : 17);
            SInt64 start = MAX(0, MIN(packet, _mpegPacketCount) - 2);
            while (reach > 0 && start > 0) {
                UInt32 wanted = (UInt32)MIN(start, (SInt64)kVibeMPEGReadPackets), count = wanted, bytes = _mpegReadCapacity;
                OSStatus status = AudioFileReadPacketData(_parser, false, &bytes, _mpegReadPackets, start - wanted, &count, _mpegRead);
                if ((status != noErr && status != kAudioFileEndOfFileError) || count != wanted) {
                    _mpegReadCount = 0; // the decode's own read reports it
                    break;
                }
                // Kept as the decode's first read.
                _mpegReadFirst = start - count;
                _mpegReadCount = count;
                for (; reach > 0 && start > _mpegReadFirst; start--) {
                    const AudioStreamPacketDescription *before = &_mpegReadPackets[start - 1 - _mpegReadFirst];
                    reach -= (SInt64)(_mpegBytesPerPacket ?: before->mDataByteSize) - overhead;
                }
            }
            _mpegNextPacket = MIN(_mpegNextPacket, start);
        }
        return [self reportWaitFault:error];
    }
    OSStatus status;
    if (_flac || _wav) {
        // Both clamp the target to the length; past the frames a truncated
        // file holds it lands at the end, where reads return nothing, as
        // Apple's does.
        BOOL landed = (_flac ? drflac_seek_to_pcm_frame(_flac, (drflac_uint64)MAX(0, frame))
                             : drwav_seek_to_pcm_frame(_wav, (drwav_uint64)MAX(0, frame))) && !_streamReadFailed;
        status = landed ? noErr : kAudioFilePositionError;
    } else {
        status = !_codec || _writing ? kAudio_ParamError : ExtAudioFileSeek(_codec, MAX(0, frame));
    }
    if (status != noErr && !_waitError && error) {
        *error = VibeHandleError(status, [NSString stringWithFormat:@"Seeking %@ failed (%d)", _url.lastPathComponent, (int)status]);
    }
    return [self reportWaitFault:error] && status == noErr;
}

// NO, with its error, when a wait answered no during the operation.
- (BOOL)reportWaitFault:(NSError **)error {
    if (_waitError && error) {
        *error = _waitError;
    }
    return !_waitError;
}

#pragma mark - Writing

- (BOOL)writeFromBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    if (![self accepts:buffer writing:YES error:error]) {
        return NO;
    }
    OSStatus status = ExtAudioFileWrite(_codec, buffer.frameLength, buffer.audioBufferList);
    if (status != noErr) {
        if (error) {
            *error = VibeHandleError(status, [NSString stringWithFormat:@"Writing %@ failed (%d)", _url.lastPathComponent, (int)status]);
        }
        return NO;
    }
    _length += buffer.frameLength;
    return YES;
}

- (BOOL)closeWithError:(NSError **)error {
    if (!_codec) {
        return YES;
    }
    OSStatus status = ExtAudioFileDispose(_codec);
    _codec = NULL;
    if (status != noErr && error) {
        *error = VibeHandleError(status, [NSString stringWithFormat:@"Finishing %@ failed (%d)", _url.lastPathComponent, (int)status]);
    }
    return status == noErr;
}

#pragma mark - Reading

// Identity is the usual match; the field comparison serves a successor read
// through an equal format of its own.
- (BOOL)accepts:(AVAudioPCMBuffer *)buffer writing:(BOOL)writing error:(NSError **)error {
    NSString *refusal = nil;
    AVAudioFormat *format = buffer.format;
    if (_writing != writing) {
        refusal = writing ? @"The handle is open for reading" : @"The handle is open for writing";
    }
    else if (format != _processingFormat
            && (format.commonFormat != _processingFormat.commonFormat || format.isInterleaved != _processingFormat.isInterleaved
                || format.channelCount != _processingFormat.channelCount || format.sampleRate != _processingFormat.sampleRate)) {
        refusal = @"The buffer's format is not the file's processing format";
    }
    if (refusal && error) {
        *error = VibeHandleError(kAudio_ParamError, refusal);
    }
    return refusal == nil;
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error {
    return [self readIntoBuffer:buffer frameCount:buffer.frameCapacity error:error];
}

- (BOOL)readIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)frameCount error:(NSError **)error {
    if (![self accepts:buffer writing:NO error:error]) {
        buffer.frameLength = 0;
        return NO;
    }
    if (_waitError) {
        // Refused until a seek, since a lost read may have left the decoder
        // anywhere, and for good after a failure.
        buffer.frameLength = 0;
        return [self reportWaitFault:error];
    }
    AVAudioFrameCount wanted = MIN(frameCount, buffer.frameCapacity);
    if (_mpeg) {
        return [self readMPEGIntoBuffer:buffer frameCount:wanted error:error];
    }
    if (_flac || _wav) {
        return [self readStreamIntoBuffer:buffer frameCount:wanted error:error];
    }
    // The list's data pointers span the whole allocation whatever frameLength
    // says; the copy below walks them by the frames already produced.
    const AudioBufferList *whole = buffer.audioBufferList;
    size_t listSize = offsetof(AudioBufferList, mBuffers) + whole->mNumberBuffers * sizeof(AudioBuffer);
    AudioBufferList *list = alloca(listSize);
    memcpy(list, whole, listSize);
    AVAudioFrameCount total = 0;
    while (total < wanted) {
        UInt32 frames = wanted - total;
        for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
            list->mBuffers[b].mData = (uint8_t *)whole->mBuffers[b].mData + (size_t)total * _bytesPerFrame;
            list->mBuffers[b].mDataByteSize = frames * _bytesPerFrame;
        }
        OSStatus status = ExtAudioFileRead(_codec, &frames, list);
        if (status != noErr || _waitError) {
            buffer.frameLength = total;
            if (error) {
                *error = _waitError ?: VibeHandleError(status, [NSString stringWithFormat:@"Reading %@ failed (%d)", _url.lastPathComponent, (int)status]);
            }
            return NO;
        }
        if (frames == 0) {
            break; // the end
        }
        total += frames;
    }
    buffer.frameLength = total;
    return YES;
}

- (BOOL)readMPEGIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    if (atomic_load_explicit(&_lengthEstimated, memory_order_relaxed) && VibeHandleAwaitWhole(self, NO)) {
        // TRAP: here, on the one thread that reads the handle, since the
        // parser is not thread-safe: the bus's decode queue, or a waveform's.
        [self countMPEGPacketsOnDisk];
    }
    UInt32 channels = _processingFormat.channelCount;
    BOOL interleaved = _processingFormat.isInterleaved;
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount total = 0;
    while (total < wanted && (_mpegPosition < _length || _mpegPacketCount == kVibeMPEGPacketsUncounted)) {
        if (_mpegPCMOffset == _mpegPCMFrames) {
            if (![self decodeNextMPEGPacket:error]) {
                buffer.frameLength = total;
                return NO;
            }
            if (_mpegPCMFrames == 0) {
                break; // no packets left
            }
            continue;
        }
        SInt64 left = _mpegPacketCount == kVibeMPEGPacketsUncounted ? INT64_MAX : _length - _mpegPosition;
        UInt32 frames = (UInt32)MIN((SInt64)MIN(_mpegPCMFrames - _mpegPCMOffset, wanted - total), left);
        const float *from = _mpegPCM + (size_t)_mpegPCMOffset * channels;
        if (interleaved || channels == 1) {
            memcpy(planes[0] + (size_t)total * channels, from, (size_t)frames * channels * sizeof(float));
        } else {
            VibeDeinterleave(from, channels, planes, total, frames);
        }
        _mpegPCMOffset += frames;
        _mpegPosition += frames;
        total += frames;
    }
    if (_mpegPacketCount == kVibeMPEGPacketsUncounted && _mpegPosition >= _length) {
        // The bus ends a voice whose cursor reaches the length, and an
        // estimate is not the end.
        __atomic_store_n(&_length, _mpegPosition + 1, __ATOMIC_RELAXED);
    }
    buffer.frameLength = total;
    return YES;
}

// dr_flac's or dr_wav's decode, straight into the buffer in one call: a channel
// to each plane, or interleaved. Each reads all that is asked but at the end of
// the stream. Reads stop at the length, where dr_flac's would read on.
- (BOOL)readStreamIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    float *const *planes = buffer.floatChannelData;
    drflac_uint64 frames = (drflac_uint64)MIN((SInt64)wanted, MAX(0, _length - self.framePosition));
    drflac_uint64 got;
    if (!_processingFormat.isInterleaved) {
        got = _flac ? drflac_read_pcm_frames_f32_planar(_flac, frames, planes) : drwav_read_pcm_frames_f32_planar(_wav, frames, planes);
    } else {
        got = _flac ? drflac_read_pcm_frames_f32(_flac, frames, planes[0]) : drwav_read_pcm_frames_f32(_wav, frames, planes[0]);
    }
    buffer.frameLength = (AVAudioFrameCount)got;
    if (_streamReadFailed && !_waitError) {
        if (error) {
            *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Reading %@ failed", _url.lastPathComponent]);
        }
        return NO;
    }
    return [self reportWaitFault:error];
}

// Decodes the next packet and places the offset at the cursor within it: the
// frames before it are priming, the decoder's delay or a seek's preroll. None
// held means no packets remain.
- (BOOL)decodeNextMPEGPacket:(NSError **)error {
    _mpegPCMFrames = _mpegPCMOffset = 0;
    if (_mpegNextPacket < _mpegPacketCount
            && (_mpegNextPacket < _mpegReadFirst || _mpegNextPacket >= _mpegReadFirst + _mpegReadCount)) {
        UInt32 bytes = _mpegReadCapacity;
        UInt32 count = kVibeMPEGReadPackets;
        OSStatus status = AudioFileReadPacketData(_parser, false, &bytes, _mpegReadPackets, _mpegNextPacket, &count, _mpegRead);
        if (_waitError) {
            // Before the count, which a lost read would shorten for good.
            return [self reportWaitFault:error];
        }
        if (status != noErr && status != kAudioFileEndOfFileError) {
            if (error) {
                *error = VibeHandleError(status, [NSString stringWithFormat:@"Reading %@ failed (%d)", _url.lastPathComponent, (int)status]);
            }
            return NO;
        }
        _mpegReadFirst = _mpegNextPacket;
        _mpegReadCount = count; // fewer than asked at the file's end
        if (count == 0) {
            SInt64 packets = _mpegNextPacket; // a truncated or damaged file declares more than it holds
            if (_mpegPacketCount == kVibeMPEGPacketsUncounted) {
                UInt32 size = sizeof(packets);
                AudioFileGetProperty(_parser, kAudioFilePropertyAudioDataPacketCount, &size, &packets);
                [self settleMPEGPacketCount:packets when:@"where its reads reached the stream's end"];
            }
            else {
                _mpegPacketCount = packets;
            }
        }
    }
    // After the last packet the parser serves, the flush: the last decoded
    // header over silence drains the filterbank's delay, ending where Apple's
    // decode ends, which zero-fills it instead.
    BOOL flush = _mpegNextPacket == _mpegPacketCount;
    if (_mpegNextPacket > _mpegPacketCount || (flush && (_mpegPacketBytes == 0 || _mpeg->header[0] != 0xff))) {
        return YES;
    }
    if (flush) {
        // Written over the last packet in place: nothing reads it again,
        // since only a seek moves the cursor back and a seek drops the read.
        memcpy(_mpegPacket, _mpeg->header, sizeof(_mpeg->header));
        memset(_mpegPacket + sizeof(_mpeg->header), 0, _mpegPacketBytes - sizeof(_mpeg->header));
    } else {
        // TRAP: the parser leaves the descriptions zeroed for fixed-size
        // packets (MPEG in a WAV, which it opens only when every frame is one
        // size), so each would decode as an empty packet: silence.
        UInt32 index = (UInt32)(_mpegNextPacket - _mpegReadFirst);
        const AudioStreamPacketDescription *packet = &_mpegReadPackets[index];
        UInt32 bytes = _mpegBytesPerPacket ?: packet->mDataByteSize;
        _mpegPacket = _mpegRead + (_mpegBytesPerPacket ? (SInt64)index * _mpegBytesPerPacket : packet->mStartOffset);
        _mpegPacketBytes = bytes >= sizeof(_mpeg->header) ? bytes : 0;
    }
    SInt64 first = _mpegNextPacket * _mpegFramesPerPacket - _mpegSkip;
    _mpegNextPacket++;
    UInt32 channels = _processingFormat.channelCount;
    drmp3dec_frame_info info = {0};
    int frames = drmp3dec_decode_frame(_mpeg, _mpegPacket, (int)_mpegPacketBytes, _mpegPCM, &info);
    if (frames != (int)_mpegFramesPerPacket || info.channels != (int)channels) {
        // A frame whose reservoir bytes precede a seek's preroll, or a
        // damaged one: silence, keeping the timeline.
        memset(_mpegPCM, 0, (size_t)_mpegFramesPerPacket * channels * sizeof(float));
    } else {
        const float low = -kVibeMPEGSampleBound, high = kVibeMPEGSampleBound;
        vDSP_vclip(_mpegPCM, 1, &low, &high, _mpegPCM, 1, (vDSP_Length)frames * channels);
    }
    _mpegPCMFrames = flush ? _mpegDelay : _mpegFramesPerPacket;
    _mpegPCMOffset = (UInt32)MIN(MAX(0, _mpegPosition - first), (SInt64)_mpegPCMFrames);
    return YES;
}

@end
