//
//  AudioVoiceBus.m
//  Vibe
//

#import "AudioVoiceBusInternal.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <sched.h>
#include <stdatomic.h>

enum {
    kVoiceSlots = 8,
    kMaxBusChannels = 8,
    kDecodeChunkFrames = 4096,
    // A voice goes live with this much buffered: one chunk, so a start costs
    // one decode and one IO cycle. The initial fill then stops at eight
    // chunks and the drain tops the ring up, so a skip storm's next start
    // never waits behind a full-ring fill on the decode queue.
    kLiveThresholdFrames = kDecodeChunkFrames,
    kInitialFillFrames = 8 * kDecodeChunkFrames,
    // Below this the drain re-kicks the decoder. Half a ring is ~0.7 s at
    // every rate, against a ≤10 ms poll and a sub-10 ms chunk decode.
    kLowWaterDivisor = 2,
    // Free slots at or below which a start cuts the oldest retiring voice.
    kFreeSlotReserve = 2,
    // A converter stays open past its file's last frame while the render is
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
    VibeStreamFlushing,     // the end is decided; a converter's tail is coming
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

// The slot the audio thread reads. Plain C, no pointers to Objective-C.
// The comments name each field's ONE writer; every other party only reads.
typedef struct {
    // Queue, before the generation's release-store publishes the allocation.
    _Atomic uint64_t generation;
    uint64_t armedWritten;
    uint64_t armedConsumed;
    // A VibeVoiceState, None while the slot is free. Queue: free→armed,
    // armed→dead. Decoder: armed→live. Audio thread: live→dead.
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
    _Atomic uint32_t stampVersion;  // odd while the stamps below are being written
    AudioTimeStamp startStamp;
    AudioTimeStamp boundaryStamp;
    AudioTimeStamp lastStamp;
    // Audio thread, private: the ramp in progress and the current gain.
    float gain;
    float rampFrom;
    float rampTo;
    uint32_t rampFrames;
    uint32_t rampElapsed;
    int32_t rampCurve;
    int32_t rampAction;
    uint32_t rampSequence;
    int32_t consuming;
} VibeVoiceSlot;

typedef struct {
    uint32_t channels;
    uint32_t capacity;  // frames per ring, a power of two
    uint32_t mask;
    double hostTicksPerFrame;
    float *rings[kVoiceSlots][kMaxBusChannels];
    VibeVoiceSlot slots[kVoiceSlots];
    // Bumped at the end of every render; inRender brackets each one, so the
    // queue can tell "no render is inside any slot" from "the engine says it
    // is stopped", which on iOS the render thread can lag.
    _Atomic uint64_t renderSequence;
    _Atomic int32_t inRender;
} VibeVoiceMix;

// The block's capture. Attached to the source node as an associated object,
// so the slot memory lives exactly as long as the block that reads it: a late
// render from a defunct engine touches valid memory whatever the bus did.
@interface VibeVoiceMixOwner : NSObject
@property (nonatomic, readonly) VibeVoiceMix *mix;
@end

@implementation VibeVoiceMixOwner {
    float *_storage;
}
- (instancetype)initWithChannels:(uint32_t)channels capacity:(uint32_t)capacity hostTicksPerFrame:(double)ticks {
    self = [super init];
    if (self) {
        _mix = calloc(1, sizeof(VibeVoiceMix));
        _storage = calloc((size_t)kVoiceSlots * channels * capacity, sizeof(float)); // touched here, never first on the audio thread
        if (!_mix || !_storage) {
            return nil;
        }
        _mix->channels = channels;
        _mix->capacity = capacity;
        _mix->mask = capacity - 1;
        _mix->hostTicksPerFrame = ticks;
        for (uint32_t s = 0; s < kVoiceSlots; s++) {
            for (uint32_t c = 0; c < channels; c++) {
                _mix->rings[s][c] = _storage + ((size_t)s * channels + c) * capacity;
            }
            atomic_init(&_mix->slots[s].endOfStream, kUnset);
            atomic_init(&_mix->slots[s].boundary, kUnset);
        }
    }
    return self;
}
- (void)dealloc {
    free(_storage);
    free(_mix);
}
@end

#pragma mark - The audio thread

static inline void VibeStampWrite(VibeVoiceSlot *slot, AudioTimeStamp *field, const AudioTimeStamp *base,
                                  uint64_t frameOffset, double ticksPerFrame) CA_REALTIME_API {
    AudioTimeStamp stamp = *base;
    if (stamp.mFlags & kAudioTimeStampSampleTimeValid) {
        stamp.mSampleTime += (Float64)frameOffset;
    }
    if (stamp.mFlags & kAudioTimeStampHostTimeValid) {
        stamp.mHostTime += (UInt64)((double)frameOffset * ticksPerFrame);
    }
    atomic_fetch_add_explicit(&slot->stampVersion, 1, memory_order_release);
    *field = stamp;
    atomic_fetch_add_explicit(&slot->stampVersion, 1, memory_order_release);
}

static void VibeVoiceDie(VibeVoiceSlot *slot, int32_t reason, uint64_t renderSequence) CA_REALTIME_API {
    int32_t expected = VibeVoiceStateLive;
    int32_t none = VibeVoiceEndNone;
    atomic_compare_exchange_strong_explicit(&slot->endedReason, &none, reason,
                                            memory_order_relaxed, memory_order_relaxed);
    atomic_store_explicit(&slot->diedAtRender, renderSequence, memory_order_relaxed);
    atomic_compare_exchange_strong_explicit(&slot->state, &expected, VibeVoiceStateDead,
                                            memory_order_release, memory_order_relaxed);
}

// Everything the audio thread does. Plain memory and atomics, no call that
// can block; the pragma below makes the compiler hold that line.
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wfunction-effects"
#endif
static OSStatus VibeVoiceBusRender(VibeVoiceMix *mix, BOOL *isSilence, const AudioTimeStamp *timestamp,
                                   AVAudioFrameCount frameCount, AudioBufferList *output) CA_REALTIME_API {
    atomic_store_explicit(&mix->inRender, 1, memory_order_seq_cst);
    uint64_t renderSequence = atomic_load_explicit(&mix->renderSequence, memory_order_relaxed);
    uint32_t channels = output->mNumberBuffers < mix->channels ? output->mNumberBuffers : mix->channels;
    for (uint32_t c = 0; c < output->mNumberBuffers; c++) {
        memset(output->mBuffers[c].mData, 0, output->mBuffers[c].mDataByteSize);
    }
    BOOL mixed = NO;
    for (uint32_t s = 0; s < kVoiceSlots; s++) {
        VibeVoiceSlot *slot = &mix->slots[s];
        if (atomic_load_explicit(&slot->state, memory_order_acquire) != VibeVoiceStateLive) {
            continue;
        }
        // Adopt a new ramp from the current gain. Adoption un-pauses, which is
        // how a resume, a seek's fade-in and a cancelled pause all work with
        // no resume action; zero frames land at once.
        uint64_t word = atomic_load_explicit(&slot->ramp, memory_order_acquire);
        uint32_t sequence = (uint32_t)(word >> 44) & 0xFFFFF;
        if (sequence != 0 && sequence != slot->rampSequence) {
            slot->rampSequence = sequence;
            slot->rampFrom = slot->gain;
            slot->rampTo = (float)(word & 0xFFFF) / 65535.0f;
            slot->rampFrames = (uint32_t)((word >> 16) & 0xFFFFFF);
            slot->rampElapsed = 0;
            slot->rampCurve = (int32_t)((word >> 40) & 3);
            slot->rampAction = (int32_t)((word >> 42) & 3);
            atomic_store_explicit(&slot->paused, 0, memory_order_relaxed);
            if (slot->rampFrames == 0) {
                slot->gain = slot->rampTo;
                if (slot->rampAction == VibeVoiceActionRetire) {
                    VibeVoiceDie(slot, VibeVoiceEndRetired, renderSequence);
                    continue;
                }
                if (slot->rampAction == VibeVoiceActionPause) {
                    atomic_store_explicit(&slot->paused, 1, memory_order_relaxed);
                    slot->consuming = 0;
                }
            }
        }
        if (atomic_load_explicit(&slot->paused, memory_order_relaxed)) {
            continue;
        }
        uint64_t written = atomic_load_explicit(&slot->written, memory_order_acquire);
        // Sequentially consistent, paired with the reopen's withdrawal of the
        // end: either this render sees the end withdrawn, or the reopen sees
        // this render in flight and waits for its verdict.
        uint64_t endOfStream = atomic_load_explicit(&slot->endOfStream, memory_order_seq_cst);
        uint64_t boundary = atomic_load_explicit(&slot->boundary, memory_order_acquire);
        uint64_t consumed = atomic_load_explicit(&slot->consumed, memory_order_relaxed);
        uint64_t available = written - consumed;
        uint32_t frames = available < frameCount ? (uint32_t)available : frameCount;
        BOOL ramping = slot->rampElapsed < slot->rampFrames;
        BOOL landsHere = NO;
        if (ramping && slot->rampAction != VibeVoiceActionNone) {
            // A pause or retire lands on an exact frame: nothing past it is mixed.
            uint32_t untilLanding = slot->rampFrames - slot->rampElapsed;
            if (untilLanding <= frames) {
                frames = untilLanding;
                landsHere = YES;
            }
        }
        if (frames > 0) {
            uint32_t readIndex = (uint32_t)(consumed & mix->mask);
            for (uint32_t c = 0; c < channels; c++) {
                const float *ring = mix->rings[s][c];
                float *out = (float *)output->mBuffers[c].mData;
                if (ramping) {
                    for (uint32_t i = 0; i < frames; i++) {
                        float g = VibeFadeGainAtFrame((VibeFadeCurve)slot->rampCurve, slot->rampFrom, slot->rampTo,
                                                      slot->rampElapsed + i, slot->rampFrames);
                        out[i] += g * ring[(readIndex + i) & mix->mask];
                    }
                }
                else if (slot->gain == 1.0f) {
                    for (uint32_t i = 0; i < frames; i++) {
                        out[i] += ring[(readIndex + i) & mix->mask];
                    }
                }
                else {
                    float g = slot->gain;
                    for (uint32_t i = 0; i < frames; i++) {
                        out[i] += g * ring[(readIndex + i) & mix->mask];
                    }
                }
            }
            if (!slot->consuming) {
                slot->consuming = 1;
                VibeStampWrite(slot, &slot->startStamp, timestamp, 0, mix->hostTicksPerFrame);
            }
            if (boundary != kUnset && consumed <= boundary && consumed + frames > boundary) {
                VibeStampWrite(slot, &slot->boundaryStamp, timestamp, boundary - consumed, mix->hostTicksPerFrame);
            }
            VibeStampWrite(slot, &slot->lastStamp, timestamp, frames, mix->hostTicksPerFrame);
            consumed += frames;
            atomic_store_explicit(&slot->consumed, consumed, memory_order_release);
            mixed = YES;
        }
        if (frames < frameCount && !landsHere && endOfStream == kUnset) {
            // Hold the position, zero-fill (already zero), count it.
            atomic_fetch_add_explicit(&slot->underrun, frameCount - frames, memory_order_relaxed);
        }
        if (ramping) {
            // Block frames, not consumed frames: a starved retiring voice
            // still dies on schedule, and a landing here is exact.
            uint32_t advance = landsHere ? frames : frameCount;
            slot->rampElapsed = slot->rampElapsed + advance >= slot->rampFrames
                    ? slot->rampFrames : slot->rampElapsed + advance;
            if (slot->rampElapsed >= slot->rampFrames) {
                slot->gain = slot->rampTo;
                if (slot->rampAction == VibeVoiceActionRetire) {
                    VibeVoiceDie(slot, VibeVoiceEndRetired, renderSequence);
                    continue;
                }
                if (slot->rampAction == VibeVoiceActionPause) {
                    atomic_store_explicit(&slot->paused, 1, memory_order_relaxed);
                    slot->consuming = 0;
                }
            }
            else {
                slot->gain = VibeFadeGainAtFrame((VibeFadeCurve)slot->rampCurve, slot->rampFrom, slot->rampTo,
                                                 slot->rampElapsed, slot->rampFrames);
            }
        }
        if (endOfStream != kUnset && consumed >= endOfStream) {
            VibeVoiceDie(slot, VibeVoiceEndOfStream, renderSequence);
        }
    }
    *isSilence = !mixed;
    atomic_store_explicit(&mix->renderSequence, renderSequence + 1, memory_order_release);
    atomic_store_explicit(&mix->inRender, 0, memory_order_release);
    return noErr;
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

#pragma mark - The records the queue and decoder share

// What the audio thread must never see: the file, its converter and buffers,
// the queued successor, and the drain's once-only event flags. The successor
// pointer is written by the queue and read by the decoder only across the
// successorState CAS, which orders them.
@interface VibeVoiceRecord : NSObject {
@public
    VibeVoiceID identifier;
    AVAudioFile *file;
    AVAudioFormat *decodeFormat;
    AVAudioConverter *converter;
    AVAudioPCMBuffer *readBuffer;    // the file's processing format
    AVAudioPCMBuffer *mixBuffer;     // the bus's channels at the file's rate, what a converter takes after the mix
    AVAudioPCMBuffer *convertBuffer; // the converter's output
    AVAudioPCMBuffer *stageBuffer;   // the bus format, what the ring takes; one per slot for the bus's life
    NSData *mixMap;                  // Float32[source channels][bus channels], when the widths differ
    AVAudioFramePosition startFrame;
    BOOL positioned;
    VibeStreamState stream;
    AVAudioFile *successorFile;
    AVAudioFormat *successorDecodeFormat;
    uint64_t retireOrder;            // when a retire ramp was submitted; 0 = not retiring
    _Atomic int32_t fillScheduled;
    uint32_t fillTarget;
    BOOL liveReported;
    uint64_t reportedBoundary;      // the last boundary the drain reported; kUnset = none
    BOOL endedReported;
    // A pending voice's start, replayed when a slot frees.
    float gain;
    VibeVoiceRamp ramp;
    BOOL paused;
    BOOL readsStopped;
}
@end

@implementation VibeVoiceRecord
@end

static const void *kVibeVoiceMixOwnerKey = &kVibeVoiceMixOwnerKey;

@implementation AudioVoiceBus {
    dispatch_queue_t _queue;
    dispatch_queue_t _decodeQueue;
    VibeVoiceMix *_mix;
    VibeVoiceRecord *_records[kVoiceSlots];
    NSMutableArray<VibeVoiceRecord *> *_pending;
    NSMutableArray<NSNumber *> *_endedPending; // killed before a slot; the next drain reports them ended
    // id → slot, for the one cross-thread lookup (snapshotOfVoice:). Never
    // taken by the audio thread; never held across a queue hop.
    os_unfair_lock _tableLock;
    VibeVoiceID _slotIdentifiers[kVoiceSlots];
    uint64_t _nextIdentifier;
    uint32_t _rampSequence;
    uint64_t _nextRetireOrder;
    AVAudioSourceNodeRenderBlock _renderBlock;
}

- (instancetype)initWithFormat:(AVAudioFormat *)busFormat queue:(dispatch_queue_t)queue inlineDecoding:(BOOL)inlineDecoding {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (busFormat.commonFormat != AVAudioPCMFormatFloat32 || busFormat.isInterleaved
            || busFormat.channelCount == 0 || busFormat.channelCount > kMaxBusChannels
            || busFormat.sampleRate <= 0) {
        return nil;
    }
    uint32_t capacity = 1;
    while (capacity < busFormat.sampleRate) {
        capacity <<= 1; // ≥ 1 s at the bus rate
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double nanosPerTick = (double)timebase.numer / (double)timebase.denom;
    double ticksPerFrame = 1e9 / busFormat.sampleRate / nanosPerTick;
    VibeVoiceMixOwner *owner = [[VibeVoiceMixOwner alloc] initWithChannels:busFormat.channelCount
                                                                   capacity:capacity
                                                          hostTicksPerFrame:ticksPerFrame];
    if (!owner) {
        return nil;
    }
    _format = busFormat;
    _queue = queue;
    _inlineDecoding = inlineDecoding;
    if (!inlineDecoding) {
        // Audio feeding: the one queue whose starvation is audible.
        _decodeQueue = dispatch_queue_create("com.vibe.voicebus.decode",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    }
    _mix = owner.mix;
    _pending = [NSMutableArray array];
    _endedPending = [NSMutableArray array];
    _tableLock = OS_UNFAIR_LOCK_INIT;
    _nextIdentifier = 1;
    _nextRetireOrder = 1;
    for (uint32_t s = 0; s < kVoiceSlots; s++) {
        _records[s] = [[VibeVoiceRecord alloc] init];
        _records[s]->stageBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:busFormat frameCapacity:kDecodeChunkFrames];
        if (!_records[s]->stageBuffer) {
            return nil;
        }
    }
    // The block sees a C pointer and nothing else; the owner rides the node.
    // The attribute on the literal puts its body under the same check as the
    // render function.
    VibeVoiceMix *mix = _mix;
    AVAudioSourceNodeRenderBlock render = ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                                    AVAudioFrameCount frameCount, AudioBufferList *outputData)
            CA_REALTIME_API {
        return VibeVoiceBusRender(mix, isSilence, timestamp, frameCount, outputData);
    };
    _renderBlock = render;
    _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:busFormat renderBlock:render];
    objc_setAssociatedObject(_sourceNode, kVibeVoiceMixOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (AVAudioSourceNodeRenderBlock)renderBlock {
    return _renderBlock;
}

- (dispatch_queue_t)decodeQueue {
    return _decodeQueue;
}

// 20 bits, never 0: a zero word is "no ramp", which a paused start relies on.
- (uint32_t)nextRampSequence {
    _rampSequence = (_rampSequence + 1) & 0xFFFFF;
    if (_rampSequence == 0) {
        _rampSequence = 1;
    }
    return _rampSequence;
}

#pragma mark - Identity

- (NSUInteger)slotForIdentifier:(VibeVoiceID)identifier {
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        if (_slotIdentifiers[s] == identifier) {
            return s;
        }
    }
    return NSNotFound;
}

- (VibeVoiceRecord *)pendingRecordForIdentifier:(VibeVoiceID)identifier {
    for (VibeVoiceRecord *record in _pending) {
        if (record->identifier == identifier) {
            return record;
        }
    }
    return nil;
}

// _pending is queue-owned; the lock lets snapshotOfVoice: read it from
// another thread, so every mutation goes through these two.
- (void)addPendingRecord:(VibeVoiceRecord *)record atFront:(BOOL)front {
    os_unfair_lock_lock(&_tableLock);
    if (front) {
        [_pending insertObject:record atIndex:0];
    }
    else {
        [_pending addObject:record];
    }
    os_unfair_lock_unlock(&_tableLock);
}

- (void)removePendingRecord:(VibeVoiceRecord *)record {
    os_unfair_lock_lock(&_tableLock);
    [_pending removeObject:record];
    os_unfair_lock_unlock(&_tableLock);
}

// The queue's own lookup: the table is queue-owned, the lock only shields
// snapshotOfVoice:'s read from another thread.
- (NSUInteger)ownedSlotForIdentifier:(VibeVoiceID)identifier {
    os_unfair_lock_lock(&_tableLock);
    NSUInteger slot = identifier ? [self slotForIdentifier:identifier] : NSNotFound;
    os_unfair_lock_unlock(&_tableLock);
    return slot;
}

- (void)setIdentifier:(VibeVoiceID)identifier forSlot:(NSUInteger)slot {
    os_unfair_lock_lock(&_tableLock);
    _slotIdentifiers[slot] = identifier;
    os_unfair_lock_unlock(&_tableLock);
}

#pragma mark - Starting

// A mono or stereo format leaves its layout unsaid; the mix map needs one.
static AVAudioChannelLayout *VibeAssumedLayout(AVAudioFormat *format) {
    if (format.channelLayout) {
        return format.channelLayout;
    }
    if (format.channelCount == 1) {
        return [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Mono];
    }
    return format.channelCount == 2 ? [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_Stereo] : nil;
}

// The mix between two channel sets, input-major (`map[in * outputs + out]`):
// the standard matrix between the two layouts, as the mixer applies it — a
// fold across widths, a permutation across orders; mono into every channel;
// otherwise the first channels.
static NSData *VibeMixMap(AVAudioFormat *source, AVAudioFormat *target) {
    uint32_t inputs = source.channelCount, outputs = target.channelCount;
    NSMutableData *map = [NSMutableData dataWithLength:inputs * outputs * sizeof(Float32)];
    float *m = map.mutableBytes;
    AVAudioChannelLayout *from = VibeAssumedLayout(source), *to = VibeAssumedLayout(target);
    UInt32 size = (UInt32)map.length;
    if (inputs != 1 && from && to) {
        const AudioChannelLayout *layouts[2] = { from.layout, to.layout };
        if (AudioFormatGetProperty(kAudioFormatProperty_MatrixMixMap, sizeof(layouts), layouts, &size, m) == noErr) {
            return map;
        }
        memset(m, 0, map.length);
    }
    for (uint32_t o = 0; o < outputs; o++) {
        if (inputs == 1) {
            m[o] = 1;
        }
        else if (o < inputs) {
            m[o * outputs + o] = 1;
        }
    }
    return map;
}

// into[out] = Σ map[in][out] · source[in], over `frames`.
static void VibeApplyMixMap(const float *map, AVAudioPCMBuffer *source, AVAudioPCMBuffer *into, uint32_t frames) {
    uint32_t inputs = source.format.channelCount, outputs = into.format.channelCount;
    for (uint32_t o = 0; o < outputs; o++) {
        float *out = into.floatChannelData[o];
        vDSP_vclr(out, 1, frames);
        for (uint32_t i = 0; i < inputs; i++) {
            float gain = map[i * outputs + o];
            if (gain != 0) {
                vDSP_vsma(source.floatChannelData[i], 1, &gain, out, 1, out, 1, frames);
            }
        }
    }
    into.frameLength = frames;
}

// The file's processing format is float32; the bus is float32 at its own rate
// and width. Nothing to do when they agree. A channel difference — the width,
// or the order a wider layout names — is mixed first, on the file's own rate,
// as the mixer would, so a converter carries the bus's channels only and none
// is needed at the bus rate. A rate
// difference is converted at maximum quality; a lossy source under
// bit-perfect output is converted to the 16-bit form it wants, which the
// decoder expands back to float exactly so the bus stays float on the 16-bit
// grid.
- (BOOL)prepareRecord:(VibeVoiceRecord *)record file:(AVAudioFile *)file decodeFormat:(AVAudioFormat *)decodeFormat {
    AVAudioFormat *source = file.processingFormat;
    record->file = file;
    record->decodeFormat = decodeFormat;
    record->converter = nil;
    record->readBuffer = nil;
    record->mixBuffer = nil;
    record->convertBuffer = nil;
    record->mixMap = nil;
    record->stream = VibeStreamReading;
    BOOL integer = decodeFormat.commonFormat == AVAudioPCMFormatInt16;
    if (!integer && VibeFormatsMatch(source, _format)) {
        return YES;
    }
    AVAudioFormat *fed = source; // what the converter takes
    if (!integer && !VibeChannelsMatch(source, _format)) {
        record->mixMap = VibeMixMap(source, _format);
        record->readBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:source frameCapacity:kDecodeChunkFrames];
        if (source.sampleRate == _format.sampleRate) {
            return record->readBuffer != nil; // the mix lands in the stage
        }
        fed = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:source.sampleRate
                                                 channels:_format.channelCount interleaved:NO];
        record->mixBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fed frameCapacity:kDecodeChunkFrames];
    }
    AVAudioFormat *target = integer ? decodeFormat : _format;
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:fed toFormat:target];
    if (!converter) {
        return NO;
    }
    converter.sampleRateConverterQuality = AVAudioQualityMax;
    record->converter = converter;
    record->readBuffer = record->readBuffer ?: [[AVAudioPCMBuffer alloc] initWithPCMFormat:source frameCapacity:kDecodeChunkFrames];
    record->convertBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:kDecodeChunkFrames];
    return record->readBuffer && record->convertBuffer && (!record->mixMap || record->mixBuffer);
}

- (NSUInteger)freeSlot {
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        if (atomic_load_explicit(&_mix->slots[s].state, memory_order_acquire) == VibeVoiceStateNone) {
            return s;
        }
    }
    return NSNotFound;
}

- (NSUInteger)freeSlotCount {
    return [self slotCountInState:VibeVoiceStateNone];
}

// A full pool is a skip storm with long crossfades. The oldest retiring voice
// is the quietest, so it is the one to cut; its slot frees at the next render.
- (void)cutOldestRetiringVoice {
    NSUInteger oldest = NSNotFound;
    uint64_t order = UINT64_MAX;
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        VibeVoiceRecord *record = _records[s];
        if (atomic_load_explicit(&_mix->slots[s].state, memory_order_acquire) == VibeVoiceStateLive
                && record->retireOrder && record->retireOrder < order) {
            order = record->retireOrder;
            oldest = s;
        }
    }
    if (oldest != NSNotFound) {
        [self killVoice:_slotIdentifiers[oldest]];
    }
}

- (VibeVoiceID)startVoiceWithFile:(AVAudioFile *)file atFrame:(AVAudioFramePosition)frame
                     decodeFormat:(AVAudioFormat *)decodeFormat gain:(float)gain
                             ramp:(VibeVoiceRamp)ramp paused:(BOOL)paused {
    VibeVoiceID identifier = _nextIdentifier++;
    if ([self freeSlotCount] <= kFreeSlotReserve) {
        [self cutOldestRetiringVoice];
    }
    VibeVoiceRecord *record = [[VibeVoiceRecord alloc] init];
    record->identifier = identifier;
    record->file = file;
    record->decodeFormat = decodeFormat;
    record->startFrame = frame;
    record->gain = gain;
    record->ramp = ramp;
    record->paused = paused;
    NSUInteger slot = _pending.count ? NSNotFound : [self freeSlot];
    if (slot == NSNotFound) {
        [self addPendingRecord:record atFront:NO];
        return identifier;
    }
    [self bindRecord:record toSlot:slot];
    return identifier;
}

// Allocates the slot for a start: counters carry on from where the slot left
// off, the audio thread's fields are whatever the recycle left, and the
// generation's release-store publishes it all.
- (void)bindRecord:(VibeVoiceRecord *)record toSlot:(NSUInteger)slot {
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t expected = VibeVoiceStateNone;
    if (!atomic_compare_exchange_strong_explicit(&s->state, &expected, VibeVoiceStateArmed,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        [self addPendingRecord:record atFront:YES];
        return;
    }
    VibeVoiceRecord *bound = _records[slot];
    bound->identifier = record->identifier;
    bound->startFrame = record->startFrame;
    bound->positioned = NO;
    // A successor queued while the start was pending rides into the slot.
    bound->successorFile = record->successorFile;
    bound->successorDecodeFormat = record->successorDecodeFormat;
    bound->retireOrder = record->ramp.action == VibeVoiceActionRetire ? _nextRetireOrder++ : 0;
    atomic_store_explicit(&bound->fillScheduled, 0, memory_order_relaxed);
    bound->fillTarget = kInitialFillFrames;
    bound->liveReported = bound->endedReported = NO;
    bound->reportedBoundary = kUnset;
    BOOL prepared = [self prepareRecord:bound file:record->file decodeFormat:record->decodeFormat];
    s->armedWritten = atomic_load_explicit(&s->written, memory_order_relaxed);
    s->armedConsumed = atomic_load_explicit(&s->consumed, memory_order_relaxed);
    atomic_store_explicit(&s->readsAllowed, prepared && !record->readsStopped, memory_order_relaxed);
    atomic_store_explicit(&s->successorState, record->successorFile ? VibeSuccessorQueued : VibeSuccessorNone,
                          memory_order_relaxed);
    atomic_store_explicit(&s->paused, record->paused, memory_order_relaxed);
    s->gain = record->gain;
    s->rampSequence = 0;
    // A paused start carries no ramp: adopting one un-pauses, and the first
    // ramp set later is the resume.
    atomic_store_explicit(&s->ramp, record->paused ? 0
            : VibeRampWord(record->ramp.target, record->ramp.frames, record->ramp.curve,
                           record->ramp.action, [self nextRampSequence]), memory_order_relaxed);
    [self setIdentifier:record->identifier forSlot:slot];
    atomic_store_explicit(&s->generation, record->identifier, memory_order_release);
    if (!prepared) {
        // A converter that could not be made ends the voice at once; the
        // drain reports it ended, and the transport reports the file.
        [self killVoice:record->identifier];
        return;
    }
    if (!_inlineDecoding) {
        [self scheduleFillForSlot:slot];
    }
}

- (void)bindPendingVoices {
    while (_pending.count) {
        NSUInteger slot = [self freeSlot];
        if (slot == NSNotFound) {
            return;
        }
        VibeVoiceRecord *record = _pending.firstObject;
        [self removePendingRecord:record];
        [self bindRecord:record toSlot:slot];
    }
}

#pragma mark - Requests

- (void)setRamp:(VibeVoiceRamp)ramp forVoice:(VibeVoiceID)voice {
    VibeVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        // Adopting a ramp un-pauses, and a pending voice adopts at its bind,
        // so the flag follows the ramp now: a resume that arrives before the
        // slot does must not bind as a paused start with its ramp dropped.
        pending->ramp = ramp;
        pending->paused = NO;
        return;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return;
    }
    if (ramp.action == VibeVoiceActionRetire && !_records[slot]->retireOrder) {
        _records[slot]->retireOrder = _nextRetireOrder++;
    }
    atomic_store_explicit(&_mix->slots[slot].ramp,
                          VibeRampWord(ramp.target, ramp.frames, ramp.curve, ramp.action, [self nextRampSequence]),
                          memory_order_release);
}

- (void)stopReadingForVoice:(VibeVoiceID)voice {
    VibeVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->readsStopped = YES;
        return;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot != NSNotFound) {
        atomic_store_explicit(&_mix->slots[slot].readsAllowed, 0, memory_order_release);
    }
}

// The decoder never hops to the player queue synchronously, so the wait
// cannot deadlock.
- (void)stopReading {
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        [self stopReadingForVoice:_slotIdentifiers[s]];
    }
    if (_decodeQueue) {
        dispatch_sync(_decodeQueue, ^{});
    }
}

- (BOOL)queueSuccessor:(AVAudioFile *)file decodeFormat:(AVAudioFormat *)decodeFormat forVoice:(VibeVoiceID)voice {
    VibeVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->successorFile = file;
        pending->successorDecodeFormat = decodeFormat;
        return YES;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return NO;
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
    if ((state != VibeVoiceStateArmed && state != VibeVoiceStateLive)
            || !atomic_load_explicit(&s->readsAllowed, memory_order_acquire)
            || atomic_load_explicit(&s->successorState, memory_order_acquire) != VibeSuccessorNone) {
        return NO; // dead, retired at declick length, or already continuing
    }
    VibeVoiceRecord *record = _records[slot];
    record->successorFile = file;
    record->successorDecodeFormat = decodeFormat;
    int32_t expected = VibeSuccessorNone;
    if (!atomic_compare_exchange_strong_explicit(&s->successorState, &expected, VibeSuccessorQueued,
                                                 memory_order_release, memory_order_relaxed)) {
        return NO;
    }
    // The decoder may have no turn scheduled — its stream drained or ended —
    // so one is asked for; a turn with nothing to do returns.
    if (!_inlineDecoding) {
        [self scheduleFillForSlot:slot];
    }
    return YES;
}

- (BOOL)unqueueSuccessorForVoice:(VibeVoiceID)voice {
    VibeVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->successorFile = nil;
        pending->successorDecodeFormat = nil;
        return YES;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return YES;
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t expected = VibeSuccessorQueued;
    if (atomic_compare_exchange_strong_explicit(&s->successorState, &expected, VibeSuccessorNone,
                                                memory_order_acq_rel, memory_order_acquire)) {
        _records[slot]->successorFile = nil;
        _records[slot]->successorDecodeFormat = nil;
        return YES;
    }
    // The decoder won the race, or had already switched: successor frames
    // are in the ring, or on their way. Its claim commits the voice from the
    // moment it is made — before the boundary is published — and the None
    // after a switch leaves the boundary behind as the sign.
    return expected == VibeSuccessorNone && atomic_load_explicit(&s->boundary, memory_order_acquire) == kUnset;
}

- (void)killVoice:(VibeVoiceID)voice {
    VibeVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        [self removePendingRecord:pending];
        [_endedPending addObject:@(voice)]; // every started voice ends exactly once, through the drain
        return;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return;
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t armed = VibeVoiceStateArmed;
    if (atomic_compare_exchange_strong_explicit(&s->state, &armed, VibeVoiceStateDead,
                                                memory_order_acq_rel, memory_order_relaxed)) {
        // The audio thread never saw it: no render has to pass before the
        // recycle, which the drain performs.
        atomic_store_explicit(&s->endedReason, VibeVoiceEndRetired, memory_order_relaxed);
        atomic_store_explicit(&s->diedAtRender, 0, memory_order_release);
        return;
    }
    [self setRamp:VibeVoiceRampMake(0, 0, VibeFadeCurveLinear, VibeVoiceActionRetire) forVoice:voice];
}

#pragma mark - Reading

- (VibeVoiceSnapshot)snapshotOfVoice:(VibeVoiceID)voice {
    VibeVoiceSnapshot snapshot = {0};
    snapshot.boundary = kUnset;
    snapshot.endOfStream = kUnset;
    if (!voice) {
        return snapshot;
    }
    os_unfair_lock_lock(&_tableLock);
    NSUInteger slot = [self slotForIdentifier:voice];
    BOOL pending = slot == NSNotFound && [self pendingRecordForIdentifier:voice] != nil;
    os_unfair_lock_unlock(&_tableLock);
    if (slot == NSNotFound) {
        // A pending voice is armed, which is what it is; anything else
        // unknown has been recycled.
        snapshot.state = pending ? VibeVoiceStateArmed : VibeVoiceStateNone;
        return snapshot;
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t generation = atomic_load_explicit(&s->generation, memory_order_acquire);
        if (generation != voice) {
            snapshot.state = VibeVoiceStateNone;
            return snapshot;
        }
        int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
        uint64_t armedWritten = s->armedWritten;
        uint64_t armedConsumed = s->armedConsumed;
        uint64_t consumed = atomic_load_explicit(&s->consumed, memory_order_acquire);
        uint64_t written = atomic_load_explicit(&s->written, memory_order_acquire);
        uint64_t boundary = atomic_load_explicit(&s->boundary, memory_order_acquire);
        uint64_t endOfStream = atomic_load_explicit(&s->endOfStream, memory_order_acquire);
        snapshot.paused = atomic_load_explicit(&s->paused, memory_order_relaxed) != 0;
        snapshot.ended = (VibeVoiceEnd)atomic_load_explicit(&s->endedReason, memory_order_relaxed);
        snapshot.underrunFrames = atomic_load_explicit(&s->underrun, memory_order_relaxed);
        snapshot.gain = s->gain; // a plain read of the thread's private float: diagnostic, never a decision
        uint32_t version = atomic_load_explicit(&s->stampVersion, memory_order_acquire);
        snapshot.startOfConsumption = s->startStamp;
        snapshot.boundaryCrossing = s->boundaryStamp;
        snapshot.lastRender = s->lastStamp;
        BOOL stampsTorn = (version & 1) || atomic_load_explicit(&s->stampVersion, memory_order_acquire) != version;
        if (atomic_load_explicit(&s->generation, memory_order_acquire) != generation) {
            continue;
        }
        snapshot.state = (VibeVoiceState)state;
        snapshot.consumed = consumed - armedConsumed;
        snapshot.written = written - armedWritten;
        snapshot.boundary = boundary == kUnset ? kUnset : boundary - armedWritten;
        snapshot.endOfStream = endOfStream == kUnset ? kUnset : endOfStream - armedWritten;
        if (!stampsTorn) {
            return snapshot;
        }
    }
    return snapshot;
}

- (NSUInteger)occupiedSlotCount {
    return kVoiceSlots - [self freeSlotCount] + _pending.count;
}

- (NSUInteger)liveVoiceCount {
    return [self slotCountInState:VibeVoiceStateLive];
}

- (NSUInteger)slotCountInState:(VibeVoiceState)state {
    NSUInteger count = 0;
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        count += atomic_load_explicit(&_mix->slots[s].state, memory_order_acquire) == state;
    }
    return count;
}

- (NSUInteger)pendingVoiceCount {
    return _pending.count;
}

#pragma mark - The drain

- (void)drainWithEngineRunning:(BOOL)engineRunning handler:(void (^)(VibeVoiceID, VibeVoiceEvent))handler {
    uint64_t renderSequence = atomic_load_explicit(&_mix->renderSequence, memory_order_acquire);
    BOOL noRenderPossible = !engineRunning && atomic_load_explicit(&_mix->inRender, memory_order_acquire) == 0;
    for (NSUInteger slot = 0; slot < kVoiceSlots; slot++) {
        VibeVoiceSlot *s = &_mix->slots[slot];
        int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
        if (state == VibeVoiceStateNone) {
            continue;
        }
        VibeVoiceRecord *record = _records[slot];
        VibeVoiceID identifier = record->identifier;
        if (!identifier) {
            continue; // dead, its recycle already queued behind decode work
        }
        if (state == VibeVoiceStateArmed) {
            if (!_inlineDecoding) {
                [self scheduleFillForSlot:slot];
            }
            continue;
        }
        if (!record->liveReported) {
            record->liveReported = YES;
            handler(identifier, VibeVoiceEventLive);
        }
        // By value, not once: a voice that chains several successors crosses a
        // boundary per successor, and the transport queues the next only after
        // the previous one was reported, so none is ever overwritten unseen.
        uint64_t boundary = atomic_load_explicit(&s->boundary, memory_order_acquire);
        if (boundary != kUnset && boundary != record->reportedBoundary
                && atomic_load_explicit(&s->consumed, memory_order_acquire) >= boundary) {
            record->reportedBoundary = boundary;
            handler(identifier, VibeVoiceEventBoundary);
        }
        if (state == VibeVoiceStateLive) {
            if (!_inlineDecoding) {
                uint64_t buffered = atomic_load_explicit(&s->written, memory_order_relaxed)
                        - atomic_load_explicit(&s->consumed, memory_order_relaxed);
                if (buffered < _mix->capacity / kLowWaterDivisor) {
                    record->fillTarget = _mix->capacity;
                    [self scheduleFillForSlot:slot];
                }
            }
            continue;
        }
        if (!record->endedReported) {
            record->endedReported = YES;
            handler(identifier, VibeVoiceEventEnded);
        }
        uint64_t died = atomic_load_explicit(&s->diedAtRender, memory_order_acquire);
        if (renderSequence > died || noRenderPossible) {
            [self setIdentifier:0 forSlot:slot];
            VibeVoiceID generation = atomic_load_explicit(&s->generation, memory_order_acquire);
            if (_inlineDecoding) {
                [self recycleSlot:slot generation:generation];
            }
            else {
                dispatch_async(_decodeQueue, ^{ [self recycleSlot:slot generation:generation]; });
            }
        }
    }
    if (_endedPending.count) {
        NSArray<NSNumber *> *ended = [_endedPending copy];
        [_endedPending removeAllObjects];
        for (NSNumber *identifier in ended) {
            handler(identifier.unsignedLongLongValue, VibeVoiceEventEnded);
        }
    }
    // After the recycles, so a slot this drain freed takes a pending start now.
    [self bindPendingVoices];
}

#pragma mark - The decoder

// Decode queue, or the caller's thread under inline decoding — never both:
// the ring has one producer. TRAP: a recycle queued behind decode work can
// run after the slot was freed and taken by a new voice, so it cleans only
// the death it was queued for; without the check it erased the new voice and
// playback went silent with no end event. A decode turn queued for the dead
// voice is the mirror: every turn checks the slot's generation first, and the
// recycle clears it, so no turn of the old voice can enter the slot while the
// next voice binds it; without that one wrote an end into a voice that had
// not read a frame, and it died at its first render.
- (void)recycleSlot:(NSUInteger)slot generation:(VibeVoiceID)generation {
    VibeVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (atomic_load_explicit(&s->state, memory_order_acquire) != VibeVoiceStateDead
            || atomic_load_explicit(&s->generation, memory_order_acquire) != generation) {
        return;
    }
    record->file = nil;
    record->converter = nil;
    record->readBuffer = nil;
    record->mixBuffer = nil;
    record->convertBuffer = nil;
    record->mixMap = nil;
    record->decodeFormat = nil;
    record->successorFile = nil;
    record->successorDecodeFormat = nil;
    record->retireOrder = 0;
    atomic_store_explicit(&record->fillScheduled, 0, memory_order_relaxed);
    atomic_store_explicit(&s->endOfStream, kUnset, memory_order_relaxed);
    atomic_store_explicit(&s->boundary, kUnset, memory_order_relaxed);
    atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_relaxed);
    atomic_store_explicit(&s->endedReason, VibeVoiceEndNone, memory_order_relaxed);
    atomic_store_explicit(&s->underrun, 0, memory_order_relaxed);
    atomic_store_explicit(&s->paused, 0, memory_order_relaxed);
    // The audio thread has provably left the slot: align the consumer index
    // to the producer's, so the next voice starts from an empty ring, and
    // reset the thread's private block.
    atomic_store_explicit(&s->consumed, atomic_load_explicit(&s->written, memory_order_relaxed), memory_order_relaxed);
    s->gain = 0;
    s->rampFrom = s->rampTo = 0;
    s->rampFrames = s->rampElapsed = 0;
    s->rampCurve = s->rampAction = 0;
    s->rampSequence = 0;
    s->consuming = 0;
    atomic_store_explicit(&s->generation, 0, memory_order_release);
    atomic_store_explicit(&s->state, VibeVoiceStateNone, memory_order_release);
}

- (void)scheduleFillForSlot:(NSUInteger)slot {
    VibeVoiceRecord *record = _records[slot];
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&record->fillScheduled, &expected, 1,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return;
    }
    VibeVoiceID identifier = record->identifier;
    dispatch_async(_decodeQueue, ^{ [self decodeTurnForSlot:slot identifier:identifier]; });
}

// One chunk per turn, re-dispatched while the ring wants more, so a start's
// first chunk never queues behind another voice's full fill. A turn of a
// voice since recycled touches nothing: the slot, its record and its fill
// flag belong to whoever holds the slot now.
- (void)decodeTurnForSlot:(NSUInteger)slot identifier:(VibeVoiceID)identifier {
    VibeVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (atomic_load_explicit(&s->generation, memory_order_acquire) != identifier) {
        return;
    }
    BOOL more = [self decodeChunkForSlot:slot];
    if (more) {
        uint64_t buffered = atomic_load_explicit(&s->written, memory_order_relaxed)
                - atomic_load_explicit(&s->consumed, memory_order_acquire);
        more = buffered < record->fillTarget;
    }
    if (more) {
        dispatch_async(_decodeQueue, ^{ [self decodeTurnForSlot:slot identifier:identifier]; });
    }
    else {
        atomic_store_explicit(&record->fillScheduled, 0, memory_order_release);
    }
}

- (void)fillInline {
    for (NSUInteger slot = 0; slot < kVoiceSlots; slot++) {
        int32_t state = atomic_load_explicit(&_mix->slots[slot].state, memory_order_acquire);
        if (state != VibeVoiceStateArmed && state != VibeVoiceStateLive) {
            continue;
        }
        while ([self decodeChunkForSlot:slot]) {
        }
    }
}

// The decoder's claim on the queued successor, against the queue's unqueue:
// won, the voice's stream is the successor's from here, whether or not a
// frame of it has reached the ring. nil when none is queued.
- (AVAudioFile *)claimSuccessorForSlot:(NSUInteger)slot {
    int32_t queued = VibeSuccessorQueued;
    if (!atomic_compare_exchange_strong_explicit(&_mix->slots[slot].successorState, &queued, VibeSuccessorSwitching,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return nil;
    }
    return _records[slot]->successorFile;
}

// A successor read the same way as the file before it — the same format,
// layout included, and the same decode format — continues through the
// voice's converter, which is told nothing of the boundary, so its filter
// carries across as the mixer's once did; the next read is the successor's
// from its start. NO when it needs a converter of its own.
- (BOOL)continueRecord:(VibeVoiceRecord *)record intoSuccessor:(AVAudioFile *)successor {
    if (!VibeFormatsMatch(record->file.processingFormat, successor.processingFormat)
            || !VibeFormatsMatch(record->decodeFormat, record->successorDecodeFormat)) {
        return NO;
    }
    record->file = successor;
    record->startFrame = 0;
    record->positioned = NO;
    record->successorFile = nil;
    record->successorDecodeFormat = nil;
    return YES;
}

// Takes the claimed successor out of the record, with a converter of its
// own, to be read from its start; NO with none there.
- (BOOL)prepareSuccessorForRecord:(VibeVoiceRecord *)record {
    AVAudioFile *successor = record->successorFile;
    AVAudioFormat *decodeFormat = record->successorDecodeFormat;
    record->successorFile = nil;
    record->successorDecodeFormat = nil;
    record->startFrame = 0;
    record->positioned = NO;
    return successor && [self prepareRecord:record file:successor decodeFormat:decodeFormat];
}

// Reads one chunk of the voice's file into the stage buffer, in the bus
// format. The file's end is a read that comes up short or empty — never
// framePosition == length, which a truncated file never reaches — and drains
// the stream: a converter is told nothing of it until the stream is flushing,
// when it is told the end and gives up its tail. *final says the end is out.
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final {
    VibeVoiceRecord *record = _records[slot];
    BOOL flushing = record->stream == VibeStreamFlushing;
    *final = NO;
    NSError *error = nil;
    if (!record->converter) {
        if (flushing) {
            *final = YES; // nothing held back: the end is now
            return 0;
        }
        AVAudioPCMBuffer *into = record->mixMap ? record->readBuffer : record->stageBuffer;
        into.frameLength = 0;
        BOOL read = [record->file readIntoBuffer:into frameCount:kDecodeChunkFrames error:&error];
        if (!read) {
            LogWarn(@"AudioVoiceBus: read failed for %@: %@", record->file.url.lastPathComponent, error.localizedDescription);
        }
        uint32_t frames = read ? into.frameLength : 0;
        if (record->mixMap) {
            VibeApplyMixMap(record->mixMap.bytes, record->readBuffer, record->stageBuffer, frames);
        }
        if (!read || frames < kDecodeChunkFrames || record->file.framePosition >= record->file.length) {
            record->stream = VibeStreamDrained;
        }
        return frames;
    }
    AVAudioConverterOutputStatus status = [record->converter convertToBuffer:record->convertBuffer error:&error
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *inputStatus) {
        AVAudioPCMBuffer *readBuffer = record->readBuffer;
        readBuffer.frameLength = 0;
        NSError *readError = nil;
        AVAudioFrameCount wanted = packets < kDecodeChunkFrames ? packets : kDecodeChunkFrames;
        if (!flushing && [record->file readIntoBuffer:readBuffer frameCount:wanted error:&readError] && readBuffer.frameLength > 0) {
            *inputStatus = AVAudioConverterInputStatus_HaveData;
            if (!record->mixMap) {
                return readBuffer;
            }
            VibeApplyMixMap(record->mixMap.bytes, readBuffer, record->mixBuffer, readBuffer.frameLength);
            return record->mixBuffer;
        }
        if (flushing) {
            *inputStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        // The file ran out with the stream open: no data now, and nothing of
        // an end, so the filter stays primed for a successor.
        record->stream = VibeStreamDrained;
        *inputStatus = AVAudioConverterInputStatus_NoDataNow;
        return nil;
    }];
    if (status == AVAudioConverterOutputStatus_Error) {
        LogWarn(@"AudioVoiceBus: conversion failed for %@: %@", record->file.url.lastPathComponent, error.localizedDescription);
        *final = YES;
        return 0;
    }
    AVAudioPCMBuffer *converted = record->convertBuffer;
    uint32_t frames = converted.frameLength;
    *final = status == AVAudioConverterOutputStatus_EndOfStream || (flushing && frames < kDecodeChunkFrames);
    if (converted.format.commonFormat == AVAudioPCMFormatInt16) {
        // Back to float on the 16-bit grid: v / 32768 is exact.
        const int16_t *in = converted.int16ChannelData[0];
        uint32_t channels = converted.format.channelCount;
        for (uint32_t c = 0; c < channels; c++) {
            float *out = record->stageBuffer.floatChannelData[c];
            for (uint32_t i = 0; i < frames; i++) {
                out[i] = (float)in[i * channels + c] / 32768.0f;
            }
        }
    }
    else {
        for (uint32_t c = 0; c < converted.format.channelCount; c++) {
            memcpy(record->stageBuffer.floatChannelData[c], converted.floatChannelData[c], frames * sizeof(float));
        }
    }
    record->stageBuffer.frameLength = frames;
    return frames;
}

// One chunk into the ring. YES when the voice could take another.
- (BOOL)decodeChunkForSlot:(NSUInteger)slot {
    VibeVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
    if ((state != VibeVoiceStateArmed && state != VibeVoiceStateLive)
            || !atomic_load_explicit(&s->readsAllowed, memory_order_acquire)) {
        return NO;
    }
    if (record->stream == VibeStreamEnded) {
        return [self reopenStreamForSlot:slot];
    }
    uint64_t written = atomic_load_explicit(&s->written, memory_order_relaxed);
    uint64_t consumed = atomic_load_explicit(&s->consumed, memory_order_acquire);
    if (_mix->capacity - (written - consumed) < kDecodeChunkFrames) {
        return NO;
    }
    if (!record->positioned) {
        record->positioned = YES;
        record->file.framePosition = record->startFrame;
    }
    if (record->stream == VibeStreamDrained) {
        // The file ran out with the stream open. A successor read the same
        // way continues it here, the boundary at what is written; one that
        // needs a converter of its own, or the render nearing the end, ends
        // it first, the tail after the last frame. With none named, a
        // converter stays open while the render is far from the end, so a
        // successor named late still continues it; a bus-format file has
        // nothing to keep open and ends at once.
        AVAudioFile *successor = [self claimSuccessorForSlot:slot];
        if (successor && [self continueRecord:record intoSuccessor:successor]) {
            record->stream = VibeStreamReading;
            atomic_store_explicit(&s->boundary, written, memory_order_release);
            atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_release);
            return YES;
        }
        if (!successor && record->converter && written - consumed >= kOpenStreamReserveFrames) {
            return NO;
        }
        record->stream = VibeStreamFlushing;
    }
    BOOL final = NO;
    uint32_t frames = [self produceChunkForSlot:slot final:&final];
    // A successor claimed above follows the tail through a converter of its own.
    BOOL switching = final && atomic_load_explicit(&s->successorState, memory_order_relaxed) == VibeSuccessorSwitching;
    if (!switching) {
        if (final) {
            record->stream = VibeStreamEnded;
        }
        [self writeFrames:frames fromRecord:record toSlot:slot written:written final:final];
        [self markLiveIfReadyForSlot:slot];
        // A file that ran out in this chunk is settled in this turn: a
        // successor already named continues at once, and a bus-format file,
        // with nothing to keep open, ends at once.
        return record->stream == VibeStreamDrained ? [self decodeChunkForSlot:slot] : !final;
    }
    // A converter that could not be made ends the stream at this chunk
    // instead; otherwise the boundary is published after the chunk and before
    // any successor frame, so a render that sees them sees where they begin.
    // The None ends the claim.
    BOOL ended = ![self prepareSuccessorForRecord:record];
    if (ended) {
        record->stream = VibeStreamEnded;
    }
    [self writeFrames:frames fromRecord:record toSlot:slot written:written final:ended];
    if (!ended) {
        atomic_store_explicit(&s->boundary, written + frames, memory_order_release);
    }
    atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_release);
    [self markLiveIfReadyForSlot:slot];
    return !ended;
}

// The stream's end was declared before a successor was named — the render
// had neared it, or a bus-format file decoded whole before its boundary
// rendered — and a live voice still takes one, with a converter of its own.
- (BOOL)reopenStreamForSlot:(NSUInteger)slot {
    VibeVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (![self claimSuccessorForSlot:slot]) {
        return NO;
    }
    uint64_t end = atomic_load_explicit(&s->endOfStream, memory_order_relaxed);
    BOOL continues = [self prepareSuccessorForRecord:record];
    if (continues) {
        // TRAP: only the audio thread decides that the voice reached its end,
        // and it may be inside that render now. Withdraw the end, then let
        // every render that could have loaded it finish — the sequence is
        // read after the withdrawal, so a render that began between the two
        // is waited for too — and read the verdict; the render's own load is
        // sequentially consistent for this. Publishing the boundary over a
        // voice that had died at the end made the transport promote, and at
        // once finish, a track that never played.
        atomic_store_explicit(&s->endOfStream, kUnset, memory_order_seq_cst);
        uint64_t renderSequence = atomic_load_explicit(&_mix->renderSequence, memory_order_seq_cst);
        while (atomic_load_explicit(&_mix->inRender, memory_order_seq_cst)
                && atomic_load_explicit(&_mix->renderSequence, memory_order_seq_cst) == renderSequence) {
            sched_yield();
        }
        continues = atomic_load_explicit(&s->state, memory_order_acquire) != VibeVoiceStateDead;
        if (!continues) {
            atomic_store_explicit(&s->endOfStream, end, memory_order_release);
        }
    }
    if (continues) {
        atomic_store_explicit(&s->boundary, end, memory_order_release);
    }
    else {
        record->stream = VibeStreamEnded;
    }
    atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_release);
    return continues;
}

// endOfStream is stored before the final `written` release-store, so a render
// that sees the last frames also sees the end and never counts an underrun.
- (void)writeFrames:(uint32_t)frames fromRecord:(VibeVoiceRecord *)record toSlot:(NSUInteger)slot
            written:(uint64_t)written final:(BOOL)final {
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (frames) {
        uint32_t index = (uint32_t)(written & _mix->mask);
        uint32_t untilWrap = _mix->capacity - index;
        uint32_t first = frames < untilWrap ? frames : untilWrap;
        for (uint32_t c = 0; c < _mix->channels; c++) {
            const float *source = record->stageBuffer.floatChannelData[c];
            memcpy(_mix->rings[slot][c] + index, source, first * sizeof(float));
            if (frames > first) {
                memcpy(_mix->rings[slot][c], source + first, (frames - first) * sizeof(float));
            }
        }
    }
    if (final) {
        atomic_store_explicit(&s->endOfStream, written + frames, memory_order_relaxed);
    }
    atomic_store_explicit(&s->written, written + frames, memory_order_release);
}

- (void)markLiveIfReadyForSlot:(NSUInteger)slot {
    VibeVoiceSlot *s = &_mix->slots[slot];
    uint64_t buffered = atomic_load_explicit(&s->written, memory_order_relaxed) - s->armedWritten;
    if (buffered < kLiveThresholdFrames && atomic_load_explicit(&s->endOfStream, memory_order_relaxed) == kUnset) {
        return;
    }
    int32_t expected = VibeVoiceStateArmed;
    if (atomic_compare_exchange_strong_explicit(&s->state, &expected, VibeVoiceStateLive,
                                                memory_order_acq_rel, memory_order_relaxed)
            && !_inlineDecoding && _voiceWentLive) {
        dispatch_async(_queue, _voiceWentLive);
    }
}

@end
