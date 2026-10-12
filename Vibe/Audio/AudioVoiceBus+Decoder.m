//
//  AudioVoiceBus+Decoder.m
//  Vibe
//
//  The decode pool's side of the bus: the prepare and its conversion, the
//  failures, the slot recycle, the fills, the converter feed, the chunk
//  decode, the stream's end and its reopen.
//

#import "AudioVoiceBusInternal.h"
#import "AudioFileHandle.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#include <sched.h>

// A decoder's wait for a render to leave the bus is bounded: a render stuck
// past this is not waited for, and the wait's caller does without its verdict.
static const uint64_t kRenderLeaveWaitNanos = 100 * NSEC_PER_MSEC;

static void VibeDisposeConverter(AudioVoiceRecord *record) {
    if (record->converter) {
        VibeResamplerDispose(record->converter);
        record->converter = NULL;
    }
}

@implementation AudioVoiceRecord
- (void)dealloc {
    VibeDisposeConverter(self);
}
@end

@implementation AudioVoiceBus (Decoder)

#pragma mark - Preparing

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
// is needed at the bus rate. A rate difference is converted by the bus's
// resampler (AudioResampler.h).
- (BOOL)prepareRecord:(AudioVoiceRecord *)record file:(AudioFileHandle *)file {
    AVAudioFormat *source = file.processingFormat;
    os_unfair_lock_lock(&_tableLock);
    record->file = file; // filesInUse reads the file pair under the lock; the decoder writes it there
    os_unfair_lock_unlock(&_tableLock);
    VibeDisposeConverter(record);
    record->readBuffer = nil;
    record->mixBuffer = nil;
    record->mixMap = nil;
    record->stream = VibeStreamReading;
    record->fedFrames = 0;
    [self setConversion:nil forRecord:record];
    if (VibePCMFormatsMatch(source, _format)) {
        return YES;
    }
    AVAudioFormat *fed = source; // what the converter takes
    if (!VibeChannelsMatch(source, _format)) {
        record->mixMap = VibeMixMap(source, _format);
        record->readBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:source frameCapacity:kDecodeChunkFrames];
        if (source.sampleRate == _format.sampleRate) {
            [self setConversion:[self conversionFrom:source record:record] forRecord:record];
            return record->readBuffer != nil; // the mix lands in the stage
        }
        fed = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:source.sampleRate
                                                 channels:_format.channelCount interleaved:NO];
        record->mixBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fed frameCapacity:kDecodeChunkFrames];
    }
    record->converter = VibeResamplerCreate(fed.sampleRate, _format.sampleRate, _format.channelCount);
    if (!record->converter) {
        return NO;
    }
    record->readBuffer = record->readBuffer ?: [[AVAudioPCMBuffer alloc] initWithPCMFormat:source frameCapacity:kDecodeChunkFrames];
    [self setConversion:[self conversionFrom:source record:record] forRecord:record];
    return record->readBuffer && (!record->mixMap || record->mixBuffer);
}

// What the prepared record does to `source`, read off the record.
- (NSDictionary<NSString *, id> *)conversionFrom:(AVAudioFormat *)source record:(AudioVoiceRecord *)record {
    NSMutableDictionary *conversion = [@{
        @"fromSampleRate": @(source.sampleRate), @"toSampleRate": @(_format.sampleRate),
        @"fromChannels": @(source.channelCount), @"toChannels": @(_format.channelCount),
        @"mixed": @(record->mixMap != nil), @"resampled": @(source.sampleRate != _format.sampleRate),
    } mutableCopy];
    if (record->converter) {
        conversion[@"algorithm"] = @"r8brain-free-src";
    }
    return conversion;
}

// conversionOfVoice: reads under the table lock, so prepare writes there too.
- (void)setConversion:(NSDictionary *)conversion forRecord:(AudioVoiceRecord *)record {
    os_unfair_lock_lock(&_tableLock);
    record->conversion = conversion;
    os_unfair_lock_unlock(&_tableLock);
}

#pragma mark - Failures

// The error stays off the render thread. Publish it before the terminal frame
// count; a failed successor is attributed to its own URL even before promotion.
- (void)recordFailure:(NSError *)error forSlot:(NSUInteger)slot {
    AudioVoiceRecord *record = _records[slot];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:error.userInfo ?: @{}];
    info[NSURLErrorKey] = record->file.url;
    if (!info[NSLocalizedDescriptionKey]) info[NSLocalizedDescriptionKey] = @"The audio decoder failed";
    NSError *failure = [NSError errorWithDomain:error.domain ?: NSOSStatusErrorDomain
                                           code:error ? error.code : kAudio_ParamError userInfo:info];
    os_unfair_lock_lock(&_tableLock);
    if (!record->failure) record->failure = failure;
    os_unfair_lock_unlock(&_tableLock);
    VibeVoiceSlot *s = &_mix->slots[slot];
    // A refused successor seek still flushes the healthy converter's
    // predecessor samples, in as many chunks as its tail requires.
    if (record->stream != VibeStreamFlushing) {
        atomic_store_explicit(&s->readsAllowed, 0, memory_order_release);
    }
    int32_t none = VibeVoiceEndNone;
    atomic_compare_exchange_strong_explicit(&s->endedReason, &none, VibeVoiceEndFailed,
                                            memory_order_release, memory_order_relaxed);
}

// A read or seek interrupted because the voice's reads were stopped: its turn
// ends, the stream neither drained nor failed, since the voice is being torn
// down or its file handed on. Interrupted with its reads still allowed, it
// was stopped by nobody here, and fails as any read error does.
- (BOOL)readWasInterrupted:(NSError *)error forSlot:(NSUInteger)slot {
    if (![AudioFileHandle isInterruption:error]
            || atomic_load_explicit(&_mix->slots[slot].readsAllowed, memory_order_seq_cst)) {
        return NO;
    }
    AudioVoiceRecord *record = _records[slot];
    record->readInterrupted = YES;
    // TRAP: the identifier under the table lock: the drain clears it on the
    // player queue (setIdentifier:forSlot:) while this turn is still on the
    // decode queue. The file is safe bare: only a recycle on this queue
    // clears it.
    os_unfair_lock_lock(&_tableLock);
    VibeVoiceID identifier = record->identifier;
    os_unfair_lock_unlock(&_tableLock);
    LogInfo(@"AudioVoiceBus: voice %llu's read of %@ was interrupted at its stream's edge",
            identifier, record->file.url.lastPathComponent);
    return YES;
}

- (void)endFailedSlot:(NSUInteger)slot frames:(uint32_t)frames written:(uint64_t)written {
    AudioVoiceRecord *record = _records[slot];
    record->stream = VibeStreamEnded;
    [self writeFrames:frames fromRecord:record toSlot:slot written:written final:YES];
    VibeVoiceSlot *s = &_mix->slots[slot];
    atomic_store_explicit(&s->readsAllowed, 0, memory_order_release);
    // A failed paused start with no samples must settle without waiting for a resume.
    int32_t armed = VibeVoiceStateArmed;
    if (written + frames == atomic_load_explicit(&s->consumed, memory_order_acquire)
            && atomic_compare_exchange_strong_explicit(&s->state, &armed, VibeVoiceStateDead,
                                                       memory_order_release, memory_order_relaxed)) {
        atomic_store_explicit(&s->diedAtRender, 0, memory_order_release);
        [self askForDrain];
    }
    else {
        [self markLiveIfReadyForSlot:slot];
    }
}

// From a decode queue: the player drains now rather than at its next poll,
// or at all under a stopped output, which has no poll.
- (void)askForDrain {
    if (!_inlineDecoding && _needsDrain) {
        dispatch_async(_queue, _needsDrain);
    }
}

#pragma mark - The decoder

// The slot's own decode queue, or the caller's thread under inline decoding —
// never both: the ring has one producer. TRAP: on any other queue it disposes
// the converter and buffers under a turn still in flight. Cleans only the
// death it was queued for. TRAP: a
// decode turn queued for the dead voice can run after the next voice binds
// the slot; every turn checks the generation this clears, or it writes an end
// into a voice that has read nothing, which dies at its first render.
- (void)recycleSlot:(NSUInteger)slot generation:(VibeVoiceID)generation {
    AudioVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (atomic_load_explicit(&s->state, memory_order_acquire) != VibeVoiceStateDead
            || atomic_load_explicit(&s->generation, memory_order_acquire) != generation) {
        return;
    }
    os_unfair_lock_lock(&_tableLock);
    record->file = nil;
    record->successorFile = nil;
    record->waitingSuccessor = nil;
    record->failure = nil;
    os_unfair_lock_unlock(&_tableLock);
    VibeDisposeConverter(record);
    record->readBuffer = nil;
    record->mixBuffer = nil;
    record->mixMap = nil;
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
    atomic_store_explicit(&s->gain, 0, memory_order_relaxed);
    s->rampFrom = s->rampTo = 0;
    s->rampFrames = s->rampElapsed = 0;
    s->rampCurve = s->rampAction = 0;
    s->rampSequence = 0;
    s->consuming = 0;
    atomic_store_explicit(&s->startStamp.flags, 0, memory_order_relaxed); // no render of the next voice yet
    atomic_store_explicit(&s->generation, 0, memory_order_release);
    atomic_store_explicit(&s->state, VibeVoiceStateNone, memory_order_release);
    [self askForDrain];
}

// Inline decoding has no decode queue: fillInline reaches every slot.
- (void)scheduleFillForSlot:(NSUInteger)slot {
    if (_inlineDecoding) {
        return;
    }
    AudioVoiceRecord *record = _records[slot];
    int32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&record->fillScheduled, &expected, 1,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return;
    }
    VibeVoiceID identifier = record->identifier;
    dispatch_async(record->decodeQueue, ^{ [self decodeTurnForSlot:slot identifier:identifier]; });
}

// One chunk per turn, re-dispatched while the ring wants more, so a start's
// first chunk never queues behind a full fill of a voice sharing its queue.
// A turn of a voice since recycled touches nothing: the slot, its record
// and its fill flag belong to whoever holds the slot now.
- (void)decodeTurnForSlot:(NSUInteger)slot identifier:(VibeVoiceID)identifier {
#if DEBUG
    while (atomic_load_explicit(&_debugHoldDecoder, memory_order_relaxed)) {
        usleep(1000);
    }
#endif
    atomic_fetch_add_explicit(&_decodeTurns, 1, memory_order_relaxed);
    AudioVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (atomic_load_explicit(&s->generation, memory_order_acquire) != identifier) {
        return;
    }
    BOOL more = [self decodeChunkForSlot:slot];
    if (more) {
        uint64_t buffered = atomic_load_explicit(&s->written, memory_order_relaxed)
                - atomic_load_explicit(&s->consumed, memory_order_acquire);
        more = _mix->capacity - buffered >= kDecodeChunkFrames;
    }
    if (more) {
        dispatch_async(record->decodeQueue, ^{ [self decodeTurnForSlot:slot identifier:identifier]; });
    }
    else {
        atomic_store_explicit(&record->fillScheduled, 0, memory_order_release);
        if (!atomic_load_explicit(&s->readsAllowed, memory_order_acquire)) {
            [self askForDrain]; // the voice has left its file
        }
    }
}

// The decoder's claim on the queued successor, against the queue's unqueue:
// won, the voice's stream is the successor's from here, whether or not a
// frame of it has reached the ring. nil when none is queued.
- (AudioFileHandle *)claimSuccessorForSlot:(NSUInteger)slot {
    int32_t queued = VibeSuccessorQueued;
    if (!atomic_compare_exchange_strong_explicit(&_mix->slots[slot].successorState, &queued, VibeSuccessorSwitching,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return nil;
    }
    return _records[slot]->successorFile;
}

// A successor with the same processing format, layout included, continues
// through the voice's converter, which is told nothing of the boundary, so
// its filter carries across. NO when it needs a converter of its own.
- (BOOL)continueRecord:(AudioVoiceRecord *)record intoSuccessor:(AudioFileHandle *)successor {
    if (!VibePCMFormatsMatch(record->file.processingFormat, successor.processingFormat)) {
        return NO;
    }
    // TRAP: the pair moves as one under the lock, or a filesInUse snapshot
    // between the writes lists the successor in neither field and the
    // replacement bus reads a file this decoder is inside.
    os_unfair_lock_lock(&_tableLock);
    record->file = successor;
    record->successorFile = nil;
    os_unfair_lock_unlock(&_tableLock);
    record->startFrame = record->successorStartFrame;
    record->endFrame = record->successorEndFrame;
    record->positioned = NO;
    return YES;
}

// Takes the claimed successor out of the record, with a converter of its
// own, to be read over its window; NO with none there.
- (BOOL)prepareSuccessorForRecord:(AudioVoiceRecord *)record {
    AudioFileHandle *successor = record->successorFile;
    if (!successor) {
        return NO;
    }
    // The successor stays in the pair until prepareRecord: makes it the file,
    // so a retirement snapshot meanwhile still lists it.
    record->startFrame = record->successorStartFrame;
    record->endFrame = record->successorEndFrame;
    record->positioned = NO;
    BOOL prepared = [self prepareRecord:record file:successor];
    os_unfair_lock_lock(&_tableLock);
    record->successorFile = nil;
    os_unfair_lock_unlock(&_tableLock);
    return prepared;
}

// One fill's view of its voice, for the converter's input proc.
typedef struct {
    __unsafe_unretained AudioVoiceBus *bus;
    __unsafe_unretained AudioVoiceRecord *record;
    NSUInteger slot;
    BOOL flushing;
    uint64_t readNanos;       // thread CPU inside the file's reads, which the resampler's cost excludes
} VibeResamplerFeed;

// Of `wanted` frames, those the voice may read before its end frame.
static AVAudioFrameCount VibeFramesBeforeEnd(AudioVoiceRecord *record, AVAudioFrameCount wanted) {
    if (record->endFrame <= 0) {
        return wanted;
    }
    AVAudioFramePosition left = record->endFrame - record->cursor;
    return left <= 0 ? 0 : (AVAudioFrameCount)MIN((AVAudioFramePosition)wanted, left);
}

// Supplies the converter one read of the file, mixed to the bus's width
// first when the widths differ, or silence while flushing. The converter
// calls this as often as one chunk needs.
static uint32_t VibeResamplerSupplyInput(void *userData, uint32_t maxFrames, const float **channels) {
    VibeResamplerFeed *input = userData;
    AudioVoiceRecord *record = input->record;
    if (record->readInterrupted) {
        return 0; // the fill asked again after an interruption
    }
    AVAudioPCMBuffer *readBuffer = record->readBuffer;
    readBuffer.frameLength = 0;
    NSError *readError = nil;
    AVAudioFrameCount wanted = MIN(maxFrames, kDecodeChunkFrames);
    if (!input->flushing && !record->failure) {
        // Only the read stops at the end frame: the flush below must push its
        // silence whatever the window.
        AVAudioFrameCount readable = VibeFramesBeforeEnd(record, wanted);
#if DEBUG
        uint64_t started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
#endif
        if (readable > 0 && ![record->file readIntoBuffer:readBuffer frameCount:readable error:&readError]) {
            if ([input->bus readWasInterrupted:readError forSlot:input->slot]) {
                return 0; // not dry: the turn ends
            }
            [input->bus recordFailure:readError forSlot:input->slot];
        }
#if DEBUG
        input->readNanos += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started;
#endif
        record->cursor += readBuffer.frameLength;
    }
    AVAudioPCMBuffer *fed;
    if (input->flushing) {
        // TRAP: silence, never zero frames: r8brain has no end-of-stream
        // call, and zero frames ends the fill with its filter's length of the
        // file still inside it. Silence pushes the whole tail out, and the
        // fill stops at the frames fed (produceChunkForSlot:final:).
        fed = record->mixMap ? record->mixBuffer : readBuffer;
        fed.frameLength = wanted;
        for (AVAudioChannelCount c = 0; c < fed.format.channelCount; c++) {
            memset(fed.floatChannelData[c], 0, wanted * sizeof(float));
        }
    }
    else if (readBuffer.frameLength > 0) {
        record->fedFrames += readBuffer.frameLength;
        fed = readBuffer;
        if (record->mixMap) {
            VibeApplyMixMap(record->mixMap.bytes, readBuffer, record->mixBuffer, readBuffer.frameLength);
            fed = record->mixBuffer;
        }
    }
    else {
        // Dry with the stream open: no frames end the fill with the filter primed.
        record->stream = VibeStreamDrained;
        return 0;
    }
    for (AVAudioChannelCount c = 0; c < fed.format.channelCount; c++) {
        channels[c] = fed.floatChannelData[c];
    }
    return fed.frameLength;
}

// Reads one chunk of the voice's file into the stage buffer, in the bus
// format. The file's end is a read that comes up short or empty — never
// framePosition == length alone, which a truncated file never reaches — or
// the voice's end frame, and drains the stream: a converter is told nothing of
// it until the stream is flushing, when silence pushes its tail out up to the
// frames fed, at the bus rate (streamEndForRecord:written:). *final says the
// end is out.
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final {
    AudioVoiceRecord *record = _records[slot];
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
        AVAudioFrameCount asked = VibeFramesBeforeEnd(record, kDecodeChunkFrames);
        BOOL read = asked == 0 || [record->file readIntoBuffer:into frameCount:asked error:&error];
        if (!read && [self readWasInterrupted:error forSlot:slot]) {
            return 0;
        }
        if (!read) {
            [self recordFailure:error forSlot:slot];
            *final = YES;
        }
        // A failed multi-read can still return a valid prefix. Publish it once,
        // followed by the failure; no later read or successor may hide the error.
        uint32_t frames = into.frameLength;
        record->cursor += frames;
        if (record->mixMap) {
            VibeApplyMixMap(record->mixMap.bytes, record->readBuffer, record->stageBuffer, frames);
        }
        if (!read || frames < asked || (record->endFrame > 0 && record->cursor >= record->endFrame)
                || record->file.framePosition >= record->file.length) {
            record->stream = VibeStreamDrained;
        }
        return frames;
    }
    AVAudioPCMBuffer *converted = record->stageBuffer;
    // A flush fills up to the frames fed, at the bus rate, and no further.
    uint64_t left = UINT64_MAX;
    if (flushing) {
        uint64_t written = atomic_load_explicit(&_mix->slots[slot].written, memory_order_relaxed); // the decoder's own
        uint64_t end = [self streamEndForRecord:record written:written];
        left = end > written ? end - written : 0;
        if (left == 0) {
            *final = YES;
            return 0;
        }
    }
    VibeResamplerFeed input = { self, record, slot, flushing, 0 };
#if DEBUG
    uint64_t started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
#endif
    uint32_t frames = VibeResamplerFill(record->converter, VibeResamplerSupplyInput, &input,
                                        (uint32_t)MIN((uint64_t)kDecodeChunkFrames, left), converted.floatChannelData);
#if DEBUG
    uint64_t spent = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started;
    atomic_fetch_add_explicit(&_debugResampleNanos, spent > input.readNanos ? spent - input.readNanos : 0,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&_debugResampledFrames, frames, memory_order_relaxed);
#endif
    converted.frameLength = frames;
    *final = flushing && frames >= left;
    return frames;
}

// One chunk into the ring. YES when the voice could take another.
- (BOOL)decodeChunkForSlot:(NSUInteger)slot {
    AudioVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
    if ((state != VibeVoiceStateArmed && state != VibeVoiceStateLive) || !VibeSlotCanWrite(s)) {
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
    if (!record->positioned && !record->failure) {
        // TRAP: reads are allowed again here and nowhere else, at this voice's
        // first seek of its file, on its own decode queue. The voice that read
        // the file before was stopped and interrupted on the player queue
        // before this one started, and a turn of it still in flight made this
        // voice share its serial queue, so that turn has returned and no other
        // read is inside the file. A stop of this voice landing between the
        // allow and the seek is caught by the re-check, which interrupts again.
        [record->file allowReads];
        if (!atomic_load_explicit(&s->readsAllowed, memory_order_seq_cst)) {
            [record->file interruptReads];
            return NO;
        }
        NSError *error = nil;
        if (![record->file seekToFrame:record->startFrame error:&error]) {
            if ([self readWasInterrupted:error forSlot:slot]) {
                record->readInterrupted = NO;
                return NO;
            }
            record->stream = VibeStreamFlushing;
            [self recordFailure:error forSlot:slot];
        }
        else {
            record->positioned = YES;
            record->cursor = record->startFrame;
        }
    }
    if (record->stream == VibeStreamDrained) {
        // The file ran out with the stream open. A successor read the same
        // way continues it here, the boundary at what is written; one that
        // needs a converter of its own, or the render nearing the end, ends
        // it first, the tail after the last frame. With none named, a
        // converter stays open while the render is far from the end, so a
        // successor named late still continues it; a bus-format file has
        // nothing to keep open and ends at once.
        AudioFileHandle *successor = [self claimSuccessorForSlot:slot];
        if (successor && [self continueRecord:record intoSuccessor:successor]) {
            record->stream = VibeStreamReading;
            atomic_store_explicit(&s->boundary, [self streamEndForRecord:record written:written], memory_order_release);
            atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_release);
            return YES;
        }
        if (!successor && record->converter && written - consumed >= kOpenStreamReserveFrames) {
            atomic_store_explicit(&record->heldOpenAt, written, memory_order_release);
            return NO;
        }
        record->stream = VibeStreamFlushing;
    }
    BOOL final = NO;
    uint32_t frames = [self produceChunkForSlot:slot final:&final];
    if (record->readInterrupted) {
        record->readInterrupted = NO;
        return NO; // nothing written: the voice is torn down or its file handed on
    }
    if (record->failure && (record->stream != VibeStreamFlushing || final)) {
        // Keep produced output; discard unproduced converter tail after an error.
        [self endFailedSlot:slot frames:frames written:written];
        return NO;
    }
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
        [self recordFailure:nil forSlot:slot];
        record->stream = VibeStreamEnded;
    }
    [self writeFrames:frames fromRecord:record toSlot:slot written:written final:ended];
    if (!ended) {
        record->convertedBase = written + frames;
        atomic_store_explicit(&s->boundary, written + frames, memory_order_release);
    }
    atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_release);
    [self markLiveIfReadyForSlot:slot];
    return !ended;
}

// The frames the converter was fed, at the bus rate, from where it began —
// not `written`, which the resampler holds back by its filter's length until
// the successor pushes it out, so the next track would promote early.
- (uint64_t)streamEndForRecord:(AudioVoiceRecord *)record written:(uint64_t)written {
    if (!record->converter) {
        return written;
    }
    double ratio = _format.sampleRate / record->file.processingFormat.sampleRate;
    return record->convertedBase + (uint64_t)llround((double)record->fedFrames * ratio);
}

// The stream's end was declared before a successor was named — the render
// had neared it, or a bus-format file decoded whole before its boundary
// rendered — and a live voice still takes one, with a converter of its own.
- (BOOL)reopenStreamForSlot:(NSUInteger)slot {
    AudioVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    if (![self claimSuccessorForSlot:slot]) {
        return NO;
    }
    uint64_t end = atomic_load_explicit(&s->endOfStream, memory_order_relaxed);
    BOOL continues = [self prepareSuccessorForRecord:record];
    if (!continues) [self recordFailure:nil forSlot:slot];
    if (continues) {
        record->convertedBase = end;
        // TRAP: only the audio thread decides the voice reached its end, and
        // it may be inside that render now. Withdraw the end (seq_cst, as the
        // render's load), wait out every render that could have loaded it,
        // then read the verdict; a boundary published over a voice that died
        // at the end promotes, and at once finishes, a track that never
        // played. TRAP: the wait is bounded and yields to stopped reads, or a
        // stuck render holds the assigned decode queue; with no verdict the end
        // goes back and the stream ends.
        atomic_store_explicit(&s->endOfStream, kUnset, memory_order_seq_cst);
        uint64_t renderSequence = atomic_load_explicit(&_mix->renderSequence, memory_order_seq_cst);
        uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + kRenderLeaveWaitNanos;
        BOOL verdict = YES;
        while (atomic_load_explicit(&_mix->inRender, memory_order_seq_cst)
                && atomic_load_explicit(&_mix->renderSequence, memory_order_seq_cst) == renderSequence) {
            if (!atomic_load_explicit(&s->readsAllowed, memory_order_acquire)
                    || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) >= deadline) {
                verdict = NO;
                break;
            }
            sched_yield();
        }
        continues = verdict && atomic_load_explicit(&s->state, memory_order_acquire) != VibeVoiceStateDead;
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
- (void)writeFrames:(uint32_t)frames fromRecord:(AudioVoiceRecord *)record toSlot:(NSUInteger)slot
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
    uint64_t buffered = atomic_load_explicit(&s->written, memory_order_relaxed)
            - atomic_load_explicit(&s->armedWritten, memory_order_relaxed);
    if (buffered < kLiveThresholdFrames && atomic_load_explicit(&s->endOfStream, memory_order_relaxed) == kUnset) {
        return;
    }
    int32_t expected = VibeVoiceStateArmed;
    if (atomic_compare_exchange_strong_explicit(&s->state, &expected, VibeVoiceStateLive,
                                                memory_order_acq_rel, memory_order_relaxed)) {
        [self askForDrain];
    }
}

@end
