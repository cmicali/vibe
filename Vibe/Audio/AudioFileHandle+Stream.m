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

// The containers whose decoder parses them itself, answering the file's facts
// as well as its samples.
typedef NS_ENUM(NSInteger, VibeOwnContainer) {
    VibeOwnContainerNone,
    VibeOwnContainerFLAC,
    VibeOwnContainerWAV,
    VibeOwnContainerOggVorbis,
};

// The container a file's first bytes name, read through the handle's reads:
// FLAC, behind an ID3v2 tag too, for dr_flac. RIFF and RF64 WAVE, Wave64 and
// AIFF(-C) for dr_wav. Ogg whose first packet is Vorbis's identification for
// libvorbis. BW64 and RIFX are left to CoreAudio's parser.
static VibeOwnContainer VibeOwnContainerOf(AudioFileHandle *handle) {
    static const uint8_t wave64[16] = {'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00};
    uint8_t head[27 + 255 + 7]; // an Ogg page header, its segment table and the first packet's opening
    UInt32 got = 0;
    VibeHandleRead((__bridge void *)handle, 0, sizeof head, head, &got);
    if (got >= 12 && (memcmp(head, "RIFF", 4) == 0 || memcmp(head, "RF64", 4) == 0) && memcmp(head + 8, "WAVE", 4) == 0) {
        return VibeOwnContainerWAV;
    }
    if (got >= 12 && memcmp(head, "FORM", 4) == 0 && (memcmp(head + 8, "AIFF", 4) == 0 || memcmp(head + 8, "AIFC", 4) == 0)) {
        return VibeOwnContainerWAV;
    }
    if (got >= sizeof wave64 && memcmp(head, wave64, sizeof wave64) == 0) {
        return VibeOwnContainerWAV;
    }
    if (got >= 4 && memcmp(head, "fLaC", 4) == 0) {
        return VibeOwnContainerFLAC;
    }
    if (got >= 27 && memcmp(head, "OggS", 4) == 0) {
        UInt32 packet = 27 + head[26];
        return got >= packet + 7 && memcmp(head + packet, "\x01vorbis", 7) == 0 ? VibeOwnContainerOggVorbis : VibeOwnContainerNone;
    }
    uint32_t tag = got >= 10 ? VibeID3v2TagBytes(head) : 0;
    uint8_t magic[4];
    UInt32 read = 0;
    if (tag && VibeHandleRead((__bridge void *)handle, tag, sizeof magic, magic, &read) == noErr && read == sizeof magic
            && memcmp(magic, "fLaC", 4) == 0) {
        return VibeOwnContainerFLAC;
    }
    return VibeOwnContainerNone;
}

// Takes the file for the decoder that parses its container, in place of
// CoreAudio's parser, which never opens it. NO leaves the file to the parser:
// a container none of them parses, a coding the decoder does not decode, or a
// stream it cannot open.
- (BOOL)openOwnDecoderInterleaved:(BOOL)interleaved {
    switch (VibeOwnContainerOf(self)) {
        case VibeOwnContainerFLAC:
            return [self openFLACInterleaved:interleaved];
        case VibeOwnContainerWAV:
            return [self openWAVInterleaved:interleaved];
        case VibeOwnContainerOggVorbis:
            return [self openVorbisInterleaved:interleaved];
        case VibeOwnContainerNone:
            return NO;
    }
}

// Keeps the decoder just opened when it found a file it plays: a length, no
// failed read, and formats that can be made. NO closes it.
- (BOOL)keepStreamDecoderWithLength:(UInt64)length description:(AudioStreamBasicDescription)description
                             layout:(AVAudioChannelLayout *)layout interleaved:(BOOL)interleaved {
    if (length == 0 || description.mSampleRate <= 0 || description.mChannelsPerFrame == 0 || _streamReadFailed || _waitError
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
// lossless format's flag, which CoreAudio states for 16, 20 and 24 bits only.
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
        .mFormatFlags = depth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : depth == 20 ? kAppleLosslessFormatFlag_20BitSourceData
                : depth == 24 ? kAppleLosslessFormatFlag_24BitSourceData : 0,
        .mFramesPerPacket = _flac->maxBlockSizeInPCMFrames, .mChannelsPerFrame = channels,
    };
    AVAudioChannelLayout *layout = channels >= 3 && channels <= 8 ? VibeMaskLayout(masks[channels - 3], channels) : nil;
    return [self keepStreamDecoderWithLength:_flac->totalPCMFrameCount description:description layout:layout interleaved:interleaved];
}

// The codings dr_wav decodes. Only its own parse can tell them: a
// WAVE_FORMAT_EXTENSIBLE's subformat, an AIFF-C's compression type. MPEG in a
// WAV is one it does not, which goes to CoreAudio's parser and dr_mp3.
static BOOL VibeDrWAVDecodesCoding(const drwav *wav) {
    drwav_uint16 tag = wav->translatedFormatTag;
    return tag == DR_WAVE_FORMAT_PCM || tag == DR_WAVE_FORMAT_ALAW || tag == DR_WAVE_FORMAT_MULAW
            || tag == DR_WAVE_FORMAT_ADPCM || tag == DR_WAVE_FORMAT_DVI_ADPCM
            || (tag == DR_WAVE_FORMAT_IEEE_FLOAT && (wav->bitsPerSample == 32 || wav->bitsPerSample == 64));
}

// Microsoft's ADPCM as CoreAudio names it. The SDK names no constant.
static const AudioFormatID kVibeMicrosoftADPCMFormat = 0x6D730002;

// dr_wav's facts as CoreAudio's parser states them, field for field. The one
// known difference is a sowt AIFF-C. CoreAudio calls it 16-bit whatever its
// COMM says, and reads it 1.5 or 2 times too long.
static AudioStreamBasicDescription VibeWAVDescription(const drwav *wav) {
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
        default: {
            BOOL isFloat = wav->translatedFormatTag == DR_WAVE_FORMAT_IEEE_FLOAT;
            BOOL isSigned = !isFloat && (aiff ? !wav->aiff.isUnsigned : wav->bitsPerSample > 8);
            description.mFormatID = kAudioFormatLinearPCM;
            description.mFormatFlags = kAudioFormatFlagIsPacked | (isFloat ? kAudioFormatFlagIsFloat : 0)
                    | (isSigned ? kAudioFormatFlagIsSignedInteger : 0) | (aiff && !wav->aiff.isLE ? kAudioFormatFlagIsBigEndian : 0);
            description.mBitsPerChannel = wav->bitsPerSample;
            description.mBytesPerFrame = description.mBytesPerPacket = (wav->bitsPerSample + 7) / 8 * channels;
        }
    }
    return description;
}

static uint32_t VibeBigEndian32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// Apple's tools keep an AIFF's channel layout in a CHAN chunk, CAF's form of
// an AudioChannelLayout, big-endian. CoreAudio's parser reads it, and so does
// this, as dr_wav meets the chunk. `user` holds the layout, malloc'd.
static drwav_uint64 VibeReadCHANChunk(void *user, drwav_read_proc onRead, drwav_seek_proc onSeek, void *readUser,
                                      const drwav_chunk_header *header, drwav_container container, const drwav_fmt *fmt) {
    enum { kFixedFields = 12, kDescriptionBytes = 20 };
    if (container != drwav_container_aiff || memcmp(header->id.fourcc, "CHAN", 4) != 0
            || header->sizeInBytes < kFixedFields || header->sizeInBytes > kFixedFields + 64 * kDescriptionBytes) {
        return 0;
    }
    uint8_t chunk[kFixedFields + 64 * kDescriptionBytes];
    size_t got = onRead(readUser, chunk, (size_t)header->sizeInBytes);
    uint32_t count = got >= kFixedFields ? VibeBigEndian32(chunk + 8) : 0;
    if (got < header->sizeInBytes || kFixedFields + (uint64_t)count * kDescriptionBytes > got) {
        return got;
    }
    AudioChannelLayout *layout = calloc(1, offsetof(AudioChannelLayout, mChannelDescriptions) + MAX(count, 1u) * sizeof(AudioChannelDescription));
    layout->mChannelLayoutTag = VibeBigEndian32(chunk);
    layout->mChannelBitmap = VibeBigEndian32(chunk + 4);
    layout->mNumberChannelDescriptions = count;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *field = chunk + kFixedFields + i * kDescriptionBytes;
        AudioChannelDescription *description = &layout->mChannelDescriptions[i];
        description->mChannelLabel = VibeBigEndian32(field);
        description->mChannelFlags = VibeBigEndian32(field + 4);
        for (int axis = 0; axis < 3; axis++) {
            uint32_t bits = VibeBigEndian32(field + 8 + 4 * axis);
            memcpy(&description->mCoordinates[axis], &bits, sizeof bits);
        }
    }
    free(*(AudioChannelLayout **)user);
    *(AudioChannelLayout **)user = layout;
    return got;
}

// dr_wav answers the length: the frames the data holds, a COMM or fact count
// only when it is no more. The layout is an AIFF's CHAN chunk, or a WAV's
// channel mask.
- (BOOL)openWAVInterleaved:(BOOL)interleaved {
    AudioChannelLayout *stated = NULL;
    if (!drwav_init_ex(&_wavState, VibeStreamRead, VibeWAVSeek, VibeStreamTell, VibeReadCHANChunk, (__bridge void *)self, &stated, 0, NULL)) {
        free(stated);
        return NO;
    }
    _wav = &_wavState;
    AVAudioChannelLayout *layout = stated ? [[AVAudioChannelLayout alloc] initWithLayout:stated] : nil;
    free(stated);
    if (_wav->channels <= 2 || layout.channelCount != _wav->channels) {
        layout = VibeMaskLayout(_wav->fmt.channelMask, _wav->channels);
    }
    if (!VibeDrWAVDecodesCoding(_wav)) {
        [self closeStreamDecoder];
        return NO;
    }
    return [self keepStreamDecoderWithLength:_wav->totalPCMFrameCount description:VibeWAVDescription(_wav)
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
    BOOL uniform = info && info->channels > 0 && info->rate > 0;
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
