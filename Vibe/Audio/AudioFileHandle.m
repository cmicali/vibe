//
//  AudioFileHandle.m
//  Vibe
//

#import "AudioFileHandle.h"

#import <AudioToolbox/AudioToolbox.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation AudioFileHandle {
    // The callback context: valid from open until AudioFileClose returns in
    // dealloc. -1 once closed, or for a QuickTime container (below), whose
    // parser reads through its own descriptor.
    int _descriptor;
    SInt64 _size;
    AudioFileID _parser;
    ExtAudioFileRef _codec;
    UInt32 _bytesPerFrame; // of the processing format, per buffer
    BOOL _writing;
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
    [self closeParser];
    if (_descriptor >= 0) {
        close(_descriptor);
        _descriptor = -1;
    }
}

#pragma mark - The cursor

- (AVAudioFramePosition)framePosition {
    SInt64 position = 0;
    return ExtAudioFileTell(_codec, &position) == noErr ? position : 0;
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
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

@end
