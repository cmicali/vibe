//
//  AudioFileHandle.m
//  Vibe
//

#import "AudioFileHandle.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>

#include "dr_flac/dr_flac.h"
#include "dr_mp3/dr_mp3.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>

static atomic_bool sAppleMPEGDecoder;

// Packets decoded and dropped before a seek's own: enough to refill the bit
// reservoir (511 bytes back at most, seven frames at MPEG-1's lowest bitrate)
// and the filterbank's history, so a seek decodes exactly what reading from
// the start would.
static const SInt64 kVibeMPEGSeekPrerollPackets = 10;

// Packets asked of the parser at once, sparing it about four small reads
// per MP3 frame, which were a tenth of the whole decode's time.
enum { kVibeMPEGReadPackets = 16 };

// Frames dr_flac decodes at once into the scratch a planar read splits.
enum { kVibeFLACReadFrames = 4096 };

@implementation AudioFileHandle {
    // The callback context: valid from open until AudioFileClose returns in
    // dealloc. -1 once closed, or for a QuickTime container (below), whose
    // parser reads through its own descriptor.
    int _descriptor;
    SInt64 _size;
    AudioFileID _parser;
    ExtAudioFileRef _codec; // NULL while dr_mp3 decodes
    UInt32 _bytesPerFrame; // of the processing format, per buffer
    BOOL _writing;
    BOOL _mpegChoiceApplies; // an MPEG file read as float32
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
    SInt64 _mpegNextPacket;
    SInt64 _mpegPosition; // logical frame the next read delivers
    float *_mpegPCM;      // one packet's frames, interleaved
    UInt32 _mpegPCMFrames;
    UInt32 _mpegPCMOffset;
    // dr_flac's decode: the stream read through the descriptor at a cursor of
    // its own. _flacPosition is the logical frame the next read delivers.
    drflac *_flac;
    SInt64 _flacCursor;
    SInt64 _flacPosition;
    BOOL _flacReadFailed; // a pread failed, which dr_flac cannot tell from the end
    float *_flacPCM;      // kVibeFLACReadFrames frames, interleaved, for a planar read
}

+ (BOOL)appleMPEGDecoder {
    return atomic_load(&sAppleMPEGDecoder);
}

+ (void)setAppleMPEGDecoder:(BOOL)appleMPEGDecoder {
    atomic_store(&sAppleMPEGDecoder, appleMPEGDecoder);
}

- (NSString *)decoderName {
    return _mpeg ? @"dr_mp3" : _flac ? @"dr_flac" : @"apple";
}

- (BOOL)decoderChoiceIsStale {
    return _mpegChoiceApplies && _openedUnderApple != atomic_load(&sAppleMPEGDecoder);
}

// Short reads answered as such, and a read at or past EOF as the end-of-file
// status: the shape CoreAudio's own file reader gives its parsers, which keeps
// the verdicts AudioFileOpenURL would give.
static OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)clientData;
    ssize_t got = pread(handle->_descriptor, buffer, requestCount, position);
    if (got < 0) {
        *actualCount = 0;
        return kAudioFilePositionError;
    }
    *actualCount = (UInt32)got;
    return (got == 0 && requestCount > 0) ? kAudioFileEndOfFileError : noErr;
}

static SInt64 VibeHandleSize(void *clientData) {
    return ((__bridge AudioFileHandle *)clientData)->_size;
}

// dr_flac's reads, over the parser's descriptor at its own cursor. TRAP: a
// failed read answers no bytes, which dr_flac takes for the end of the stream,
// so it is remembered here and reported by the read or seek it happened in:
// a read error must never become a clean end.
static size_t VibeFLACRead(void *user, void *buffer, size_t count) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    ssize_t got = pread(handle->_descriptor, buffer, count, handle->_flacCursor);
    if (got < 0) {
        handle->_flacReadFailed = YES;
        return 0;
    }
    handle->_flacCursor += got;
    return (size_t)got;
}

static drflac_bool32 VibeFLACSeek(void *user, int offset, drflac_seek_origin origin) {
    AudioFileHandle *handle = (__bridge AudioFileHandle *)user;
    SInt64 base = origin == DRFLAC_SEEK_SET ? 0 : origin == DRFLAC_SEEK_CUR ? handle->_flacCursor : handle->_size;
    if (base + offset < 0) {
        return DRFLAC_FALSE;
    }
    handle->_flacCursor = base + offset;
    return DRFLAC_TRUE;
}

static drflac_bool32 VibeFLACTell(void *user, drflac_int64 *cursor) {
    *cursor = ((__bridge AudioFileHandle *)user)->_flacCursor;
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

static NSError *VibeHandleError(OSStatus status, NSString *description) {
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:status
                           userInfo:@{NSLocalizedDescriptionKey: description}];
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
    unsigned char head[16] = {0};
    ssize_t got = pread(descriptor, head, sizeof(head), 0);
    NSString *start;
    if (got >= 10 && head[0] == 'I' && head[1] == 'D' && head[2] == '3') {
        // ID3v2: a syncsafe size in bytes 6-9, excluding the 10-byte header.
        uint32_t tag = ((head[6] & 0x7f) << 21) | ((head[7] & 0x7f) << 14) | ((head[8] & 0x7f) << 7) | (head[9] & 0x7f);
        start = [NSString stringWithFormat:@"an ID3v2.%u tag of %u bytes", head[3], tag + 10];
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
    return [self initForReading:url commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
}

- (instancetype)initForReading:(NSURL *)url commonFormat:(AVAudioCommonFormat)format interleaved:(BOOL)interleaved
                         error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }
    _url = url;
    _descriptor = -1;
    NSString *name = url.lastPathComponent;
    if (!url.isFileURL) {
        return [self failWithError:error status:kAudioFileUnsupportedFileTypeError
                       description:[NSString stringWithFormat:@"%@ is not a file", name]];
    }
    // TRAP: nonblocking, so a FIFO with no writer returns at once for fstat
    // to refuse, instead of parking an uncancellable open worker. A regular
    // file's pread ignores the flag.
    _descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (_descriptor < 0) {
        int code = errno;
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not open %@: %s", name, strerror(code)]}];
        }
        return nil;
    }
    struct stat info;
    if (fstat(_descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size == 0) {
        return [self failWithError:error status:kAudioFileUnsupportedFileTypeError
                       description:[NSString stringWithFormat:@"%@ holds no audio data", name]];
    }
    _size = info.st_size;
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
    if (status != noErr && (status == kAudio_UnimplementedError || hinted == kAudio_UnimplementedError)) {
        // TRAP: CoreAudio's QuickTime reader (MooV, Voice Memos' .qta) has no
        // callback open and answers kAudio_UnimplementedError, so this parse
        // goes through the URL. Safe: the URL open leaks only on the empty
        // files and directories already refused above. iOS has no such
        // reader.
        [self closeParser];
        close(_descriptor);
        _descriptor = -1;
        status = AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, hint, &_parser);
    }
    if (status != noErr) {
#if VIBE_VERBOSE_LOGGING
        if (_descriptor >= 0) {
            VibeLogOpenRefusal(url, _descriptor, _size, hint, hinted, status);
        }
#endif
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"CoreAudio refused %@ (%d)", name, (int)status]];
    }
    status = ExtAudioFileWrapAudioFileID(_parser, false, &_codec);
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
            ? [[AVAudioFormat alloc] initWithCommonFormat:format sampleRate:fileDescription.mSampleRate interleaved:interleaved channelLayout:layout]
            : [[AVAudioFormat alloc] initWithCommonFormat:format sampleRate:fileDescription.mSampleRate
                                                 channels:fileDescription.mChannelsPerFrame interleaved:interleaved];
    if (!_fileFormat || !_processingFormat) {
        return [self failWithError:error status:kAudioFileUnsupportedDataFormatError
                       description:[NSString stringWithFormat:@"%@ has a format this player cannot decode", name]];
    }
    UInt32 formatID = fileDescription.mFormatID;
    _mpegChoiceApplies = format == AVAudioPCMFormatFloat32
            && (formatID == kAudioFormatMPEGLayer1 || formatID == kAudioFormatMPEGLayer2 || formatID == kAudioFormatMPEGLayer3);
    _openedUnderApple = atomic_load(&sAppleMPEGDecoder);
    if (_mpegChoiceApplies && !_openedUnderApple && [self openMPEGWithDescription:fileDescription]) {
        return self;
    }
    // Before the client format below, which Apple's FLAC codec refuses for
    // some legal streams dr_flac plays: block sizes of 16 and 65535, rates
    // past 655 kHz, 32-bit samples.
    if (format == AVAudioPCMFormatFloat32 && formatID == kAudioFormatFLAC && [self openFLAC]) {
        return self;
    }
    const AudioStreamBasicDescription *client = _processingFormat.streamDescription;
    status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientDataFormat, sizeof(*client), client);
    if (status == noErr && layout) {
        status = ExtAudioFileSetProperty(_codec, kExtAudioFileProperty_ClientChannelLayout, VibeLayoutSize(layout.layout), layout.layout);
    }
    if (status != noErr) {
        // What AVAudioFile reported for a file its decoder cannot produce:
        // an MP2 on a platform without the codec opens and fails here.
        return [self failWithError:error status:status
                       description:[NSString stringWithFormat:@"No decoder for %@'s format (%d)", name, (int)status]];
    }
    _bytesPerFrame = client->mBytesPerFrame;
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
    return self;
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

// Takes the file over for dr_mp3, or leaves it to ExtAudioFile when the
// parser cannot serve its packets. ExtAudioFile answers the length, priming
// and padding excluded, exactly as for its own decode, and is disposed without
// decoding; the parser answers the priming and serves the packets.
- (BOOL)openMPEGWithDescription:(AudioStreamBasicDescription)description {
    SInt64 length = 0;
    UInt64 packets = 0;
    UInt32 upperBound = 0;
    UInt32 lengthSize = sizeof(length), packetsSize = sizeof(packets), boundSize = sizeof(upperBound);
    if (description.mFramesPerPacket == 0 || description.mFramesPerPacket > DRMP3_MAX_PCM_FRAMES_PER_MP3_FRAME
            || description.mChannelsPerFrame > 2
            || ExtAudioFileGetProperty(_codec, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length) != noErr
            || AudioFileGetProperty(_parser, kAudioFilePropertyAudioDataPacketCount, &packetsSize, &packets) != noErr
            || AudioFileGetProperty(_parser, kAudioFilePropertyPacketSizeUpperBound, &boundSize, &upperBound) != noErr) {
        return NO;
    }
    // An untagged file has no packet table, and no priming.
    AudioFilePacketTableInfo table = {0};
    UInt32 size = sizeof(table);
    AudioFileGetProperty(_parser, kAudioFilePropertyPacketTableInfo, &size, &table);
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

// Takes the file over for dr_flac, or leaves it to ExtAudioFile when dr_flac
// cannot open it or reads it differently. ExtAudioFile answers the length, as
// for its own decode, and is disposed without decoding; dr_flac reads the
// stream through the descriptor itself, so the parser is closed too.
- (BOOL)openFLAC {
    SInt64 length = 0;
    UInt32 size = sizeof(length);
    if (_descriptor < 0 || ExtAudioFileGetProperty(_codec, kExtAudioFileProperty_FileLengthFrames, &size, &length) != noErr) {
        return NO;
    }
    _flac = drflac_open(VibeFLACRead, VibeFLACSeek, VibeFLACTell, (__bridge void *)self, NULL);
    if (!_flac || _flacReadFailed || _flac->channels != _processingFormat.channelCount
            || _flac->sampleRate != _processingFormat.sampleRate) {
        if (_flac) {
            drflac_close(_flac);
            _flac = NULL;
        }
        return NO;
    }
    ExtAudioFileDispose(_codec);
    _codec = NULL;
    [self closeParser];
    _flacPCM = malloc(sizeof(float) * kVibeFLACReadFrames * _flac->channels);
    _length = MAX(0, length);
    return YES;
}

- (instancetype)failWithError:(NSError **)error status:(OSStatus)status description:(NSString *)description {
    if (error) {
        *error = VibeHandleError(status, description);
    }
    // dealloc releases the descriptor and whatever parser was left.
    return nil;
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
    free(_mpeg);
    free(_mpegRead);
    free(_mpegPCM);
    if (_flac) {
        drflac_close(_flac);
        _flac = NULL;
    }
    free(_flacPCM);
    [self closeParser];
    if (_descriptor >= 0) {
        close(_descriptor);
        _descriptor = -1;
    }
}

#pragma mark - The cursor

- (AVAudioFramePosition)framePosition {
    if (_mpeg) {
        return _mpegPosition;
    }
    if (_flac) {
        return _flacPosition;
    }
    SInt64 position = 0;
    return ExtAudioFileTell(_codec, &position) == noErr ? position : 0;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
    if (_mpeg) {
        // A fresh decoder a preroll before the target; the reads drop the
        // preroll's frames, as they drop the priming.
        _mpegPosition = MIN(MAX(0, frame), _length);
        SInt64 packet = (_mpegPosition + _mpegSkip) / _mpegFramesPerPacket;
        _mpegNextPacket = MAX(0, packet - kVibeMPEGSeekPrerollPackets);
        memset(_mpeg, 0, sizeof(*_mpeg));
        _mpegPCMFrames = _mpegPCMOffset = _mpegPacketBytes = _mpegReadCount = 0;
        return YES;
    }
    if (_flac) {
        // A seek past the frames a truncated file holds lands at its end,
        // where reads return nothing, as Apple's does.
        SInt64 target = _length > 0 ? MIN(MAX(0, frame), _length) : MAX(0, frame);
        BOOL landed = drflac_seek_to_pcm_frame(_flac, (drflac_uint64)target) && !_flacReadFailed;
        if (!landed) {
            if (error) {
                *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Seeking %@ failed", _url.lastPathComponent]);
            }
            return NO;
        }
        _flacPosition = target;
        return YES;
    }
    OSStatus status = !_codec || _writing ? kAudio_ParamError : ExtAudioFileSeek(_codec, MAX(0, frame));
    if (status != noErr && error) {
        *error = VibeHandleError(status, [NSString stringWithFormat:@"Seeking %@ failed (%d)", _url.lastPathComponent, (int)status]);
    }
    return status == noErr;
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
    AVAudioFrameCount wanted = MIN(frameCount, buffer.frameCapacity);
    if (_mpeg) {
        return [self readMPEGIntoBuffer:buffer frameCount:wanted error:error];
    }
    if (_flac) {
        return [self readFLACIntoBuffer:buffer frameCount:wanted error:error];
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
        if (status != noErr) {
            buffer.frameLength = total;
            if (error) {
                *error = VibeHandleError(status, [NSString stringWithFormat:@"Reading %@ failed (%d)", _url.lastPathComponent, (int)status]);
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
    UInt32 channels = _processingFormat.channelCount;
    BOOL interleaved = _processingFormat.isInterleaved;
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount total = 0;
    while (total < wanted && _mpegPosition < _length) {
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
        UInt32 frames = (UInt32)MIN((SInt64)MIN(_mpegPCMFrames - _mpegPCMOffset, wanted - total), _length - _mpegPosition);
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
    buffer.frameLength = total;
    return YES;
}

// Reads stop at the declared length, or for a file whose STREAMINFO declares
// none (0), where its frames run out.
- (BOOL)readFLACIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    UInt32 channels = _processingFormat.channelCount;
    BOOL direct = _processingFormat.isInterleaved || channels == 1;
    float *const *planes = buffer.floatChannelData;
    AVAudioFrameCount total = 0;
    while (total < wanted) {
        SInt64 frames = MIN(wanted - total, (AVAudioFrameCount)kVibeFLACReadFrames);
        if (_length > 0) {
            frames = MIN(frames, _length - _flacPosition);
        }
        if (frames <= 0) {
            break;
        }
        float *into = direct ? planes[0] + (size_t)total * channels : _flacPCM;
        UInt32 got = (UInt32)drflac_read_pcm_frames_f32(_flac, (drflac_uint64)frames, into);
        if (_flacReadFailed) {
            buffer.frameLength = total;
            if (error) {
                *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Reading %@ failed", _url.lastPathComponent]);
            }
            return NO;
        }
        if (got == 0) {
            break; // the end
        }
        if (!direct) {
            VibeDeinterleave(_flacPCM, channels, planes, total, got);
        }
        _flacPosition += got;
        total += got;
    }
    buffer.frameLength = total;
    return YES;
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
        if (status != noErr && status != kAudioFileEndOfFileError) {
            if (error) {
                *error = VibeHandleError(status, [NSString stringWithFormat:@"Reading %@ failed (%d)", _url.lastPathComponent, (int)status]);
            }
            return NO;
        }
        _mpegReadFirst = _mpegNextPacket;
        _mpegReadCount = count; // fewer than asked at the file's end
        if (count == 0) {
            _mpegPacketCount = _mpegNextPacket; // a truncated or damaged file declares more than it holds
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
        // TRAP: a fresh decoder syncs only by finding the next frame's header
        // after this one, which a single packet lacks, and then scans the
        // payload for a false one. The parser has already framed the packet,
        // so its header is handed over as the one to follow.
        if (_mpeg->header[0] != 0xff && _mpegPacketBytes) {
            memcpy(_mpeg->header, _mpegPacket, sizeof(_mpeg->header));
        }
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
    }
    _mpegPCMFrames = flush ? _mpegDelay : _mpegFramesPerPacket;
    _mpegPCMOffset = (UInt32)MIN(MAX(0, _mpegPosition - first), (SInt64)_mpegPCMFrames);
    return YES;
}

@end
