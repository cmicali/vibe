//
//  AudioFileHandle.m
//  Vibe
//

#import "AudioFileHandleInternal.h"
#import "NetworkReadAheadMath.h"
#import "CloudFileMaterializer.h"
#import "NetworkReadAhead.h"
#if DEBUG
#import "AudioFileHandle+Debug.h"
#endif

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>

#include <errno.h>
#include <fcntl.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

// CoreAudio's Ogg reader (.ogg, .oga, .opus). The SDK names no constant.
static const AudioFileTypeID kVibeOggFileType = 'Oggf';

// Whether one of Vibe's own decoders takes this container and coding
// (openOwnDecoderInterleaved:). Such a file reaches the parser only after its
// decoder refused it, damaged past what that decoder plays, so playback
// refuses it too. Apple's decoders play only codings Vibe has no decoder for,
// GSM in a WAV among them, and containers it does not parse.
static BOOL VibeOwnDecoderCoding(AudioFileTypeID container, AudioFormatID format) {
    BOOL mpeg = format == kAudioFormatMPEGLayer1 || format == kAudioFormatMPEGLayer2 || format == kAudioFormatMPEGLayer3;
    BOOL pcm = format == kAudioFormatLinearPCM || format == kAudioFormatALaw || format == kAudioFormatULaw;
    switch (container) {
        case kAudioFileWAVEType: case kAudioFileRF64Type: case kAudioFileWave64Type:
            return mpeg || pcm || format == 0x6D730002 || format == 0x6D730011; // Microsoft's ADPCM and IMA's
        case kAudioFileAIFFType: case kAudioFileAIFCType:
            return pcm || format == kAudioFormatAppleIMA4;
        case kAudioFileFLACType:
            return format == kAudioFormatFLAC;
        case kAudioFileMP3Type: case kAudioFileMP2Type: case kAudioFileMP1Type:
            return mpeg;
        case kVibeOggFileType:
            return format == 'vorb';
        default:
            return NO;
    }
}

// The status of an interrupted read, seek or open (+isInterruption:).
static const OSStatus kVibeReadInterrupted = 'intr';

BOOL (^const VibeNeverWaitsForAStream)(void) = ^BOOL { return YES; };

// TRAP: a close can wait on a network share's server. The player, the voice
// bus, the open coordinator and the waveform loader each let a handle go
// where main waits: under a lock main takes, or on a queue main syncs onto.
// So an interruptible open's file closes here, never on the thread that let
// it go. Serial: a close stuck on a dead server holds the later ones, not a
// thread each.
static dispatch_queue_t VibeHandleCloseQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.vibe.audiofile.close",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

#if DEBUG
dispatch_queue_t VibeHandleDebugCloseQueue(void) {
    return VibeHandleCloseQueue();
}
#endif

// An ID3v2 syncsafe integer: 28 bits, 7 to a byte.
uint32_t VibeID3v2Syncsafe(const uint8_t bytes[4]) {
    return (uint32_t)(bytes[0] & 0x7F) << 21 | (bytes[1] & 0x7F) << 14 | (bytes[2] & 0x7F) << 7 | (bytes[3] & 0x7F);
}

// An ID3v2 tag's whole length from the file's first 10 bytes: the syncsafe
// size in bytes 6-9 excludes the header and a footer. 0 for no tag.
uint32_t VibeID3v2TagBytes(const uint8_t header[10]) {
    if (memcmp(header, "ID3", 3) != 0) {
        return 0;
    }
    return 10 + (header[5] & 0x10 ? 10 : 0) + VibeID3v2Syncsafe(header + 6);
}

@implementation AudioFileHandle {
    // What the parser's callbacks read, and dr_flac's and dr_wav's: valid from open until
    // dealloc has closed both. -1 once closed. A read-ahead holds none: it
    // reads through its availability. Nor does a QuickTime container (below):
    // its parser reads through its own descriptor.
    int _descriptor;
    // The last block a small read filled: its bytes from _readBlockStart,
    // _readBlockLength of them. Allocated by the first.
    uint8_t *_readBlock;
    SInt64 _readBlockStart;
    UInt32 _readBlockLength;
    UInt32 _bytesPerFrame; // of the processing format, per buffer
    BOOL _writing;
    uint8_t *_readAheadEnd; // the flags cell a read-ahead shares with its thread
    AudioFileTypeID _container; // the parser's kAudioFilePropertyFileFormat
    BOOL _holdsStream; // one of _availability's readers (holdStream)
    BOOL _interruptible; // opened with an `interrupted` block: dealloc closes the file on VibeHandleCloseQueue
    BOOL _parserOwnsFile; // opened by URL (the QuickTime road), so it holds a descriptor of its own
    _Atomic bool _readsInterrupted;
    _Atomic bool _waitingForBytes;
    BOOL (^_openInterrupted)(void); // the open's caller's, while it runs
    float _opusGain; // the Opus header's output gain as a factor, 0 for none
}

- (NSString *)decoderName {
    return _mpeg ? @"dr_mp3" : _flac ? @"dr_flac" : _wav ? @"dr_wav" : _vorbis ? @"libvorbis" : @"apple";
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

NSError *VibeHandleError(OSStatus status, NSString *description) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static NSError *VibeInterruptedError(NSURL *url) {
    return VibeHandleError(kVibeReadInterrupted, [NSString stringWithFormat:@"Reading %@ was interrupted", url.lastPathComponent]);
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
    // A read-ahead's open waits in slices. Every later interrupt comes with a
    // wake (interruptReads).
    BOOL slices = openInterrupted && !handle->_availability.partURL;
    CloudFileAvailabilityWait wait;
    do {
        // Asked only when the wait is about to block, so the flag is up for a
        // wait and never for bytes already readable.
        wait = [handle->_availability waitForBytesAt:(uint64_t)MAX(0, position)
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
        } deadline:slices ? [NSDate dateWithTimeIntervalSinceNow:kVibeReadAheadPollSeconds] : nil error:&error];
    } while (slices && wait == CloudFileAvailabilityInterrupted && !atomic_load(interrupted) && !openInterrupted());
    atomic_store(waiting, false);
    if (wait == CloudFileAvailabilityReady) {
        return YES;
    }
    handle->_waitError = wait == CloudFileAvailabilityFailed && error ? error : VibeInterruptedError(handle.url);
    return NO;
}

// YES once the whole file is readable: the transfer complete, or every byte
// written. Waiting, it waits as a read does and latches what ends the wait;
// otherwise it never waits and latches nothing.
BOOL VibeHandleAwaitWhole(AudioFileHandle *handle, BOOL wait) {
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
// latched on the handle, or a failed pread. A read-ahead's bytes all come
// from its blocks. One answering none is the end. A negative position fails
// as the pread would.
ssize_t VibeHandleFetch(AudioFileHandle *handle, SInt64 position, SInt64 requested, void *buffer, size_t capacity) {
    if (position < 0 && handle->_descriptor < 0) {
        return -1;
    }
    uint64_t fromWindow = 0;
    if (handle->_availability && !VibeHandleAwait(handle, position, requested, buffer, capacity, &fromWindow)) {
        return -1;
    }
    if (fromWindow || handle->_descriptor < 0) {
        return (ssize_t)fromWindow;
    }
    return VibePread(handle->_descriptor, buffer, capacity, position);
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
OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount) {
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

// dr_flac's, dr_wav's and vorbisfile's reads, at their own cursor. Each
// takes a short read for the end of the stream, so a read is filled
// but at the end. TRAP: a failed read ends it short too, so it is remembered
// here and reported by the read or seek it happened in: a read error must never
// become a clean end. A wait that answers no reads nothing: the decoder's
// position stays where the stream's is.
size_t VibeStreamRead(void *user, void *buffer, size_t count) {
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
static drflac_bool32 VibeStreamSeek(void *user, SInt64 offset, int origin) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    SInt64 base = origin == 0 ? 0 : origin == 1 ? handle->_streamCursor : handle->_size;
    SInt64 target;
    if (__builtin_add_overflow(base, offset, &target) || target < 0 || target > handle->_size) {
        return DRFLAC_FALSE;
    }
    handle->_streamCursor = target;
    return DRFLAC_TRUE;
}

drflac_bool32 VibeFLACSeek(void *user, int offset, drflac_seek_origin origin) {
    _Static_assert(DRFLAC_SEEK_SET == 0 && DRFLAC_SEEK_CUR == 1 && DRFLAC_SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, offset, (int)origin);
}

drwav_bool32 VibeWAVSeek(void *user, int offset, drwav_seek_origin origin) {
    _Static_assert(DRWAV_SEEK_SET == 0 && DRWAV_SEEK_CUR == 1 && DRWAV_SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, offset, (int)origin);
}

// One tell for both: their tell procs are the same type.
drflac_bool32 VibeStreamTell(void *user, drflac_int64 *cursor) {
    *cursor = ((__bridge AudioFileHandle *)user)->_streamCursor;
    return DRFLAC_TRUE;
}

// vorbisfile's reads. It takes no bytes with errno set for an error. A lost
// or failed read sets it, and a clean end clears it.
size_t VibeVorbisRead(void *buffer, size_t size, size_t count, void *user) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    size_t got = VibeStreamRead(user, buffer, size * count);
    errno = got == 0 && (handle->_streamReadFailed || handle->_waitError) ? EIO : 0;
    return size ? got / size : 0;
}

int VibeVorbisSeek(void *user, ogg_int64_t offset, int whence) {
    _Static_assert(SEEK_SET == 0 && SEEK_CUR == 1 && SEEK_END == 2, "VibeStreamSeek's origins");
    return VibeStreamSeek(user, offset, whence) ? 0 : -1;
}

long VibeVorbisTell(void *user) {
    return (long)((__bridge AudioFileHandle *)user)->_streamCursor;
}

// The type CoreAudio registers for an extension: the hint AudioFileOpenURL
// takes from a path. 0 when none is registered.
AudioFileTypeID VibeFileTypeForExtension(NSString *extension) {
    // A strong local, not a bridged temporary: ARC frees that at the end of
    // its statement, leaving the lookup below reading freed memory.
    NSString *lowered = extension.lowercaseString;
    if (lowered.length == 0) {
        return 0;
    }
    // Every open asks. CoreAudio's lookup was a quarter of an MP3 open's cost.
    // Its answer does not change while the app runs.
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSString *, NSNumber *> *known;
    os_unfair_lock_lock(&lock);
    NSNumber *remembered = known[lowered];
    os_unfair_lock_unlock(&lock);
    if (remembered != nil) {
        return remembered.unsignedIntValue;
    }
    CFStringRef key = (__bridge CFStringRef)lowered;
    UInt32 size = 0;
    AudioFileTypeID types[8] = {0};
    if (AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size) == noErr
            && size >= sizeof(AudioFileTypeID)) {
        size = MIN(size, (UInt32)sizeof(types));
        if (AudioFileGetGlobalInfo(kAudioFileGlobalInfo_TypesForExtension, sizeof(key), &key, &size, types) != noErr) {
            types[0] = 0;
        }
    }
    os_unfair_lock_lock(&lock);
    known = known ?: [NSMutableDictionary dictionary];
    known[lowered] = @(types[0]);
    os_unfair_lock_unlock(&lock);
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

// RFC 7845 section 5.1: an Ogg Opus file's header carries an output gain,
// and a player must apply it. Apple's decoder ignores it (macOS 27). The
// parser serves the header, the OpusHead packet, as the file's magic cookie.
// The gain is Q7.8 dB at byte 16. Answers it as a factor, or 0 when it is
// 0 dB or the cookie is no OpusHead.
static float VibeOpusOutputGain(AudioFileID parser) {
    UInt32 size = 0;
    if (AudioFileGetPropertyInfo(parser, kAudioFilePropertyMagicCookieData, &size, NULL) != noErr || size < 19) {
        return 0;
    }
    NSMutableData *cookie = [NSMutableData dataWithLength:size];
    const uint8_t *head = cookie.bytes;
    if (AudioFileGetProperty(parser, kAudioFilePropertyMagicCookieData, &size, cookie.mutableBytes) != noErr
            || size < 19 || memcmp(head, "OpusHead", 8) != 0) {
        return 0;
    }
    int16_t gain = (int16_t)(head[16] | head[17] << 8);
    return gain ? powf(10, gain / 256.0f / 20) : 0;
}

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

// A read-ahead also stops fetching ahead while reads are interrupted. A voice
// skipped away from then stops pulling its file over the network.
- (void)interruptReads {
    atomic_store(&_readsInterrupted, true);
    _availability.readAheadPaused = YES;
    [_availability wakeWaiters];
}

- (void)allowReads {
    atomic_store(&_readsInterrupted, false);
    _availability.readAheadPaused = NO;
}

- (BOOL)waitsForBytes {
    return _availability != nil;
}

- (BOOL)waitingForBytes {
    return atomic_load(&_waitingForBytes);
}

- (uint64_t)bytesWritten {
    return _availability ? _availability.progressBytes : (uint64_t)MAX(0, _size);
}

- (void)holdStream {
    if (_availability.partURL && !_holdsStream) {
        _holdsStream = YES;
        [_availability addReader]; // removed by dealloc
    } else if (_availability && _readAheadEnd) {
        double rate = _processingFormat.sampleRate;
        double seconds = rate > 0 ? (double)self.length / rate : 0;
        VibeNetworkReadAheadSizePlay(_availability, _readAheadEnd, VibeReadAheadSpanBytes((uint64_t)MAX(0, _size), seconds));
    }
}

- (instancetype)initParserForReading:(NSURL *)url interrupted:(BOOL (^)(void))interrupted error:(NSError **)error {
    self = [super init];
    if (!self || ![self openFile:url interrupted:interrupted error:error]) {
        return nil;
    }
    return [self openParserWithError:error];
}

// The file the reads go to: a descriptor, a transfer's part file, or a
// read-ahead. Nil, with why, when there is none.
- (instancetype)openFile:(NSURL *)url interrupted:(BOOL (^)(void))interrupted error:(NSError **)error {
    _url = url;
    _descriptor = -1;
    _openInterrupted = interrupted;
    _interruptible = interrupted != nil;
    NSString *name = url.lastPathComponent;
    if (!url.isFileURL) {
        return [self failWithError:error status:kAudioFileUnsupportedFileTypeError
                       description:[NSString stringWithFormat:@"%@ is not a file", name]];
    }
    _availability = [CloudFileMaterializer availabilityForURL:url];
    NSString *mount = nil;
    if (!_availability && interrupted && interrupted != VibeNeverWaitsForAStream && VibeNetworkReadAheadApplies(url, &mount)) {
        if (!VibeNetworkReadAheadAwaitRoom(name, interrupted)) {
            _waitError = VibeInterruptedError(url);
            return [self failWithError:error status:noErr description:@""];
        }
        _availability = VibeNetworkReadAheadStart(url, mount, &_readAheadEnd);
        // The thread's open and its first block, waited for as any read is.
        if (!VibeHandleAwait(self, 0, 1, NULL, 0, NULL)) {
            return [self failWithError:error status:noErr description:@""];
        }
        _size = (SInt64)_availability.size;
    } else {
        // TRAP: nonblocking. A FIFO with no writer then returns at once for
        // fstat to refuse. It never parks an uncancellable open worker. A
        // regular file's pread ignores the flag. The read-ahead's thread opens
        // with the same flags for the same reason.
        int flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC;
        _descriptor = open((_availability ? _availability.partURL : url).fileSystemRepresentation, flags);
        if (_descriptor < 0 && _availability && errno == ENOENT) {
            // TRAP: the transfer can finish and rename its part over url
            // between the lookup and the open. Once it has finished, url is
            // the whole file.
            if (!VibeHandleAwaitWhole(self, YES)) {
                return [self failWithError:error status:noErr description:@""];
            }
            _availability = nil;
            _descriptor = open(url.fileSystemRepresentation, flags);
        }
        // A part file is the size it will have, not the size it has.
        struct stat info;
        NSError *failure = _descriptor < 0 ? VibeCouldNotOpenError(name, errno)
                : fstat(_descriptor, &info) != 0 || !S_ISREG(info.st_mode)
                        || (_availability ? _availability.size : (uint64_t)info.st_size) == 0 ? VibeNoAudioError(name) : nil;
        if (failure) {
            if (error) {
                *error = failure;
            }
            return nil;
        }
        _size = _availability ? (SInt64)_availability.size : info.st_size;
    }
    return self;
}

// CoreAudio's parser over the file's reads, which answers its facts.
- (instancetype)openParserWithError:(NSError **)error {
    NSURL *url = _url;
    NSString *name = url.lastPathComponent;
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
    if (status != noErr && !_availability.partURL && !_waitError
            && (status == kAudio_UnimplementedError || hinted == kAudio_UnimplementedError)) {
        // TRAP: CoreAudio's QuickTime reader (MooV, Voice Memos' .qta) has no
        // callback open and answers kAudio_UnimplementedError, so this parse
        // goes through the URL. Safe: the URL open leaks only on the empty
        // files and directories already refused above. iOS has no such
        // reader. A transfer's URL is not yet the file. A transfer never
        // takes this road. A read-ahead's URL is the file. Its availability
        // is finished first, and that ends its thread.
        [self closeParser];
        if (_readAheadEnd) {
            VibeNetworkReadAheadClose(_availability, url);
            _availability = nil;
        }
        if (_descriptor >= 0) {
            close(_descriptor);
            _descriptor = -1;
        }
        status = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, hint, &_parser);
        _parserOwnsFile = YES;
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
    // Opus reads in full on both platforms. Vorbis comes here only when
    // libvorbis refused it.
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

// TRAP: CoreAudio's CAF info parser (parseInfoStringsChunk) loops over the
// info chunk's entry count without checking it against the chunk. A forged
// count of 0xF90000EE never returns, and afinfo hangs the same way. It held a
// metadata worker forever and stopped the folder's sweep. So the info
// dictionary is readable only when this walk finds an info chunk inside the
// file whose body could hold its count. Each entry is two NUL-terminated
// strings, so it takes at least two bytes. A streamed CAF's data chunk
// declares size -1 and stops the walk, so an info chunk after it is dropped.
// Asked, not walked at open: a playback open never waits for those bytes.
- (BOOL)infoDictionaryReadable {
    if (_container != kAudioFileCAFType) {
        return YES;
    }
    void *context = (__bridge void *)self;
    uint64_t fileSize = (uint64_t)MAX(0, _size);
    uint64_t at = 8; // 'caff', version, flags
    uint8_t header[12];
    UInt32 got = 0;
    while (at + sizeof header <= fileSize
            && VibeHandleRead(context, (SInt64)at, sizeof header, header, &got) == noErr && got == sizeof header) {
        uint64_t size = 0;
        for (size_t i = 4; i < 12; i++) size = size << 8 | header[i];
        uint64_t body = at + sizeof header;
        if (size > fileSize - body) return NO; // past the file, or the data chunk's -1
        if (memcmp(header, "info", 4) == 0) {
            uint8_t count[4];
            if (size < 4 || VibeHandleRead(context, (SInt64)body, 4, count, &got) != noErr || got != 4) return NO;
            uint32_t entries = (uint32_t)count[0] << 24 | (uint32_t)count[1] << 16 | (uint32_t)count[2] << 8 | count[3];
            return entries <= (size - 4) / 2;
        }
        at = body + size;
    }
    return NO;
}

- (instancetype)initForReading:(NSURL *)url interleaved:(BOOL)interleaved interrupted:(BOOL (^)(void))interrupted
                         error:(NSError **)error {
    self = [super init];
    if (!self || ![self openFile:url interrupted:interrupted error:error]) {
        return nil;
    }
    NSString *name = url.lastPathComponent;
    // FLAC, WAV, AIFF, Ogg Vorbis and MPEG go to the decoders that parse them.
    // Those answer the facts too. CoreAudio's parser opens only what none of
    // them takes.
    // TRAP: iOS's Ogg reader refuses Vorbis, and macOS's decoder drops
    // each Vorbis file's first 128 frames (macOS 27,
    // docs/future/audio-quality-gaps.md).
    if ([self openOwnDecoderInterleaved:interleaved] || _waitError) {
        return [self openedWithError:error];
    }
    if (![self openParserWithError:error]) {
        return nil;
    }
    // Again: the parser's open let it go, and the decoders' opens read too.
    _openInterrupted = interrupted;
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
    if (VibeOwnDecoderCoding(_container, fileDescription.mFormatID)) {
        return [self failWithError:error status:kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ is damaged past what Vibe's decoder plays", name]];
    }
    if (![self takeFileFormat:fileDescription layout:VibeFileChannelLayout(_codec) interleaved:interleaved]) {
        return [self failWithError:error status:kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ has a format this player cannot decode", name]];
    }
    UInt32 formatID = fileDescription.mFormatID;
    status = [self decodeToProcessingFormatInLayout:_processingFormat.channelLayout];
    if (status != noErr) {
        // What AVAudioFile reported for a file its decoder cannot produce:
        // an MP2 on a platform without the codec opens and fails here.
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"No decoder for %@'s format (%d)", name, (int)status]];
    }
    _bytesPerFrame = _processingFormat.streamDescription->mBytesPerFrame;
    if (_container == kVibeOggFileType && formatID == kAudioFormatOpus) {
        _opusGain = VibeOpusOutputGain(_parser);
    }
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
    // A damaged header can state a negative length.
    _length = MAX(0, length);
    return [self openedWithError:error];
}

// The file's format and the float32 one its reads decode to. The processing
// format carries the file's layout when it states one. A wider file that
// states none gets a discrete layout, since a converter between more than two
// channels is refused without one. NO when either format cannot be made.
- (BOOL)takeFileFormat:(AudioStreamBasicDescription)description layout:(AVAudioChannelLayout *)layout
           interleaved:(BOOL)interleaved {
    if (!layout && description.mChannelsPerFrame > 2) {
        layout = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame];
    }
    _fileFormat = [[AVAudioFormat alloc] initWithStreamDescription:&description channelLayout:layout];
    _processingFormat = layout
            ? [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:description.mSampleRate interleaved:interleaved channelLayout:layout]
            : [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:description.mSampleRate
                                                 channels:description.mChannelsPerFrame interleaved:interleaved];
    return _fileFormat && _processingFormat;
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
// decoders made of the reads it lost. A read-ahead's reader is then placed at
// the head. The open may have read the tail last, and the thread fetches
// ahead of the reader's position.
- (instancetype)openedWithError:(NSError **)error {
    _openInterrupted = nil;
    if (_waitError) {
        return [self failWithError:error status:noErr description:@""];
    }
    [_availability noteReaderPosition:0];
    return self;
}

- (void)closeParser {
    if (_parser) {
        AudioFileClose(_parser);
        _parser = NULL;
    }
}

// A read-ahead's availability first, with a real error. That ends its
// thread once its read returns. Then the decoder before the parser, the
// parser before the descriptor its callbacks read. A parser opened by URL
// reads through a descriptor of its own, so it closes with the file.
- (void)dealloc {
    if (_readAheadEnd) {
        VibeNetworkReadAheadHandleGone(_availability, _url, _readAheadEnd);
    }
    if (_codec) {
        ExtAudioFileDispose(_codec);
        _codec = NULL;
    }
    free(_readBlock);
    free(_mpeg);
    free(_mpegPacket);
    free(_mpegPCM);
    free(_mpegOffsets);
    free(_mpegSizes);
    [self closeStreamDecoder];
    AudioFileID parser = _parserOwnsFile ? _parser : NULL;
    if (!parser) {
        [self closeParser];
    }
    int descriptor = _descriptor;
    if (parser || descriptor >= 0) {
        dispatch_block_t closeFile = ^{
            if (parser) {
                AudioFileClose(parser);
            }
            if (descriptor >= 0) {
                close(descriptor);
            }
        };
        if (_interruptible) {
            dispatch_async(VibeHandleCloseQueue(), closeFile);
        } else {
            closeFile();
        }
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
    if (_vorbis) {
        return _vorbisPosition;
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
        return [self seekMPEGToFrame:frame error:error];
    }
    OSStatus status;
    if (_flac || _wav || _vorbis) {
        // Each lands at the end for a target past it, where reads return
        // nothing, as Apple's does. dr_flac and dr_wav clamp it themselves.
        // vorbisfile refuses it, so it is clamped here. vorbisfile's seek finds
        // its page again from the bytes. An interrupted read leaves nothing.
        SInt64 target = MAX(0, frame);
        BOOL landed = (_flac ? drflac_seek_to_pcm_frame(_flac, (drflac_uint64)target)
                       : _wav ? drwav_seek_to_pcm_frame(_wav, (drwav_uint64)target)
                       : ov_pcm_seek(_vorbis, MIN(target, _length)) == 0) && !_streamReadFailed;
        if (landed && _vorbis) {
            _vorbisPosition = MIN(target, _length);
        }
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
    if (_flac || _wav || _vorbis) {
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
        if (_opusGain) {
            const float low = -kVibeDecodeSampleBound, high = kVibeDecodeSampleBound;
            for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
                float *samples = list->mBuffers[b].mData;
                vDSP_Length count = list->mBuffers[b].mDataByteSize / sizeof(float);
                vDSP_vsmul(samples, 1, &_opusGain, samples, 1, count);
                vDSP_vclip(samples, 1, &low, &high, samples, 1, count);
            }
        }
        total += frames;
    }
    buffer.frameLength = total;
    return YES;
}

@end
