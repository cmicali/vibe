//
//  AudioFileHandle+MPEG.m
//  Vibe
//
//  dr_mp3's decode of an MPEG file: the open, the packet count of a stream
//  with no VBR header and its settle, the seek, the reads and the packet
//  decode. The ivars are AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"
#import "CloudFileAvailability.h"

#import <Accelerate/Accelerate.h>

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

// A stream's packet count until it is settled (VibeUncountedMPEGPackets).
static const SInt64 kVibeMPEGPacketsUncounted = INT64_MAX;

// The head a stream's frames are walked in: what is on disk of its first MB of
// audio, so the open never waits for it. At the 256 KB a stream opens on, 7 to
// 20 s of a 128 to 320 kbps stream, a few hundred frames; the average of every
// one of them, since more is a better guess and the walk costs one read. Fewer
// than kVibeMPEGEstimateFrames whole frames is no guess at all.
enum { kVibeMPEGEstimateBytes = 1024 * 1024, kVibeMPEGEstimateFrames = 16 };

@implementation AudioFileHandle (MPEG)

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
    // A read-ahead counts at open, as a whole file does, its waits reading
    // the frame headers.
    SInt64 estimate = _availability.partURL ? VibeUncountedMPEGPackets(self, description) : 0;
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

// seekToFrame:'s dr_mp3 branch. It has cleared an interruption first.
- (BOOL)seekMPEGToFrame:(AVAudioFramePosition)frame error:(NSError **)error {
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
