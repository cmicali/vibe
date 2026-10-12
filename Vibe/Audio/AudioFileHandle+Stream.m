//
//  AudioFileHandle+Stream.m
//  Vibe
//
//  dr_flac's and dr_wav's decode of a FLAC, WAV or AIFF file: the opens, the
//  adopt, the close and the reads. The byte reads they decode from are
//  AudioFileHandle.m's (VibeStreamRead). The ivars are
//  AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"

@implementation AudioFileHandle (Stream)

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

@end
