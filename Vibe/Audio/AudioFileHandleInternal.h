//
//  AudioFileHandleInternal.h
//  Vibe
//
//  The private header AudioFileHandle.m and its decodes share: dr_mp3's
//  (AudioFileHandle+MPEG.m), and dr_flac's, dr_wav's and libvorbis's
//  (AudioFileHandle+Stream.m). It holds the ivars the decodes read, the reads
//  and waits they call, and the decodes' methods the core calls. Only those
//  three files import it.
//

#import "AudioFileHandle.h"

#include "dr_mp3/dr_mp3.h"
#include "dr_flac/dr_flac.h"
#include "dr_wav/dr_wav.h"
#include <vorbis/vorbisfile.h>

#include <stdatomic.h>

@class CloudFileAvailability;

// The bound on a decoded sample where damage can run past it: a damaged MP3
// frame, or an Opus header's gain. dr_mp3 never clamps, and one damaged frame
// can decode past +90 dBFS. The FX's reverb and delay then ring at full scale
// for seconds, the equalizer's reference stays up for half a minute, and the
// track's detected tempo moves. The bound, +12 dBFS, sits well above any real
// master's overs (docs/audio-quality.md).
static const float kVibeDecodeSampleBound = 4.0f;

// Small reads go through one block: the parser's under kVibeReadBlock, filling
// all of it — Apple's Ogg reader asks for about 200 bytes at a time on Opus,
// 18,000 reads for three minutes — and dr_flac's 4 KB ones, filling a quarter:
// a seek's bisection probes a few KB at each position it tries, and dr_wav's
// larger reads gain nothing from a copy. Anything bigger is read straight
// through.
enum { kVibeReadBlock = 64 * 1024, kVibeStreamReadSmall = 4096, kVibeStreamReadFill = 16 * 1024 };

@interface AudioFileHandle () {
    // The properties' own, declared here so the decode reads them directly.
    NSURL *_url;
    AVAudioFormat *_fileFormat;
    AVAudioFormat *_processingFormat;
    SInt64 _size;
    // Written by the decode of a stream counting its MPEG packets as it
    // goes, and read on any thread, hence the getter's atomic load.
    AVAudioFramePosition _length;
    AudioFileID _parser;
    ExtAudioFileRef _codec; // NULL while dr_mp3, dr_flac, dr_wav or libvorbis decodes
    // A file still streaming, or reading ahead: every read waits for its
    // bytes. Set by the open and fixed from then on. Nil for a whole file.
    CloudFileAvailability *_availability;
    // Latched by the wait that answered no, so each decoder sees one clean
    // end of data, never bytes after a gap, and its read or seek reports why:
    // the transfer's error, for good, or an interruption, until the next seek.
    NSError *_waitError;
    // dr_mp3's decode: the stream's frames, its packets, on a timeline of
    // packet × framesPerPacket, with _mpegSkip frames before logical frame 0.
    drmp3dec *_mpeg;
    uint8_t *_mpegPacket;    // the packet decoded last
    UInt32 _mpegPacketBytes; // 0 when none is held
    // The frames walked so far: each one's offset and size, in stream order.
    // The walk goes on from _mpegWalk, and has ended at the data's end.
    SInt64 *_mpegOffsets;
    uint16_t *_mpegSizes;
    SInt64 _mpegIndexed;
    SInt64 _mpegIndexCapacity;
    SInt64 _mpegWalk;
    SInt64 _mpegDataEnd;
    BOOL _mpegWalkEnded;
    // What every frame of the stream shares (VibeMPEGFrame.fixed), and a free
    // format stream's frame size before its padding.
    UInt32 _mpegFixed;
    UInt32 _mpegFreeBytes;
    UInt32 _mpegFirstBitrate;
    BOOL _mpegConstantBitrate;
    UInt32 _mpegChannels; // the most any frame walked holds
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
    // dr_flac's, dr_wav's or libvorbis's decode, at most one: the stream read
    // through the descriptor at a cursor of its own.
    drflac *_flac;
    drwav *_wav; // &_wavState once drwav_init has succeeded
    drwav _wavState;
    OggVorbis_File *_vorbis;
    // The frame libvorbis's next read delivers, counted here. vorbisfile's own
    // follows the pages' granule positions, and damage can set those to
    // anything.
    SInt64 _vorbisPosition;
    SInt64 _streamCursor;
    BOOL _streamReadFailed; // a pread failed, which no stream decoder can tell from the end
}

- (BOOL)reportWaitFault:(NSError **)error;
- (BOOL)takeFileFormat:(AudioStreamBasicDescription)description layout:(AVAudioChannelLayout *)layout
           interleaved:(BOOL)interleaved;

@end

// AudioFileHandle+MPEG.m. The stream open calls the opens, and the core
// calls the rest from its own methods' MPEG branches.
@interface AudioFileHandle (MPEG)

- (BOOL)openMPEGFrom:(SInt64)start to:(SInt64)end junk:(BOOL)junk interleaved:(BOOL)interleaved;
- (BOOL)openMPEGInWAVInterleaved:(BOOL)interleaved;
- (void)countMPEGPacketsOnDisk;
- (BOOL)seekMPEGToFrame:(AVAudioFramePosition)frame error:(NSError **)error;
- (BOOL)readMPEGIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error;

@end

// AudioFileHandle+Stream.m. The open tries it before CoreAudio's parser, the
// reads and seeks call the stream decoders' branches, and dealloc closes the
// decoder.
@interface AudioFileHandle (Stream)

- (BOOL)openOwnDecoderInterleaved:(BOOL)interleaved mpeg:(BOOL)mpeg;
- (void)closeStreamDecoder;
- (BOOL)readStreamIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error;

@end

// AudioFileHandle.m's reads and waits, which the decode's open also uses.
uint32_t VibeID3v2TagBytes(const uint8_t header[10]);
AudioFileTypeID VibeFileTypeForExtension(NSString *extension);
NSError *VibeHandleError(OSStatus status, NSString *description);
BOOL VibeHandleAwait(AudioFileHandle *handle, SInt64 position, SInt64 count,
                     void *window, uint64_t capacity, uint64_t *copied);
BOOL VibeHandleAwaitWhole(AudioFileHandle *handle, BOOL wait);
ssize_t VibeHandleFetch(AudioFileHandle *handle, SInt64 position, SInt64 requested, void *buffer, size_t capacity);
OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount);

// AudioFileHandle.m's byte reads for dr_flac, dr_wav and vorbisfile. The
// stream opens pass them to the decoders. They stay beside the parser's
// reads, because the block read they call on every read is static there.
size_t VibeStreamRead(void *user, void *buffer, size_t count);
drflac_bool32 VibeFLACSeek(void *user, int offset, drflac_seek_origin origin);
drwav_bool32 VibeWAVSeek(void *user, int offset, drwav_seek_origin origin);
drflac_bool32 VibeStreamTell(void *user, drflac_int64 *cursor);
size_t VibeVorbisRead(void *buffer, size_t size, size_t count, void *user);
int VibeVorbisSeek(void *user, ogg_int64_t offset, int whence);
long VibeVorbisTell(void *user);
