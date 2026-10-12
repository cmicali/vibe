//
//  AudioFileHandle.m
//  Vibe
//

#import "AudioFileHandleInternal.h"
#import "CloudFileMaterializer.h"
#import "NetworkReadAhead.h"

#import <AudioToolbox/AudioToolbox.h>

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

static atomic_bool sAppleMPEGDecoder;

// CoreAudio's Ogg reader (.ogg, .oga, .opus). The SDK names no constant.
static const AudioFileTypeID kVibeOggFileType = 'Oggf';

// The status of an interrupted read, seek or open (+isInterruption:).
static const OSStatus kVibeReadInterrupted = 'intr';

BOOL (^const VibeNeverWaitsForAStream)(void) = ^BOOL { return YES; };

// An ID3v2 tag's whole length from the file's first 10 bytes: the syncsafe
// size in bytes 6-9 excludes the header and a footer. 0 for no tag.
uint32_t VibeID3v2TagBytes(const uint8_t header[10]) {
    if (memcmp(header, "ID3", 3) != 0) {
        return 0;
    }
    return 10 + (header[5] & 0x10 ? 10 : 0)
            + ((header[6] & 0x7F) << 21 | (header[7] & 0x7F) << 14 | (header[8] & 0x7F) << 7 | (header[9] & 0x7F));
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
    BOOL _mpegChoiceApplies; // an MPEG file
    BOOL _openedUnderApple;  // the choice when it opened
    uint8_t *_readAheadEnd; // the flags cell a read-ahead shares with its thread
    BOOL _holdsStream; // one of _availability's readers (holdStream)
    _Atomic bool _readsInterrupted;
    _Atomic bool _waitingForBytes;
    BOOL (^_openInterrupted)(void); // the open's caller's, while it runs
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
BOOL VibeHandleAwait(AudioFileHandle *handle, SInt64 position, SInt64 count,
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
        } deadline:slices ? [NSDate dateWithTimeIntervalSinceNow:kVibeReadAheadOpenPollSeconds] : nil error:&error];
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
static ssize_t VibeHandleFetch(AudioFileHandle *handle, SInt64 position, SInt64 requested, void *buffer, size_t capacity) {
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

// dr_flac's and dr_wav's reads, over the parser's descriptor at their own
// cursor. Both take a short read for the end of the stream, so a read is filled
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
    // Both read through the callbacks. Neither runs after the QuickTime road.
    if ((_descriptor >= 0 || _availability) && ((formatID == kAudioFormatFLAC && [self openFLAC])
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
// parser before the descriptor its callbacks read.
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
        return [self seekMPEGToFrame:frame error:error];
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

@end
