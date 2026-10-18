//
//  AudioFileHandle+Stream.m
//  Vibe
//
//  dr_flac's, dr_wav's and libvorbis's decode of a FLAC, WAV, AIFF or Ogg
//  Vorbis file: the container sniff, the opens, the facts they answer in
//  place of CoreAudio's parser, the close and the reads. The byte reads they
//  decode from are AudioFileHandle.m's (VibeStreamRead). The ivars are
//  AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"

@implementation AudioFileHandle (Stream)

// Takes the file for the decoder that parses its container, in place of
// CoreAudio's parser, which never opens it. The file's first bytes name the
// container. RIFF and RF64 WAVE, Wave64 and AIFF(-C) go to dr_wav. FLAC,
// behind ID3v2 tags too, goes to dr_flac. Ogg whose first packet is Vorbis's
// identification goes to libvorbis. With `mpeg`, the dr_mp3 choice, MPEG
// frames go to dr_mp3, behind ID3v2 tags or in a WAV's data chunk too. NO
// leaves the file to the parser: BW64, RIFX and every other container, a
// coding the decoder does not decode, or a stream it cannot open.
- (BOOL)openOwnDecoderInterleaved:(BOOL)interleaved mpeg:(BOOL)mpeg {
    static const uint8_t wave64[16] = {'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00};
    uint8_t head[27 + 255 + 7]; // an Ogg page header, its segment table and the first packet's opening
    UInt32 got = 0;
    VibeHandleRead((__bridge void *)self, 0, sizeof head, head, &got);
    // Every tag, as dr_flac skips them. Fetched past the read block: a cover
    // bigger than the block would move it off the file's head, which the
    // parser reads next.
    SInt64 at = 0;
    for (uint32_t tag; got >= 10 && (tag = VibeID3v2TagBytes(head)); ) {
        at += tag;
        ssize_t fetched = VibeHandleFetch(self, at, 10, head, 10);
        got = fetched < 0 ? 0 : (UInt32)fetched;
    }
    if ((got >= 12 && (memcmp(head, "RIFF", 4) == 0 || memcmp(head, "RF64", 4) == 0) && memcmp(head + 8, "WAVE", 4) == 0)
            || (got >= 12 && memcmp(head, "FORM", 4) == 0 && (memcmp(head + 8, "AIFF", 4) == 0 || memcmp(head + 8, "AIFC", 4) == 0))
            || (got >= sizeof wave64 && memcmp(head, wave64, sizeof wave64) == 0)) {
        return [self openWAVInterleaved:interleaved] || (mpeg && [self openMPEGInWAVInterleaved:interleaved]);
    }
    if (got >= 4 && memcmp(head, "fLaC", 4) == 0) {
        return [self openFLACInterleaved:interleaved];
    }
    UInt32 packet = got >= 27 && memcmp(head, "OggS", 4) == 0 ? 27 + head[26] : 0;
    if (packet) {
        return got >= packet + 7 && memcmp(head + packet, "\x01vorbis", 7) == 0 && [self openVorbisInterleaved:interleaved];
    }
    AudioFileTypeID type = VibeFileTypeForExtension(_url.pathExtension);
    BOOL named = type == kAudioFileMP3Type || type == kAudioFileMP2Type || type == kAudioFileMP1Type;
    return mpeg && [self openMPEGFrom:at to:_size junk:named interleaved:interleaved];
}

// Keeps the decoder just opened when it found a file it plays: a length, no
// failed read, and formats that can be made. NO closes it. A zeroed
// description is a coding the decoder does not decode.
- (BOOL)keepStreamDecoderWithLength:(UInt64)length description:(AudioStreamBasicDescription)description
                             layout:(AVAudioChannelLayout *)layout interleaved:(BOOL)interleaved {
    if (length == 0 || description.mSampleRate <= 0 || description.mChannelsPerFrame == 0 || _streamReadFailed
            || ![self takeFileFormat:description layout:layout interleaved:interleaved]) {
        [self closeStreamDecoder];
        return NO;
    }
    _length = (SInt64)length;
    return YES;
}

// A WAVE channel mask as a layout, for more than two channels. CoreAudio's
// parser names some masks with a tag and others by their bits. Each folds to
// stereo as its bits do. Nil when the mask does not count the channels.
static AVAudioChannelLayout *VibeMaskLayout(UInt32 mask, UInt32 channels) {
    if (channels <= 2 || (UInt32)__builtin_popcount(mask) != channels) {
        return nil;
    }
    AudioChannelLayout bitmap = {.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap, .mChannelBitmap = mask};
    return [[AVAudioChannelLayout alloc] initWithLayout:&bitmap];
}

// dr_flac's facts as CoreAudio's parser states them. The source depth is the
// lossless format's flag, which names 16, 20, 24 and 32 bits. The parser
// states no flag for any other depth. Here a depth takes the narrowest flag
// that holds it. An 8 or 12-bit file states 16, and a 28-bit file states 32.
// With no flag, bit-perfect output would assume 24 and report a 28-bit file
// as Active.
// The packet is the largest block. FLAC orders three to eight channels as
// WAVE does, so each count is a mask. dr_flac answers the length, STREAMINFO's
// or, for a stream that leaves it unknown, the end of its last frame
// (ThirdParty/AGENTS.md).
- (BOOL)openFLACInterleaved:(BOOL)interleaved {
    static const UInt32 masks[] = {0x7, 0x33, 0x37, 0x3F, 0x70F, 0x63F};
    _flac = drflac_open(VibeStreamRead, VibeFLACSeek, VibeStreamTell, (__bridge void *)self, NULL);
    if (!_flac) {
        return NO;
    }
    UInt32 depth = _flac->bitsPerSample, channels = _flac->channels;
    AudioStreamBasicDescription description = {
        .mSampleRate = _flac->sampleRate, .mFormatID = kAudioFormatFLAC,
        .mFormatFlags = depth <= 16 ? kAppleLosslessFormatFlag_16BitSourceData : depth <= 20 ? kAppleLosslessFormatFlag_20BitSourceData
                : depth <= 24 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_32BitSourceData,
        .mFramesPerPacket = _flac->maxBlockSizeInPCMFrames, .mChannelsPerFrame = channels,
    };
    AVAudioChannelLayout *layout = channels >= 3 && channels <= 8 ? VibeMaskLayout(masks[channels - 3], channels) : nil;
    return [self keepStreamDecoderWithLength:_flac->totalPCMFrameCount description:description layout:layout interleaved:interleaved];
}

// Microsoft's ADPCM as CoreAudio names it. The SDK names no constant.
static const AudioFormatID kVibeMicrosoftADPCMFormat = 0x6D730002;

// What an AIFF's chunks state that dr_wav keeps no copy of.
typedef struct {
    AudioChannelLayout *layout; // the CHAN chunk's, malloc'd
    UInt16 sampleSize;          // the COMM chunk's, before dr_wav rounds it up to whole bytes
} VibeAIFFStated;

// dr_wav's facts as CoreAudio's parser states them, field for field. A PCM
// sample narrower than its bytes is high-aligned in them: 20 bits in 3. A
// WAV states that width. An AIFF's COMM does, and dr_wav rounds it up to the
// bytes. An extensible WAV's valid bits do, and they can fill fewer bytes
// than the container: 24 in 32 (Microsoft's WAVEFORMATEXTENSIBLE). There are
// two known differences. CoreAudio calls a sowt AIFF-C 16-bit whatever its
// COMM says, and reads it 1.5 or 2 times too long. It ignores an extensible
// WAV's valid bits and states the container. Zeroed for a coding dr_wav does
// not decode. Only dr_wav's own parse can tell one: a
// WAVE_FORMAT_EXTENSIBLE's subformat, an AIFF-C's compression type. MPEG in a
// WAV is one. Under the dr_mp3 choice the MPEG open takes it.
static AudioStreamBasicDescription VibeWAVDescription(const drwav *wav, UInt16 aiffSampleSize) {
    UInt32 channels = wav->channels, blockAlign = wav->fmt.blockAlign;
    BOOL aiff = wav->container == drwav_container_aiff;
    AudioStreamBasicDescription description = {.mSampleRate = wav->sampleRate, .mChannelsPerFrame = channels, .mFramesPerPacket = 1};
    switch (wav->translatedFormatTag) {
        case DR_WAVE_FORMAT_ALAW:
        case DR_WAVE_FORMAT_MULAW:
            description.mFormatID = wav->translatedFormatTag == DR_WAVE_FORMAT_ALAW ? kAudioFormatALaw : kAudioFormatULaw;
            description.mBitsPerChannel = 8;
            description.mBytesPerFrame = description.mBytesPerPacket = channels;
            break;
        case DR_WAVE_FORMAT_DVI_ADPCM:
            if (aiff) {
                // Apple's ima4: 64 frames a packet, in 34 bytes a channel.
                description.mFormatID = kAudioFormatAppleIMA4;
                description.mFramesPerPacket = 64;
                description.mBytesPerPacket = 34 * channels;
                break;
            }
            // A 4-byte header a channel, then two frames a byte.
            description.mFormatID = kAudioFormatDVIIntelIMA;
            description.mBytesPerPacket = blockAlign;
            description.mFramesPerPacket = (blockAlign - 4 * channels) * 2 / channels + 1;
            break;
        case DR_WAVE_FORMAT_ADPCM:
            // A 7-byte header a channel holding two frames, then two frames a byte.
            description.mFormatID = kVibeMicrosoftADPCMFormat;
            description.mBytesPerPacket = blockAlign;
            description.mFramesPerPacket = (blockAlign - 7 * channels) * 2 / channels + 2;
            break;
        case DR_WAVE_FORMAT_PCM:
        case DR_WAVE_FORMAT_IEEE_FLOAT: {
            BOOL isFloat = wav->translatedFormatTag == DR_WAVE_FORMAT_IEEE_FLOAT;
            if (isFloat && wav->bitsPerSample != 32 && wav->bitsPerSample != 64) {
                return (AudioStreamBasicDescription){0};
            }
            BOOL isSigned = !isFloat && (aiff ? !wav->aiff.isUnsigned : wav->bitsPerSample > 8);
            UInt32 bytes = (wav->bitsPerSample + 7) / 8;
            UInt32 stated = aiff ? ((aiffSampleSize + 7u) / 8 == bytes ? aiffSampleSize : 0) : wav->fmt.validBitsPerSample;
            UInt32 bits = !isFloat && stated > 0 && stated < wav->bitsPerSample ? stated : wav->bitsPerSample;
            description.mFormatID = kAudioFormatLinearPCM;
            description.mFormatFlags = (bits < bytes * 8 ? kAudioFormatFlagIsAlignedHigh : kAudioFormatFlagIsPacked)
                    | (isFloat ? kAudioFormatFlagIsFloat : 0) | (isSigned ? kAudioFormatFlagIsSignedInteger : 0)
                    | (aiff && !wav->aiff.isLE ? kAudioFormatFlagIsBigEndian : 0);
            description.mBitsPerChannel = bits;
            description.mBytesPerFrame = description.mBytesPerPacket = bytes * channels;
            break;
        }
        default:
            return (AudioStreamBasicDescription){0};
    }
    return description;
}

// An AIFF's chunks as dr_wav meets them, into the VibeAIFFStated at `user`.
// COMM's sample size is bytes 6 and 7. Apple's tools keep the channel layout
// in a CHAN chunk, CAF's form of an AudioChannelLayout, big-endian.
// CoreAudio's parser reads both.
static drwav_uint64 VibeReadAIFFChunk(void *user, drwav_read_proc onRead, drwav_seek_proc onSeek, void *readUser,
                                      const drwav_chunk_header *header, drwav_container container, const drwav_fmt *fmt) {
    enum { kFixedFields = 12, kDescriptionBytes = 20 };
    VibeAIFFStated *stated = user;
    if (container != drwav_container_aiff) {
        return 0;
    }
    if (memcmp(header->id.fourcc, "COMM", 4) == 0 && header->sizeInBytes >= 8) {
        uint8_t comm[8];
        size_t got = onRead(readUser, comm, sizeof comm);
        stated->sampleSize = got == sizeof comm ? OSReadBigInt16(comm, 6) : 0;
        return got;
    }
    if (memcmp(header->id.fourcc, "CHAN", 4) != 0
            || header->sizeInBytes < kFixedFields || header->sizeInBytes > kFixedFields + 64 * kDescriptionBytes) {
        return 0;
    }
    // The chunk is an AudioChannelLayout word for word, big-endian.
    _Static_assert(offsetof(AudioChannelLayout, mChannelDescriptions) == kFixedFields
                   && sizeof(AudioChannelDescription) == kDescriptionBytes, "a CHAN chunk's words are an AudioChannelLayout's");
    size_t size = (size_t)header->sizeInBytes;
    uint32_t *words = calloc(1, MAX(size, sizeof(AudioChannelLayout)));
    if (!words) {
        return 0;
    }
    size_t got = onRead(readUser, words, size);
    for (size_t i = 0; i < got / 4; i++) {
        words[i] = OSSwapBigToHostInt32(words[i]);
    }
    AudioChannelLayout *layout = (AudioChannelLayout *)words;
    if (got < size || kFixedFields + (uint64_t)layout->mNumberChannelDescriptions * kDescriptionBytes > got) {
        free(words);
        return got;
    }
    free(stated->layout);
    stated->layout = layout;
    return got;
}

// dr_wav answers the length: the frames the data holds, a COMM or fact count
// only when it is no more. The layout is an AIFF's CHAN chunk, or a WAV's
// channel mask.
- (BOOL)openWAVInterleaved:(BOOL)interleaved {
    VibeAIFFStated stated = {0};
    if (!drwav_init_ex(&_wavState, VibeStreamRead, VibeWAVSeek, VibeStreamTell, VibeReadAIFFChunk, (__bridge void *)self, &stated, 0, NULL)) {
        free(stated.layout);
        return NO;
    }
    _wav = &_wavState;
    AVAudioChannelLayout *layout = stated.layout ? [[AVAudioChannelLayout alloc] initWithLayout:stated.layout] : nil;
    free(stated.layout);
    if (_wav->channels <= 2 || layout.channelCount != _wav->channels) {
        layout = VibeMaskLayout(_wav->fmt.channelMask, _wav->channels);
    }
    return [self keepStreamDecoderWithLength:_wav->totalPCMFrameCount description:VibeWAVDescription(_wav, stated.sampleSize)
                                      layout:layout interleaved:interleaved];
}

// Vorbis I's channel order (section 4.3.9) for three to eight channels, as
// labels. The voice bus then folds each channel as the file means it. Nil for
// mono and stereo, and for a wider stream, whose order is the encoder's own.
static AVAudioChannelLayout *VibeVorbisChannelLayout(UInt32 channels) {
    enum { L = kAudioChannelLabel_Left, R = kAudioChannelLabel_Right, C = kAudioChannelLabel_Center,
           Ls = kAudioChannelLabel_LeftSurround, Rs = kAudioChannelLabel_RightSurround,
           Cs = kAudioChannelLabel_CenterSurround, Rls = kAudioChannelLabel_RearSurroundLeft,
           Rrs = kAudioChannelLabel_RearSurroundRight, LFE = kAudioChannelLabel_LFEScreen };
    static const AudioChannelLabel orders[6][8] = {
        {L, C, R}, {L, R, Ls, Rs}, {L, C, R, Ls, Rs}, {L, C, R, Ls, Rs, LFE},
        {L, C, R, Ls, Rs, Cs, LFE}, {L, C, R, Ls, Rs, Rls, Rrs, LFE},
    };
    if (channels <= 2 || channels > 8) {
        return nil;
    }
    size_t size = offsetof(AudioChannelLayout, mChannelDescriptions) + channels * sizeof(AudioChannelDescription);
    AudioChannelLayout *layout = calloc(1, size);
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = channels;
    for (UInt32 c = 0; c < channels; c++) {
        layout->mChannelDescriptions[c].mChannelLabel = orders[channels - 3][c];
    }
    AVAudioChannelLayout *result = [[AVAudioChannelLayout alloc] initWithLayout:layout];
    free(layout);
    return result;
}

// vorbisfile answers the facts. The rate and the channels are the first
// stream's. The bus keeps one format per file, so a chained file that changes
// either is left to CoreAudio's parser. The length is the last page's granule
// position, which trims the encoder's padding too.
- (BOOL)openVorbisInterleaved:(BOOL)interleaved {
    _vorbis = calloc(1, sizeof(OggVorbis_File));
    ov_callbacks callbacks = { VibeVorbisRead, VibeVorbisSeek, NULL, VibeVorbisTell };
    if (!_vorbis || ov_open_callbacks((__bridge void *)self, _vorbis, NULL, 0, callbacks) != 0) {
        [self closeStreamDecoder]; // a failed open has cleared it, and clearing again is safe
        return NO;
    }
    // vorbisfile keeps every link's comments, an embedded cover among them,
    // until it closes. Nothing reads them after the open.
    for (int link = 0; link < ov_streams(_vorbis); link++) {
        vorbis_comment_clear(&_vorbis->vc[link]);
    }
    vorbis_info *info = ov_info(_vorbis, 0);
    BOOL uniform = info != NULL;
    for (int link = 1; uniform && link < ov_streams(_vorbis); link++) {
        vorbis_info *next = ov_info(_vorbis, link);
        uniform = next && next->channels == info->channels && next->rate == info->rate;
    }
    if (!uniform) {
        [self closeStreamDecoder];
        return NO;
    }
    AudioStreamBasicDescription description = {
        .mSampleRate = (Float64)info->rate, .mFormatID = 'vorb', .mChannelsPerFrame = (UInt32)info->channels,
    };
    ogg_int64_t length = ov_pcm_total(_vorbis, -1);
    return [self keepStreamDecoderWithLength:(UInt64)MAX(0, length) description:description
                                      layout:VibeVorbisChannelLayout(description.mChannelsPerFrame) interleaved:interleaved];
}

- (void)closeStreamDecoder {
    drflac_close(_flac);
    _flac = NULL;
    if (_wav) {
        drwav_uninit(_wav);
        _wav = NULL;
    }
    if (_vorbis) {
        ov_clear(_vorbis);
        free(_vorbis);
        _vorbis = NULL;
    }
}

// libvorbis's decode. vorbisfile hands out each packet's frames from buffers
// of its own, a channel to each. They are copied to a plane each, or
// interleaved. A hole, a page lost to damage, is skipped, and the decode goes
// on from the next page.
- (AVAudioFrameCount)readVorbisInto:(float *const *)planes frameCount:(AVAudioFrameCount)wanted failed:(BOOL *)failed {
    UInt32 channels = _processingFormat.channelCount;
    BOOL interleaved = _processingFormat.isInterleaved;
    AVAudioFrameCount got = 0;
    while (got < wanted) {
        float **pcm = NULL;
        long frames = ov_read_float(_vorbis, &pcm, (int)MIN(wanted - got, (AVAudioFrameCount)INT_MAX), NULL);
        if (frames == OV_HOLE) {
            continue;
        }
        if (frames <= 0) {
            *failed = frames < 0;
            break;
        }
        if (interleaved) {
            float *to = planes[0] + (size_t)got * channels;
            for (long f = 0; f < frames; f++) {
                for (UInt32 c = 0; c < channels; c++) {
                    *to++ = pcm[c][f];
                }
            }
        } else {
            for (UInt32 c = 0; c < channels; c++) {
                memcpy(planes[c] + got, pcm[c], (size_t)frames * sizeof(float));
            }
        }
        got += (AVAudioFrameCount)frames;
    }
    _vorbisPosition += got;
    return got;
}

// dr_flac's, dr_wav's or libvorbis's decode, into the buffer: a channel to
// each plane, or interleaved. Each reads all that is asked but at the end of
// the stream. Reads stop at the length, where dr_flac's would read on.
- (BOOL)readStreamIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    float *const *planes = buffer.floatChannelData;
    drflac_uint64 frames = (drflac_uint64)MIN((SInt64)wanted, MAX(0, _length - self.framePosition));
    drflac_uint64 got;
    BOOL failed = NO;
    if (_vorbis) {
        got = [self readVorbisInto:planes frameCount:(AVAudioFrameCount)frames failed:&failed];
    } else if (!_processingFormat.isInterleaved) {
        got = _flac ? drflac_read_pcm_frames_f32_planar(_flac, frames, planes) : drwav_read_pcm_frames_f32_planar(_wav, frames, planes);
    } else {
        got = _flac ? drflac_read_pcm_frames_f32(_flac, frames, planes[0]) : drwav_read_pcm_frames_f32(_wav, frames, planes[0]);
    }
    buffer.frameLength = (AVAudioFrameCount)got;
    if ((_streamReadFailed || failed) && !_waitError) {
        if (error) {
            *error = VibeHandleError(kAudioFilePositionError, [NSString stringWithFormat:@"Reading %@ failed", _url.lastPathComponent]);
        }
        return NO;
    }
    return [self reportWaitFault:error];
}

@end
