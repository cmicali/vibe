//
//  AudioVoiceBusInternal.h
//  Vibe
//
//  The bus's private header: the slot and mix the audio thread reads, the
//  record the queue and the decoder share, the ivars, and the decoder's
//  methods the queue calls. The bus is three files: AudioVoiceBus.m is the
//  queue side, AudioVoiceBusRender.m the render and AudioVoiceBus+Decoder.m
//  the decode pool's side. Only they and the tests import this. The host-less
//  suite calls VibeVoiceBusRender directly over the bus's mix and buffers,
//  with no pipeline.
//

#import "AudioVoiceBus.h"

#import <os/lock.h>
#include <stdatomic.h>

NS_ASSUME_NONNULL_BEGIN

enum {
    kVoiceSlots = 8,
    kMaxBusChannels = 8,
    kDecodeChunkFrames = 4096,
    // A voice goes live with this much buffered: one chunk, so a start costs
    // one decode and one IO cycle. Fills yield after each chunk so voices
    // handing off the same file never queue behind a full fill.
    kLiveThresholdFrames = kDecodeChunkFrames,
    // Below this the drain re-kicks the decoder. Half a ring holds at least
    // 0.5 s. The player's steady drain interval is 100 ms.
    kLowWaterDivisor = 2,
    // Free slots at or below which a start cuts the oldest retiring voice.
    kFreeSlotReserve = 2,
    // A resampler stays open past its file's last frame while the render is
    // at least this far behind it, so a successor named late still continues
    // it; nearer, its tail is flushed and the end declared.
    kOpenStreamReserveFrames = 2 * kDecodeChunkFrames,
};

typedef NS_ENUM(int32_t, VibeSuccessorState) {
    VibeSuccessorNone = 0,
    VibeSuccessorQueued,
    VibeSuccessorSwitching,
};

// Where a voice's stream stands past its file's frames.
typedef NS_ENUM(int32_t, VibeStreamState) {
    VibeStreamReading = 0,  // the file has frames
    VibeStreamDrained,      // the file ran out; the stream is open for a successor
    VibeStreamFlushing,     // the end is decided; a resampler's tail is coming
    VibeStreamEnded,        // endOfStream is published
};

static const uint64_t kUnset = UINT64_MAX;

// One 64-bit word carries a whole ramp request, so the queue can replace it
// atomically and the audio thread adopts it whole: target gain (16 bits),
// frames (24), curve (2), action (2), sequence (20). The sequence changing
// is what the audio thread notices; equality, never ordering.
static inline uint64_t VibeRampWord(float target, uint32_t frames, VibeFadeCurve curve,
                                    VibeVoiceAction action, uint32_t sequence) {
    uint64_t q = (uint64_t)llroundf(fminf(fmaxf(target, 0.0f), 1.0f) * 65535.0f);
    uint64_t f = frames > 0xFFFFFF ? 0xFFFFFF : frames;
    return q | (f << 16) | ((uint64_t)(curve & 3) << 40) | ((uint64_t)(action & 3) << 42)
            | ((uint64_t)(sequence & 0xFFFFF) << 44);
}

// A timestamp the audio thread writes and any thread reads: the sample
// time's bits, the host time and the flags, each an atomic word, under the
// slot's version so a reader can tell a torn copy.
typedef struct {
    _Atomic uint64_t sampleTimeBits;
    _Atomic uint64_t hostTime;
    _Atomic uint32_t flags;
} VibeVoiceStamp;

// The slot the audio thread reads. Plain C, no pointers to Objective-C.
// The comments name active writers. Binding and recycling initialize fields.
typedef struct {
    // Queue, before the generation's release-store publishes the allocation.
    // The generation is also the seqlock's version over every field a bind
    // writes (bindRecord:toSlot:), and the two origins a snapshot subtracts
    // are atomics: a snapshot polls them while a rebind writes them.
    _Atomic uint64_t generation;
    _Atomic uint64_t armedWritten;
    _Atomic uint64_t armedConsumed;
    // A VibeVoiceState, None while the slot is free. Queue: free→armed,
    // armed→dead. Decoder: armed→live or armed→dead. Audio thread: live→dead.
    _Atomic int32_t state;
    // Decoder. `written` is the ring's producer index, absolute for the slot's
    // life; `endOfStream` and `boundary` are absolute too, kUnset until known.
    _Atomic uint64_t written;
    _Atomic uint64_t endOfStream;
    _Atomic uint64_t boundary;
    _Atomic int32_t successorState; // the decoder wins queued→switching; the queue wins queued→none
    _Atomic int32_t readsAllowed;   // the queue clears it for a declick retire
    // Queue.
    _Atomic uint64_t ramp;
    // Audio thread.
    _Atomic uint64_t consumed;      // the ring's consumer index, absolute
    _Atomic int32_t paused;
    _Atomic int32_t endedReason;
    _Atomic uint64_t underrun;
    _Atomic uint64_t diedAtRender;
    _Atomic uint32_t stampVersion;  // odd while the stamp below is being written
    VibeVoiceStamp startStamp;
    // Audio thread, private: the ramp in progress and the current gain. The
    // gain is an atomic only so the diagnostic snapshot may read it; it has
    // no other writer while the slot is live.
    _Atomic float gain;
    float rampFrom;
    float rampTo;
    uint32_t rampFrames;
    uint32_t rampElapsed;
    int32_t rampCurve;
    int32_t rampAction;
    uint32_t rampSequence;
    int32_t consuming;
} VibeVoiceSlot;

struct VibeVoiceMix {
    uint32_t channels;
    uint32_t capacity;  // frames per ring, a power of two
    uint32_t mask;
    double hostTicksPerFrame;
    float *_Null_unspecified rings[kVoiceSlots][kMaxBusChannels];
    float *gains;       // the render's scratch: a fading voice's gain per frame, kVibeVoiceBusMaxRenderFrames long
    VibeVoiceSlot slots[kVoiceSlots];
    // Bumped at the end of every render; inRender brackets each one, so the
    // queue can tell "no render is inside any slot" from "the output says it
    // is stopped", which on iOS the render thread can lag.
    _Atomic uint64_t renderSequence;
    _Atomic int32_t inRender;
    // Debug builds only. A test's stuck render: while set, a render blocks
    // inside the bus after it has entered — inRender up, the sequence unmoved —
    // and rendersHeld counts the renders blocked there.
    _Atomic int32_t holdRender;
    _Atomic int32_t rendersHeld;
};

// Whether the decoder could write for the slot: its reads allowed, and no
// end published — or a successor queued past one, which a turn reopens the
// stream for. The drain asks before it schedules a turn; the turn asks first.
static inline BOOL VibeSlotCanWrite(VibeVoiceSlot *s) {
    return atomic_load_explicit(&s->readsAllowed, memory_order_acquire)
            && (atomic_load_explicit(&s->endOfStream, memory_order_relaxed) == kUnset
                || atomic_load_explicit(&s->successorState, memory_order_relaxed) != VibeSuccessorNone);
}

static inline BOOL VibeSlotIsOccupied(VibeVoiceSlot *s) {
    return atomic_load_explicit(&s->state, memory_order_acquire) != VibeVoiceStateNone;
}

// NO for a voice that is dead, retired at declick length, failed, or already
// continuing into a successor.
static inline BOOL VibeSlotTakesSuccessor(VibeVoiceSlot *s) {
    int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
    return (state == VibeVoiceStateArmed || state == VibeVoiceStateLive)
            && atomic_load_explicit(&s->readsAllowed, memory_order_acquire)
            && atomic_load_explicit(&s->endedReason, memory_order_acquire) != VibeVoiceEndFailed
            && atomic_load_explicit(&s->successorState, memory_order_acquire) == VibeSuccessorNone;
}

// The reader's half of the stamp seqlock (VibeStampWrite, AudioVoiceBusRender.m).
static inline AudioTimeStamp VibeStampRead(const VibeVoiceStamp *field) {
    AudioTimeStamp stamp = {0};
    uint64_t bits = atomic_load_explicit(&field->sampleTimeBits, memory_order_relaxed);
    memcpy(&stamp.mSampleTime, &bits, sizeof(bits));
    stamp.mHostTime = atomic_load_explicit(&field->hostTime, memory_order_relaxed);
    stamp.mFlags = atomic_load_explicit(&field->flags, memory_order_relaxed);
    return stamp;
}

// What the audio thread must never see: the file, its resampler and buffers,
// the queued successor, and the drain's once-only event flags. The successor
// pointer is written by the queue and read by the decoder only across the
// successorState CAS, which orders them.
@interface AudioVoiceRecord : NSObject {
@public
    VibeVoiceID identifier;
    AudioFileHandle *file;
    VibeResampler *resampler;        // disposed with the record, or when it is re-prepared
    AVAudioPCMBuffer *readBuffer;    // the file's processing format
    AVAudioPCMBuffer *mixBuffer;     // the bus's channels at the file's rate, what a resampler takes after the mix
    AVAudioPCMBuffer *stageBuffer;   // the bus format, what the ring takes; one per slot for the bus's life
    NSData *mixMap;                  // Float32[source channels][bus channels], when channel counts or layouts differ
    NSError *failure;               // decoder writes, queue reads under _tableLock
    NSDictionary *conversion;        // how the file reaches the bus, for conversionOfVoice:; _tableLock; nil = direct
    // The resampler's frames: what it has been fed since it was made, and the
    // ring position it began at, so a stream's end in the ring is computed
    // rather than read off `written`, which the resampler's filter holds
    // back from by its length.
    uint64_t fedFrames;
    uint64_t convertedBase;
    AVAudioFramePosition startFrame;
    AVAudioFramePosition endFrame;   // exclusive; 0 = the file's own end
    // The next frame a read delivers, counted from the seek rather than asked
    // of the file: framePosition answers 0 when ExtAudioFileTell fails, and an
    // end clamped against that reads into the next window.
    AVAudioFramePosition cursor;
    BOOL positioned;
    VibeStreamState stream;
    BOOL readInterrupted;            // the decoder's: this turn's read or seek ended as an interruption
    AudioFileHandle *successorFile;
    AudioFileHandle *waitingSuccessor; // accepted, not yet the decoder's: the start is pending, or another queue reads it
    // The window the successor — waiting or queued — is read over, carried
    // with it through every hand-off.
    AVAudioFramePosition successorStartFrame;
    AVAudioFramePosition successorEndFrame;
    uint64_t retireOrder;            // when a retire ramp was submitted; 0 = not retiring
    _Atomic int32_t fillScheduled;
    // The decoder's: `written` when it last held a drained stream open for a
    // late successor, kUnset from the bind. Only a match with `written` is a
    // current hold: a successor that continued the stream has written past
    // it, and a stale hold read as current keeps the drain prompt for the
    // rest of the voice.
    _Atomic uint64_t heldOpenAt;
    BOOL liveReported;
    uint64_t reportedBoundary;      // the last boundary the drain reported; kUnset = none
    BOOL endedReported;
    // A pending voice's start, replayed when a slot frees.
    float gain;
    VibeVoiceRamp ramp;
    BOOL paused;
    BOOL readsStopped;
    dispatch_queue_t decodeQueue;   // bound before generation is published; recycle on this queue precedes any rebind
    BOOL readsWithheld;              // started on a withheld file: reads allowed once allowReadsOfFile: says so
}
@end

@interface AudioVoiceBus () {
    // The properties' storage the categories read, declared so they see it.
    AVAudioFormat *_format;
    BOOL _inlineDecoding;
    dispatch_block_t _needsDrain;
    dispatch_queue_t _queue;
    dispatch_queue_t _decodeQueues[kVoiceSlots];
    _Atomic uint64_t _decodeTurns;   // turns run so far, for the tests
    NSMutableSet<AudioFileHandle *> *_withheldFiles; // a retired decoder may be inside these; queue-owned
    float *_mixStorage;
    VibeVoiceMix *_mix;
    AudioVoiceRecord *_records[kVoiceSlots];
    NSMutableArray<AudioVoiceRecord *> *_pending;
    NSMutableArray<NSNumber *> *_endedPending; // killed before a slot; the next drain reports them ended
    // id → slot and record data for cross-thread lookups. Never
    // taken by the audio thread; never held across a queue hop.
    os_unfair_lock _tableLock;
    VibeVoiceID _slotIdentifiers[kVoiceSlots];
    uint64_t _nextIdentifier;
    uint32_t _rampSequence;
    uint64_t _nextRetireOrder;
    // Debug builds only. Decode-thread CPU spent resampling (the fill less
    // the file reads inside it), and the bus frames it produced.
    _Atomic uint64_t _debugResampleNanos;
    _Atomic uint64_t _debugResampledFrames;
    // Debug builds only. While set, every decode turn waits at its start, as
    // one stuck in a stalled read would.
    _Atomic int32_t _debugHoldDecoder;
}
@end

// The decode pool's side of the bus (AudioVoiceBus+Decoder.m): what the queue
// side calls.
@interface AudioVoiceBus (Decoder)

- (BOOL)prepareRecord:(AudioVoiceRecord *)record file:(AudioFileHandle *)file;
- (void)recordFailure:(nullable NSError *)error forSlot:(NSUInteger)slot;
- (void)endFailedSlot:(NSUInteger)slot frames:(uint32_t)frames written:(uint64_t)written;
- (void)recycleSlot:(NSUInteger)slot generation:(VibeVoiceID)generation;
- (void)scheduleFillForSlot:(NSUInteger)slot;
- (BOOL)decodeChunkForSlot:(NSUInteger)slot;
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final;

@end

// The test seam. The race tests also hold the decode queue inside the
// decoder's steps above: prepareRecord:file:, produceChunkForSlot:final: and
// recycleSlot:generation:.
@interface AudioVoiceBus (Testing)

// A queue of the decode pool, nil past its last or under inline decoding: the
// race tests hold it.
- (nullable dispatch_queue_t)decodeQueueAtIndex:(NSUInteger)index;

// Slots in each state, for the pool tests.
- (NSUInteger)slotCountInState:(VibeVoiceState)state;
- (NSUInteger)pendingVoiceCount;

@end

NS_ASSUME_NONNULL_END
