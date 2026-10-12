//
//  AudioFileHandleInternal.h
//  Vibe
//
//  The private header AudioFileHandle.m and its MPEG decode
//  (AudioFileHandle+MPEG.m) share: the ivars the decode reads, the reads and
//  waits it calls, and the decode's methods the core calls. Only those two
//  files import it.
//

#import "AudioFileHandle.h"

#include "dr_mp3/dr_mp3.h"

#include <stdatomic.h>

@class CloudFileAvailability;

// Packets asked of the parser at once, sparing it about four small reads
// per MP3 frame, which were a tenth of the whole decode's time.
enum { kVibeMPEGReadPackets = 16 };

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
    AVAudioFormat *_processingFormat;
    SInt64 _size;
    // Written by the decode of a stream counting its MPEG packets as it
    // goes, and read on any thread, hence the getter's atomic load.
    AVAudioFramePosition _length;
    AudioFileID _parser;
    ExtAudioFileRef _codec; // NULL while dr_mp3, dr_flac or dr_wav decodes
    // A file still streaming, or reading ahead: every read waits for its
    // bytes. Set by the open and fixed from then on. Nil for a whole file.
    CloudFileAvailability *_availability;
    // Latched by the wait that answered no, so each decoder sees one clean
    // end of data, never bytes after a gap, and its read or seek reports why:
    // the transfer's error, for good, or an interruption, until the next seek.
    NSError *_waitError;
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
    SInt64 _mpegEstimate;    // an uncounted stream's packets at open, for the settle's log
    _Atomic bool _lengthEstimated;
    SInt64 _mpegNextPacket;
    SInt64 _mpegPosition; // logical frame the next read delivers
    float *_mpegPCM;      // one packet's frames, interleaved
    UInt32 _mpegPCMFrames;
    UInt32 _mpegPCMOffset;
}

- (BOOL)reportWaitFault:(NSError **)error;

@end

// AudioFileHandle+MPEG.m. The core calls each from its own method's MPEG
// branch.
@interface AudioFileHandle (MPEG)

- (BOOL)openMPEGWithDescription:(AudioStreamBasicDescription)description;
- (void)countMPEGPacketsOnDisk;
- (BOOL)seekMPEGToFrame:(AVAudioFramePosition)frame error:(NSError **)error;
- (BOOL)readMPEGIntoBuffer:(AVAudioPCMBuffer *)buffer frameCount:(AVAudioFrameCount)wanted error:(NSError **)error;

@end

// AudioFileHandle.m's reads and waits, which the decode's open also uses.
uint32_t VibeID3v2TagBytes(const uint8_t header[10]);
NSError *VibeHandleError(OSStatus status, NSString *description);
BOOL VibeHandleAwait(AudioFileHandle *handle, SInt64 position, SInt64 count,
                     void *window, uint64_t capacity, uint64_t *copied);
BOOL VibeHandleAwaitWhole(AudioFileHandle *handle, BOOL wait);
OSStatus VibeHandleRead(void *clientData, SInt64 position, UInt32 requestCount, void *buffer, UInt32 *actualCount);
