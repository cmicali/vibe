//
//  AudioFileHandle+MPEG.m
//  Vibe
//
//  dr_mp3's decode of an MPEG file: the open, which frames the stream in
//  place of CoreAudio's parser, the walk that indexes its frames, the packet
//  count of a stream with no VBR header and its settle, the seek, the reads
//  and the packet decode. The ivars are AudioFileHandleInternal.h's.
//

#import "AudioFileHandleInternal.h"
#import "CloudFileAvailability.h"
#import "VibeMacros.h"

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

// A stream's packet count until it is settled (estimateMPEGPacketsAtRate:).
static const SInt64 kVibeMPEGPacketsUncounted = INT64_MAX;

enum {
    // Frames a stream's estimate waits for. Fewer is no guess at all. It
    // walks on through the frames already on disk, up to the first MB.
    kVibeMPEGEstimateFrames = 16,
    kVibeMPEGEstimateBytes = 1024 * 1024,
    // More than any frame: MPEG-2.5 Layer II at 160 kbps is 2,881 bytes, and
    // a free format frame at most DRMP3_MAX_FREE_FORMAT_FRAME_SIZE.
    kVibeMPEGFrameCapacity = 4096,
    // A frame is the stream's first, or where a walk takes up again after
    // damage, only when this many frames follow it, unless the data ends.
    // One header can be a stray match in a tag or damage. A chain of them
    // is not.
    kVibeMPEGSyncFrames = 4,
    // How far past the tags the first frame may lie in a file named as
    // MPEG, and how far past damage a walk looks for the next frame.
    kVibeMPEGSyncSpan = 64 * 1024,
    // Bytes after a stated stream that tags can fill, ID3v1, APE and the like,
    // at least: a sixteenth of the audio's bytes is allowed too.
    kVibeMPEGTrailingBytes = 1024,
};

// One frame header's facts. `fixed` is what every frame of a stream shares:
// its version, layer and rate. The mode is not, since a stream can change it
// from frame to frame, nor whether it states its bit rate. `bytes` is 0 for a
// frame that states none (free format), which only the next header measures.
// `smallest` and `largest` are the sizes a frame of the stream can have.
typedef struct {
    UInt32 layer, rate, framesPerPacket, channels, bitrate, bytes, padding, fixed, smallest, largest;
} VibeMPEGFrame;

// A frame's size at `bitrate`, before its padding.
static inline UInt32 VibeMPEGFrameBytes(const VibeMPEGFrame *frame, UInt32 bitrate) {
    return frame->layer == 1 ? 12 * bitrate / frame->rate * 4 : frame->framesPerPacket / 8 * bitrate / frame->rate;
}

// The header at `h`, as ISO/IEC 11172-3 and 13818-3 lay it out.
static BOOL VibeMPEGParse(const uint8_t h[4], VibeMPEGFrame *frame) {
    static const uint16_t kbps[2][3][15] = {
        {{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448},
         {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384},
         {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}},
        {{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256},
         {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
         {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}},
    };
    static const UInt32 rates[3] = {44100, 48000, 32000};
    UInt32 version = (h[1] >> 3) & 3, layer = 4 - ((h[1] >> 1) & 3), index = h[2] >> 4, rateIndex = (h[2] >> 2) & 3;
    if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0 || version == 1 || layer == 4 || index == 15 || rateIndex == 3) {
        return NO;
    }
    BOOL lsf = version != 3; // MPEG-2 or MPEG-2.5
    UInt32 slot = layer == 1 ? 4 : 1;
    frame->layer = layer;
    frame->rate = rates[rateIndex] >> (version == 3 ? 0 : version == 2 ? 1 : 2);
    frame->framesPerPacket = layer == 1 ? 384 : layer == 3 && lsf ? 576 : 1152;
    frame->channels = (h[3] >> 6) == 3 ? 1 : 2;
    frame->padding = ((h[2] >> 1) & 1) * slot;
    frame->fixed = (UInt32)(h[1] & 0xFE) << 8 | (h[2] & 0x0C);
    frame->bitrate = kbps[lsf][layer - 1][index] * 1000u;
    frame->bytes = index ? VibeMPEGFrameBytes(frame, frame->bitrate) + frame->padding : 0;
    frame->smallest = VibeMPEGFrameBytes(frame, kbps[lsf][layer - 1][1] * 1000u);
    frame->largest = (index ? VibeMPEGFrameBytes(frame, kbps[lsf][layer - 1][14] * 1000u) : DRMP3_MAX_FREE_FORMAT_FRAME_SIZE) + slot;
    return YES;
}

@implementation AudioFileHandle (MPEG)

// A header of the stream at `at`, or any header while no stream is known
// (_mpegFixed 0). A read that waited and lost reads as none.
- (BOOL)mpegHeaderAt:(SInt64)at frame:(VibeMPEGFrame *)frame {
    uint8_t h[4];
    UInt32 got = 0;
    return at + 4 <= _mpegDataEnd && VibeHandleRead((__bridge void *)self, at, 4, h, &got) == noErr && got == 4
            && VibeMPEGParse(h, frame) && (!_mpegFixed || frame->fixed == _mpegFixed);
}

// Whether a free format frame can end at `next`: at the data's end, or at a
// header of the stream whose own frame another header follows.
- (BOOL)mpegFreeFrameEndsAt:(SInt64)next {
    VibeMPEGFrame other, third;
    if (next == _mpegDataEnd) {
        return YES;
    }
    if (![self mpegHeaderAt:next frame:&other]) {
        return NO;
    }
    SInt64 after = next + other.bytes;
    return other.bytes == 0 || after == _mpegDataEnd || [self mpegHeaderAt:after frame:&third];
}

// The stream's frame at `at`, all of it before the data's end. A frame that
// states no bit rate runs to the first place a free format frame can end. A
// stream can be free format throughout, and damage can leave one frame so.
// The frame's bytes are read once, and only a 0xFF can start the header that
// ends it.
// TRAP: never past dr_mp3's largest free format frame. Its reservoir copy
// holds that much, and a longer frame overflowed into the side information
// beside it: a damaged stream whose free format frames were six frames apart.
- (BOOL)mpegFrameAt:(SInt64)at frame:(VibeMPEGFrame *)frame {
    if (![self mpegHeaderAt:at frame:frame]) {
        return NO;
    }
    if (frame->bytes == 0) {
        uint8_t window[4 + DRMP3_MAX_FREE_FORMAT_FRAME_SIZE + 1];
        SInt64 limit = MIN(at + frame->padding + DRMP3_MAX_FREE_FORMAT_FRAME_SIZE, _mpegDataEnd);
        UInt32 got = 0;
        if (VibeHandleRead((__bridge void *)self, at, (UInt32)MIN((SInt64)sizeof window, limit - at + 1), window, &got) != noErr) {
            got = 0;
        }
        for (SInt64 next = at + 4; frame->bytes == 0 && next <= limit && !_waitError; next++) {
            if ((next == _mpegDataEnd || (next - at < got && window[next - at] == 0xFF)) && [self mpegFreeFrameEndsAt:next]) {
                frame->bytes = (UInt32)(next - at);
            }
        }
    }
    return frame->bytes > 4 && at + frame->bytes <= _mpegDataEnd;
}

// Whether kVibeMPEGSyncFrames frames of the stream chain from `at`, or reach
// the data's end exactly, or a tag that ends a file: ID3v1, APE, Lyrics3 or
// an ID3v2 tag appended. TRAP: without the tags, the frames between damage
// and a file's ID3v1 tag were dropped, since too few chained to the end.
- (BOOL)mpegFramesChainFrom:(SInt64)at {
    VibeMPEGFrame frame;
    for (int n = 0; n < kVibeMPEGSyncFrames; n++) {
        uint8_t tag[8];
        UInt32 got = 0;
        if (at == _mpegDataEnd || (n > 0 && VibeHandleRead((__bridge void *)self, at, sizeof tag, tag, &got) == noErr && got >= 3
                                   && (memcmp(tag, "TAG", 3) == 0 || memcmp(tag, "ID3", 3) == 0
                                       || (got == sizeof tag && (memcmp(tag, "APETAGEX", 8) == 0 || memcmp(tag, "LYRICSBE", 8) == 0))))) {
            return n > 0;
        }
        // A free format frame measured only by the data's end is no evidence
        // of a stream. One damaged header near a short file's end otherwise
        // took the whole file for a single frame.
        if (![self mpegFrameAt:at frame:&frame] || (n == 0 && frame.bitrate == 0 && at + frame.bytes == _mpegDataEnd)) {
            return NO;
        }
        at += frame.bytes;
    }
    return YES;
}

// The first frame at or after `from`, no further on than `span`, that a chain
// follows. With no stream yet (_mpegFixed 0) the candidate's header sets it.
// Each header is read on its own, so a stream waits only for the bytes each
// one needs. -1 when there is none.
- (SInt64)syncMPEGFrom:(SInt64)from span:(SInt64)span {
    UInt32 fixed = _mpegFixed;
    for (SInt64 at = from; at <= from + span && at + 4 <= _mpegDataEnd; at++) {
        VibeMPEGFrame frame;
        if (![self mpegHeaderAt:at frame:&frame]) {
            if (_waitError) {
                return -1;
            }
            continue;
        }
        _mpegFixed = frame.fixed;
        if ([self mpegFramesChainFrom:at]) {
            return at;
        }
        _mpegFixed = fixed;
    }
    return -1;
}

// Indexes frames until packet `packet` is, or the walk reaches the data's
// end. Each header is read as any read is, so a stream's walk waits for its
// bytes. A header that is not the stream's is damage, and the walk takes up
// again at the next frame a chain follows. YES when the packet is indexed.
// TRAP: a wait that answers no ends no walk, or a lost read would shorten the
// packet count for good.
- (BOOL)indexMPEGThrough:(SInt64)packet {
    while (_mpegIndexed <= packet && !_mpegWalkEnded) {
        VibeMPEGFrame frame;
        if (![self mpegFrameAt:_mpegWalk frame:&frame]) {
            SInt64 next = _waitError ? -1 : [self syncMPEGFrom:_mpegWalk + 1 span:kVibeMPEGSyncSpan];
            if (_waitError) {
                return NO; // a lost wait, the walk not ended
            }
            if (next < 0) {
                _mpegWalkEnded = YES;
                break;
            }
            _mpegWalk = next;
            continue;
        }
        if (_mpegIndexed == _mpegIndexCapacity) {
            SInt64 capacity = MAX(1024, _mpegIndexCapacity * 2);
            SInt64 *offsets = realloc(_mpegOffsets, (size_t)capacity * sizeof(*offsets));
            uint16_t *sizes = offsets ? realloc(_mpegSizes, (size_t)capacity * sizeof(*sizes)) : NULL;
            if (offsets) {
                _mpegOffsets = offsets;
            }
            if (!sizes) {
                _mpegWalkEnded = YES;
                break;
            }
            _mpegSizes = sizes;
            _mpegIndexCapacity = capacity;
        }
        _mpegOffsets[_mpegIndexed] = _mpegWalk;
        _mpegSizes[_mpegIndexed] = (uint16_t)frame.bytes;
        _mpegIndexed++;
        _mpegConstantBitrate = _mpegConstantBitrate && frame.bitrate == _mpegFirstBitrate;
        _mpegChannels = MAX(_mpegChannels, frame.channels);
        _mpegWalk += frame.bytes;
    }
    return _mpegIndexed > packet;
}

// A COMM frame's body: encoding, language, description, text. UTF-16 ends
// the description with two zero bytes, and its BOMs and zero bytes are
// dropped here, so its ASCII reads as Latin-1. YES when it is iTunSMPB with
// four hex words.
static BOOL VibeITunesGaplessText(const uint8_t *body, SInt64 size, SInt64 *priming, SInt64 *remainder, SInt64 *frames) {
    SInt64 wide = body[0] == 1 || body[0] == 2, i = 4;
    char text[512];
    size_t length = 0;
    while (i + wide < size && (body[i] || (wide && body[i + 1]))) {
        if (body[i] && body[i] < 0x80) text[length++] = (char)body[i];
        i++;
    }
    if (length != 8 || memcmp(text, "iTunSMPB", 8) != 0) {
        return NO;
    }
    length = 0;
    for (i += 1 + wide; i < size; i++) {
        if (body[i] && body[i] < 0x80) text[length++] = (char)body[i];
    }
    text[length] = 0;
    unsigned long long words[4] = {0};
    char *cursor = text;
    for (int count = 0; count < 4; count++) {
        char *after = NULL;
        words[count] = strtoull(cursor, &after, 16);
        if (after == cursor) return NO;
        cursor = after;
    }
    // TRAP: the words are 64-bit, and a damaged one overflowed the length's
    // arithmetic. A priming or remainder past 65,536 frames, over a second at
    // MP3's highest rate, or frames past 2^40, is no gapless comment.
    if (words[1] > 1 << 16 || words[2] > 1 << 16 || words[3] > 1ULL << 40) {
        return NO;
    }
    *priming = (SInt64)words[1];
    *remainder = (SInt64)words[2];
    *frames = (SInt64)words[3];
    return YES;
}

// Undoes ID3v2 unsynchronisation in place: the writer put a zero byte after
// every 0xFF that could read as a frame sync. Answers the length left.
static SInt64 VibeID3v2Resync(uint8_t *bytes, SInt64 length) {
    SInt64 to = 0;
    for (SInt64 from = 0; from < length; from++) {
        bytes[to++] = bytes[from];
        if (bytes[from] == 0xFF && from + 1 < length && bytes[from + 1] == 0) {
            from++;
        }
    }
    return to;
}

// `count` of a tag's bytes at `at`: the file's, or a decoded tag's when one
// is held.
static BOOL VibeID3v2Read(void *context, const uint8_t *decoded, SInt64 length, SInt64 at, SInt64 count, uint8_t *out) {
    if (decoded) {
        if (at < 0 || count > length - at) return NO;
        memcpy(out, decoded + at, (size_t)count);
        return YES;
    }
    UInt32 got = 0;
    return VibeHandleRead(context, at, (UInt32)count, out, &got) == noErr && got == count;
}

// iTunes' gapless comment, in the ID3v2 tags before `end`: an ID3v2.2 COM or
// later COMM frame described as "iTunSMPB", whose text is hex words. The
// second is the priming, the third the remainder and the fourth the frames
// between. NO when none states it.
//
// TRAP: unsynchronisation. An ID3v2.2 or 2.3 tag can be unsynchronised as a
// whole, and its frame sizes count the decoded bytes. So that tag is decoded
// first, up to kVibeID3v2DecodedTagBytes, and walked in memory. An ID3v2.4
// frame flags its own, and can carry a data length first. Skipping either
// left an iTunes file playing its encoder's padding.
static BOOL VibeITunesGapless(AudioFileHandle *handle, SInt64 end, SInt64 *priming, SInt64 *remainder, SInt64 *frames) {
    enum { kVibeID3v2DecodedTagBytes = 16 * 1024 * 1024 };
    void *context = (__bridge void *)handle;
    uint8_t h[10];
    UInt32 got = 0;
    BOOL found = NO;
    for (SInt64 tag = 0; !found && tag + 10 <= end && VibeHandleRead(context, tag, 10, h, &got) == noErr && got == 10;) {
        uint32_t bytes = VibeID3v2TagBytes(h);
        if (!bytes) {
            break;
        }
        UInt32 version = h[3];
        BOOL whole = (h[5] & 0x80) && version <= 3;
        SInt64 at = tag + 10, stop = MIN(end, tag + bytes);
        uint8_t *decoded = NULL;
        if (whole && stop - at <= kVibeID3v2DecodedTagBytes && (decoded = malloc((size_t)MAX(1, stop - at)))) {
            if (VibeID3v2Read(context, NULL, 0, at, stop - at, decoded)) {
                stop = VibeID3v2Resync(decoded, stop - at);
                at = 0;
            } else {
                free(decoded);
                decoded = NULL;
            }
        }
        if (version >= 2 && version <= 4 && (!whole || decoded)) {
            if (h[5] & 0x40 && version >= 3) {
                uint8_t x[4];
                if (!VibeID3v2Read(context, decoded, stop, at, 4, x)) {
                    at = stop;
                } else {
                    at += version == 4 ? VibeID3v2Syncsafe(x) : 4 + (SInt64)OSReadBigInt32(x, 0);
                }
            }
            UInt32 header = version == 2 ? 6 : 10;
            while (!found && at + header <= stop && VibeID3v2Read(context, decoded, stop, at, header, h) && h[0]) {
                SInt64 size = version == 2 ? (SInt64)h[3] << 16 | h[4] << 8 | h[5]
                        : version == 4 ? (SInt64)VibeID3v2Syncsafe(h + 4)
                        : (SInt64)OSReadBigInt32(h, 4);
                // TRAP: a damaged size can claim more than the tag holds. In
                // 32 bits, a header plus a size near 2^32 wrapped to 0, and
                // the walk never moved.
                if (size > stop - at - header) {
                    break;
                }
                // ID3v2.4's frame flags: unsynchronised (0x02) and a data
                // length first (0x01) are read. Compression and encryption,
                // in either version, are not.
                UInt32 flags = version == 2 ? 0 : h[9];
                BOOL comment = version == 2 ? memcmp(h, "COM", 3) == 0
                        : memcmp(h, "COMM", 4) == 0 && (flags & ~(version == 4 ? 0x03u : 0u)) == 0;
                uint8_t body[512];
                SInt64 length = size;
                if (comment && size >= 5 && size <= (SInt64)sizeof body && VibeID3v2Read(context, decoded, stop, at + header, size, body)) {
                    if (flags & 0x02) length = VibeID3v2Resync(body, length);
                    SInt64 skip = flags & 0x01 ? 4 : 0;
                    found = length - skip >= 5 && VibeITunesGaplessText(body + skip, length - skip, priming, remainder, frames);
                }
                at += header + size;
            }
        }
        free(decoded);
        tag += bytes;
    }
    return found;
}

// The frames of a stream with no VBR header whose download runs: an estimate
// from its first frames, the first kVibeMPEGEstimateFrames waited for as any
// read is, and the rest already on disk. If they share the first's
// bit rate, the count is what that rate gives the audio's bytes. Otherwise it
// is the count at their average size. Either is an estimate, since a
// headerless file can change rate after its intro. 0 when too few frames
// walk.
- (SInt64)estimateMPEGPacketsAtRate:(UInt32)rate {
    if (![self indexMPEGThrough:kVibeMPEGEstimateFrames - 1]) {
        return 0;
    }
    SInt64 audio = _mpegOffsets[0], limit = MIN(MIN(_size, (SInt64)_availability.writtenBytes), audio + kVibeMPEGEstimateBytes);
    while (!_mpegWalkEnded && _mpegWalk + kVibeMPEGFrameCapacity <= limit && [self indexMPEGThrough:_mpegIndexed]) {
    }
    UInt64 bytes = (UInt64)(_mpegDataEnd - audio);
    SInt64 walked = _mpegWalk - audio;
    if (!_mpegConstantBitrate || _mpegFirstBitrate == 0) {
        return walked > 0 ? (SInt64)((bytes * (UInt64)_mpegIndexed + (UInt64)walked / 2) / (UInt64)walked) : 0;
    }
    // The nearest count: a frame a fraction of a byte long is padded to the
    // rate on average, and the bytes past the last whole frame are not one.
    UInt64 scale = (UInt64)_mpegFramesPerPacket * _mpegFirstBitrate;
    return (SInt64)((bytes * 8 * (UInt64)rate + scale / 2) / scale);
}

// Takes the stream from `start`, no further than `end`, for dr_mp3, in place
// of CoreAudio's parser. Its first frame must be at `start`, or, with `junk`,
// within kVibeMPEGSyncSpan of it, as CoreAudio plays a file named as MPEG
// with stray bytes after its tags. NO leaves the file to the parser.
//
// The first frame can be a Xing, Info or VBRI frame, which holds no audio. It
// states the frame count, and a LAME tag in it the encoder's priming and
// remainder. An iTunSMPB comment in the tags states them too. A stated count
// is trusted when it fits the file (below). The remainder is trimmed only
// when the stream holds exactly the packets stated. A stream whose download
// runs, without a count that fits, opens on an estimate
// (estimateMPEGPacketsAtRate:). Otherwise the walk counts every frame at
// open, as CoreAudio's parser did.
//
// CoreAudio's parser misses the Info frame of a mono or an MPEG-2 file, and
// stops counting packets where a stream changes mode. It refuses free format.
// The channels are the most any frame walked at open holds. The decode
// copies a mono frame into both channels, or mixes a stereo one down.
- (BOOL)openMPEGFrom:(SInt64)start to:(SInt64)end junk:(BOOL)junk interleaved:(BOOL)interleaved {
    _mpegDataEnd = end;
    _mpegFixed = 0;
    SInt64 first = [self syncMPEGFrom:start span:junk ? kVibeMPEGSyncSpan : 0];
    VibeMPEGFrame frame;
    // The first frame's head: its side information, then a Xing, Info or VBRI
    // tag with a LAME tag after it, in at most 36 + 120 + 36 bytes. Only the
    // frame's own bytes count. A tag found in the frames after a short one
    // took that frame for a header and stopped the stream at its count.
    uint8_t head[192] = {0};
    UInt32 got = 0;
    if (first < 0 || ![self mpegFrameAt:first frame:&frame]
            || VibeHandleRead((__bridge void *)self, first, MIN((UInt32)sizeof head, frame.bytes), head, &got) != noErr) {
        return NO;
    }
    // The tag after the side information, where LAME writes it.
    BOOL mpeg1 = frame.framesPerPacket == 1152, vbr = NO, gapless = NO;
    UInt32 x = 4 + (frame.channels == 1 ? (mpeg1 ? 17 : 9) : (mpeg1 ? 32 : 17));
    SInt64 stated = 0, statedBytes = 0, priming = 0, remainder = 0, frames = 0;
    if (frame.layer == 3 && x + 8 <= got && (memcmp(head + x, "Xing", 4) == 0 || memcmp(head + x, "Info", 4) == 0)) {
        vbr = YES;
        const uint8_t *tag = head + x;
        uint32_t flags = OSReadBigInt32(tag, 4), at = 8;
        if (flags & 1) { stated = OSReadBigInt32(tag, at); at += 4; }
        if (flags & 2) { statedBytes = OSReadBigInt32(tag, at); at += 4; }
        if (flags & 4) at += 100;
        if (flags & 8) at += 4;
        const uint8_t *lame = tag + at;
        if (x + at + 24 <= got && (memcmp(lame, "LAME", 4) == 0 || memcmp(lame, "Lavf", 4) == 0 || memcmp(lame, "Lavc", 4) == 0)) {
            gapless = YES;
            priming = lame[21] << 4 | lame[22] >> 4;
            remainder = (lame[22] & 0xF) << 8 | lame[23];
        }
    } else if (frame.layer == 3 && 36 + 18 <= got && memcmp(head + 36, "VBRI", 4) == 0) {
        vbr = YES;
        statedBytes = OSReadBigInt32(head, 36 + 10);
        stated = OSReadBigInt32(head, 36 + 14);
    }
    if (!gapless && VibeITunesGapless(self, start, &priming, &remainder, &frames) && !stated) {
        stated = (priming + remainder + frames) / frame.framesPerPacket;
    }
    _mpegWalk = vbr ? first + frame.bytes : first;
    _mpegFramesPerPacket = frame.framesPerPacket;
    _mpegFirstBitrate = frame.bitrate;
    _mpegConstantBitrate = YES;
    _mpegChannels = frame.channels;
    SInt64 packets = 0, estimate = 0;
    // A stated count must fit the file. Its byte count covers the audio but
    // for tags after it, and either count gives each frame a size a frame of
    // the stream can have. A damaged count of one frame played one frame, and
    // a header kept from a shorter stream stopped short.
    // TRAP: the bytes include the Xing, Info or VBRI frame itself, and the
    // count does not. Counted against the frames, they failed every 320 kbps
    // file at 44.1 kHz under 4.5 minutes, and its open walked every frame.
    SInt64 audio = end - first, slack = MAX((SInt64)kVibeMPEGTrailingBytes, audio / 16), bytes = statedBytes ?: audio;
    SInt64 counted = bytes - (vbr ? frame.bytes : 0);
    BOOL fits = stated > 0 && statedBytes <= audio && (!statedBytes || audio - statedBytes <= slack)
            && counted >= stated * frame.smallest && counted <= stated * frame.largest + (statedBytes ? 0 : slack);
    if (fits) {
        packets = stated;
    } else if (_availability.partURL && (estimate = [self estimateMPEGPacketsAtRate:frame.rate]) > 0 && !_mpegWalkEnded) {
        packets = kVibeMPEGPacketsUncounted;
    } else {
        estimate = 0;
        [self indexMPEGThrough:INT64_MAX];
        packets = _mpegIndexed;
    }
    AudioStreamBasicDescription description = {
        .mSampleRate = frame.rate, .mChannelsPerFrame = _mpegChannels, .mFramesPerPacket = frame.framesPerPacket,
        .mFormatID = frame.layer == 1 ? kAudioFormatMPEGLayer1 : frame.layer == 2 ? kAudioFormatMPEGLayer2 : kAudioFormatMPEGLayer3,
    };
    if (_waitError || packets == 0 || ![self takeFileFormat:description layout:nil interleaved:interleaved]
            || !(_mpeg = calloc(1, sizeof(*_mpeg))) || !(_mpegPacket = malloc(kVibeMPEGFrameCapacity))
            || !(_mpegPCM = calloc(DRMP3_MAX_SAMPLES_PER_FRAME, sizeof(float)))) {
        free(_mpeg);
        _mpeg = NULL;
        return NO;
    }
    if (estimate) {
        _mpegEstimate = estimate;
        atomic_store(&_lengthEstimated, true);
        LogInfo(@"MP3 stream: %@ has no VBR header; opens on %lld packets estimated from its head's frames",
                _url.lastPathComponent, estimate);
    }
    BOOL whole = !estimate && packets == stated;
    // Apple's decoder removes its own synthesis delay, tagged or not, and so
    // the same frames are skipped here.
    _mpegDelay = frame.layer == 3 ? 529 : 241;
    _mpegSkip = priming + _mpegDelay;
    _mpegPacketCount = packets;
    _length = MAX(0, (estimate ?: packets) * frame.framesPerPacket - priming - (whole ? remainder : 0));
    return YES;
}

// MPEG in a WAV's data chunk, which dr_wav refuses. Its frames must start the
// chunk.
- (BOOL)openMPEGInWAVInterleaved:(BOOL)interleaved {
    uint8_t chunk[8];
    UInt32 got = 0;
    for (SInt64 at = 12; at + 8 <= _size && VibeHandleRead((__bridge void *)self, at, 8, chunk, &got) == noErr && got == 8;) {
        SInt64 size = OSReadLittleInt32(chunk, 4);
        if (memcmp(chunk, "data", 4) == 0) {
            return [self openMPEGFrom:at + 8 to:MIN(_size, at + 8 + size) junk:NO interleaved:interleaved];
        }
        at += 8 + size + (size & 1);
    }
    return NO;
}

// An uncounted stream's count, settling its length: where the reads reached
// the stream's end, or once the download is complete. The walk has counted
// every frame either way.
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

// The walk reads every frame header it has not yet read, the rest of the
// file, which takes a long mix tens of milliseconds from disk and a stream
// the rest of its download, so it is paid only once downloaded.
- (void)countMPEGPacketsOnDisk {
    uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    [self indexMPEGThrough:INT64_MAX];
    if (_mpegWalkEnded && _mpegIndexed > 0) {
        [self settleMPEGPacketCount:_mpegIndexed when:[NSString stringWithFormat:@"once downloaded, counted from disk in %.1f ms",
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
    _mpegPosition = MIN(uncounted ? MAX(0, frame) : MIN(MAX(0, frame), _length), INT64_MAX / 2);
    if (uncounted && _mpegPosition >= _length) {
        __atomic_store_n(&_length, _mpegPosition + 1, __ATOMIC_RELAXED);
    }
    SInt64 packet = (_mpegPosition + _mpegSkip) / _mpegFramesPerPacket;
    _mpegNextPacket = MAX(0, packet - kVibeMPEGSeekPrerollPackets);
    memset(_mpeg, 0, sizeof(*_mpeg));
    _mpegPCMFrames = _mpegPCMOffset = _mpegPacketBytes = 0;
    if (_mpegFramesPerPacket == 576) {
        // MPEG-2 Layer III, a granule a packet: the target's output
        // depends on the two packets before it, and the first of those on
        // 255 bytes of payload before it, which at 8 kbps can be 255
        // packets. A packet's header, a CRC and its side info are not
        // payload.
        SInt64 reach = 255, overhead = 4 + 2 + (_processingFormat.channelCount == 1 ? 9 : 17);
        SInt64 start = MAX(0, MIN(packet, _mpegPacketCount) - 2);
        [self indexMPEGThrough:start - 1];
        for (start = MIN(start, _mpegIndexed); reach > 0 && start > 0; start--) {
            reach -= (SInt64)_mpegSizes[start - 1] - overhead;
        }
        _mpegNextPacket = MIN(_mpegNextPacket, start);
    }
    return [self reportWaitFault:error];
}

- (BOOL)readMPEGIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error {
    if (atomic_load_explicit(&_lengthEstimated, memory_order_relaxed) && VibeHandleAwaitWhole(self, NO)) {
        // TRAP: here, on the one thread that reads the handle, since the
        // walk is not thread-safe: the bus's decode queue, or a waveform's.
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
            DSPSplitComplex planar = {planes[0] + total, planes[1] + total};
            vDSP_ctoz((const DSPComplex *)from, 2, &planar, 1, frames);
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
    if (_mpegNextPacket < _mpegPacketCount && ![self indexMPEGThrough:_mpegNextPacket]) {
        if (_waitError) {
            return [self reportWaitFault:error];
        }
        // A truncated or damaged file holds fewer packets than it states.
        if (_mpegPacketCount == kVibeMPEGPacketsUncounted) {
            [self settleMPEGPacketCount:_mpegIndexed when:@"where its reads reached the stream's end"];
        } else {
            _mpegPacketCount = _mpegIndexed;
        }
    }
    // After the last packet, the flush: the last decoded header over silence
    // drains the filterbank's delay, ending where Apple's decode ends, which
    // zero-fills it instead.
    BOOL flush = _mpegNextPacket == _mpegPacketCount;
    if (_mpegNextPacket > _mpegPacketCount || (flush && (_mpegPacketBytes == 0 || _mpeg->header[0] != 0xff))) {
        return YES;
    }
    if (flush) {
        // Written over the last packet in place: nothing reads it again,
        // since only a seek moves the cursor back and a seek drops it.
        memcpy(_mpegPacket, _mpeg->header, sizeof(_mpeg->header));
        memset(_mpegPacket + sizeof(_mpeg->header), 0, _mpegPacketBytes - sizeof(_mpeg->header));
    } else {
        UInt32 bytes = _mpegSizes[_mpegNextPacket], got = 0;
        OSStatus status = VibeHandleRead((__bridge void *)self, _mpegOffsets[_mpegNextPacket], bytes, _mpegPacket, &got);
        if (_waitError) {
            return [self reportWaitFault:error];
        }
        if (status != noErr || got != bytes) {
            if (error) {
                *error = VibeHandleError(status ?: kAudioFilePositionError,
                                         [NSString stringWithFormat:@"Reading %@ failed (%d)", _url.lastPathComponent, (int)status]);
            }
            return NO;
        }
        _mpegPacketBytes = bytes;
    }
    SInt64 first = _mpegNextPacket * _mpegFramesPerPacket - _mpegSkip;
    _mpegNextPacket++;
    UInt32 channels = _processingFormat.channelCount;
    drmp3dec_frame_info info = {0};
    // TRAP: dr_mp3 resets itself, reservoir and all, at a header unlike the
    // one it holds, a frame without a bit rate after one with one included,
    // and finds a free format frame's size only from the next header in what
    // it is handed. It is handed one frame, its size the walk's. So it holds
    // each frame's header before it decodes, and a free format frame's size.
    // Without the size every such frame decoded to nothing.
    VibeMPEGFrame packet;
    memcpy(_mpeg->header, _mpegPacket, sizeof(_mpeg->header));
    if (VibeMPEGParse(_mpegPacket, &packet) && packet.bitrate == 0) {
        _mpeg->free_format_bytes = (int)(_mpegPacketBytes - packet.padding);
    }
    int frames = drmp3dec_decode_frame(_mpeg, _mpegPacket, (int)_mpegPacketBytes, _mpegPCM, &info);
    if (frames != (int)_mpegFramesPerPacket) {
        // A frame whose reservoir bytes precede a seek's preroll, or a
        // damaged one: silence, keeping the timeline.
        memset(_mpegPCM, 0, (size_t)_mpegFramesPerPacket * channels * sizeof(float));
    } else {
        if (info.channels == 1 && channels == 2) {
            for (int f = frames - 1; f >= 0; f--) {
                _mpegPCM[2 * f] = _mpegPCM[2 * f + 1] = _mpegPCM[f];
            }
        } else if (info.channels == 2 && channels == 1) {
            for (int f = 0; f < frames; f++) {
                _mpegPCM[f] = (_mpegPCM[2 * f] + _mpegPCM[2 * f + 1]) * 0.5f;
            }
        }
        const float low = -kVibeDecodeSampleBound, high = kVibeDecodeSampleBound;
        vDSP_vclip(_mpegPCM, 1, &low, &high, _mpegPCM, 1, (vDSP_Length)frames * channels);
    }
    _mpegPCMFrames = flush ? _mpegDelay : _mpegFramesPerPacket;
    _mpegPCMOffset = (UInt32)MIN(MAX(0, _mpegPosition - first), (SInt64)_mpegPCMFrames);
    return YES;
}

@end
