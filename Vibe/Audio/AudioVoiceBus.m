//
//  AudioVoiceBus.m
//  Vibe
//

#import "AudioVoiceBusInternal.h"
#if DEBUG
#import "AudioPlayer+Debug.h"
#endif
#import "AudioFileHandle.h"

#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>

@implementation AudioVoiceBus

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
    uint32_t channels = busFormat.channelCount;
    _mix = calloc(1, sizeof(VibeVoiceMix));
    size_t ringFloats = (size_t)kVoiceSlots * channels * capacity;
    _mixStorage = calloc(ringFloats + kVibeVoiceBusMaxRenderFrames, sizeof(float));
    if (!_mix || !_mixStorage) {
        return nil;
    }
    _mix->channels = channels;
    _mix->capacity = capacity;
    _mix->mask = capacity - 1;
    _mix->hostTicksPerFrame = ticksPerFrame;
    for (uint32_t slot = 0; slot < kVoiceSlots; slot++) {
        for (uint32_t channel = 0; channel < channels; channel++) {
            _mix->rings[slot][channel] = _mixStorage + ((size_t)slot * channels + channel) * capacity;
        }
        atomic_init(&_mix->slots[slot].endOfStream, kUnset);
        atomic_init(&_mix->slots[slot].boundary, kUnset);
    }
    _mix->gains = _mixStorage + ringFloats;
    // TRAP: calloc's pages are mapped at their first write, so the scratch
    // only the render writes is written here: a fault on the audio thread
    // waits for a free page. The rings' first writer is the decoder.
    // vDSP_vclr, not memset: clang drops a memset(0) after calloc.
    vDSP_vclr(_mix->gains, 1, kVibeVoiceBusMaxRenderFrames);
    _format = busFormat;
    _queue = queue;
    _inlineDecoding = inlineDecoding;
    if (!inlineDecoding) {
        for (NSUInteger i = 0; i < kVoiceSlots; i++) {
            _decodeQueues[i] = dispatch_queue_create("com.vibe.voicebus.decode",
                    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        }
    }
    _pending = [NSMutableArray array];
    _withheldFiles = [NSMutableSet set];
    _endedPending = [NSMutableArray array];
    _tableLock = OS_UNFAIR_LOCK_INIT;
    _nextIdentifier = 1;
    _nextRetireOrder = 1;
    for (uint32_t s = 0; s < kVoiceSlots; s++) {
        _records[s] = [[AudioVoiceRecord alloc] init];
        _records[s]->stageBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:busFormat frameCapacity:kDecodeChunkFrames];
        if (!_records[s]->stageBuffer) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    free(_mixStorage);
    free(_mix);
}

- (VibeVoiceMix *)mix {
    return _mix;
}

- (uint32_t)ringFrames {
    return _mix->capacity;
}

- (dispatch_queue_t)decodeQueueAtIndex:(NSUInteger)index {
    return index < kVoiceSlots ? _decodeQueues[index] : nil;
}

- (uint64_t)decodeTurns {
    return atomic_load_explicit(&_decodeTurns, memory_order_relaxed);
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

- (AudioVoiceRecord *)pendingRecordForIdentifier:(VibeVoiceID)identifier {
    for (AudioVoiceRecord *record in _pending) {
        if (record->identifier == identifier) {
            return record;
        }
    }
    return nil;
}

// Pending records are queue-owned; the lock shields cross-thread snapshots.
- (void)addPendingRecord:(AudioVoiceRecord *)record {
    os_unfair_lock_lock(&_tableLock);
    [_pending addObject:record];
    os_unfair_lock_unlock(&_tableLock);
}

- (void)removePendingRecord:(AudioVoiceRecord *)record {
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
    _records[slot]->identifier = identifier;
    os_unfair_lock_unlock(&_tableLock);
}

#pragma mark - Starting

- (NSUInteger)freeSlot {
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        if (!VibeSlotIsOccupied(&_mix->slots[s])) {
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
        AudioVoiceRecord *record = _records[s];
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

// The queue a voice of the bus reads `file` on, or may yet: one handle has one
// cursor, so its overlapping reads share a queue. TRAP: a voice has left its
// file only once its reads are stopped for good AND its last turn is over;
// on readsAllowed alone a second queue takes the cursor with the old read
// still inside, and a withheld voice reads again. It may still occupy its
// slot, fading what it buffered.
- (dispatch_queue_t)decodeQueueReadingFile:(AudioFileHandle *)file {
    if (!file) {
        return nil;
    }
    dispatch_queue_t queue = nil;
    os_unfair_lock_lock(&_tableLock);
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        AudioVoiceRecord *record = _records[s];
        VibeVoiceSlot *slot = &_mix->slots[s];
        BOOL mayRead = atomic_load_explicit(&slot->readsAllowed, memory_order_acquire) || record->readsWithheld
                || atomic_load_explicit(&record->fillScheduled, memory_order_acquire);
        if (VibeSlotIsOccupied(slot) && mayRead && (record->file == file || record->successorFile == file)) {
            queue = record->decodeQueue;
            break;
        }
    }
    os_unfair_lock_unlock(&_tableLock);
    return queue;
}

- (dispatch_queue_t)decodeQueueForRecord:(AudioVoiceRecord *)record {
    dispatch_queue_t queue = [self decodeQueueReadingFile:record->file];
    if (queue) {
        return queue;
    }
    // The slot being bound is free, so at most seven queues are in use.
    for (NSUInteger i = 0; i < kVoiceSlots; i++) {
        BOOL used = NO;
        for (NSUInteger s = 0; s < kVoiceSlots && !used; s++) {
            used = VibeSlotIsOccupied(&_mix->slots[s]) && _records[s]->decodeQueue == _decodeQueues[i];
        }
        if (!used) return _decodeQueues[i];
    }
    return nil;
}

- (VibeVoiceID)startVoiceWithFile:(AudioFileHandle *)file atFrame:(AVAudioFramePosition)frame
                         endFrame:(AVAudioFramePosition)endFrame
                             gain:(float)gain
                             ramp:(VibeVoiceRamp)ramp paused:(BOOL)paused {
    VibeVoiceID identifier = _nextIdentifier++;
    if ([self freeSlotCount] <= kFreeSlotReserve) {
        [self cutOldestRetiringVoice];
    }
    AudioVoiceRecord *record = [[AudioVoiceRecord alloc] init];
    record->identifier = identifier;
    record->file = file;
    record->startFrame = frame;
    record->endFrame = MAX(0, endFrame);
    record->gain = gain;
    record->ramp = ramp;
    record->paused = paused;
    NSUInteger slot = _pending.count ? NSNotFound : [self freeSlot];
    if (slot == NSNotFound || ![self bindRecord:record toSlot:slot]) {
        [self addPendingRecord:record];
    }
    _promptDrainDue = YES;
    return identifier;
}

// Allocates the slot for a start: counters carry on from where the slot left
// off, the audio thread's fields are whatever the recycle left, and the
// generation's release-store publishes it all. NO leaves the record unbound
// and the pending list to the caller.
- (BOOL)bindRecord:(AudioVoiceRecord *)record toSlot:(NSUInteger)slot {
    dispatch_queue_t decoder = nil;
    if (!_inlineDecoding && !(decoder = [self decodeQueueForRecord:record])) {
        return NO;
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t expected = VibeVoiceStateNone;
    if (!atomic_compare_exchange_strong_explicit(&s->state, &expected, VibeVoiceStateArmed,
                                                 memory_order_acq_rel, memory_order_relaxed)) {
        return NO;
    }
    // The slot's fields are a seqlock whose version is the generation: the
    // recycle zeroed it, this fence orders that zero before every write
    // below, and the identifier's release-store publishes them, so a snapshot
    // straddling the bind retries. TRAP: the origins are atomics because a
    // snapshot polls them while a seek or skip reuses the slot; plain, they
    // race.
    atomic_thread_fence(memory_order_release);
    AudioVoiceRecord *bound = _records[slot];
    bound->decodeQueue = decoder;
    bound->startFrame = record->startFrame;
    bound->endFrame = record->endFrame;
    bound->positioned = NO;
    bound->waitingSuccessor = record->waitingSuccessor;
    bound->successorStartFrame = record->successorStartFrame;
    bound->successorEndFrame = record->successorEndFrame;
    bound->retireOrder = record->ramp.action == VibeVoiceActionRetire ? _nextRetireOrder++ : 0;
    atomic_store_explicit(&bound->fillScheduled, 0, memory_order_relaxed);
    atomic_store_explicit(&bound->heldOpenAt, kUnset, memory_order_relaxed);
    bound->liveReported = bound->endedReported = NO;
    bound->reportedBoundary = kUnset;
    BOOL prepared = [self prepareRecord:bound file:record->file];
    bound->convertedBase = atomic_load_explicit(&s->written, memory_order_relaxed);
    atomic_store_explicit(&s->armedWritten, atomic_load_explicit(&s->written, memory_order_relaxed), memory_order_relaxed);
    atomic_store_explicit(&s->armedConsumed, atomic_load_explicit(&s->consumed, memory_order_relaxed), memory_order_relaxed);
    bound->readsWithheld = !record->readsStopped && [_withheldFiles containsObject:record->file];
    atomic_store_explicit(&s->readsAllowed, prepared && !record->readsStopped && !bound->readsWithheld, memory_order_relaxed);
    atomic_store_explicit(&s->successorState, VibeSuccessorNone, memory_order_relaxed);
    atomic_store_explicit(&s->paused, record->paused, memory_order_relaxed);
    atomic_store_explicit(&s->gain, record->gain, memory_order_relaxed);
    s->rampSequence = 0;
    // A paused start carries no ramp: adopting one un-pauses, and the first
    // ramp set later is the resume.
    atomic_store_explicit(&s->ramp, record->paused ? 0
            : VibeRampWord(record->ramp.target, record->ramp.frames, record->ramp.curve,
                           record->ramp.action, [self nextRampSequence]), memory_order_relaxed);
    [self setIdentifier:record->identifier forSlot:slot];
    atomic_store_explicit(&s->generation, record->identifier, memory_order_release);
    if (!prepared) {
        [self recordFailure:nil forSlot:slot];
        [self endFailedSlot:slot frames:0 written:atomic_load_explicit(&s->written, memory_order_relaxed)];
        return YES;
    }
    [self publishWaitingSuccessorForSlot:slot];
    [self scheduleFillForSlot:slot];
    return YES;
}

- (void)bindPendingVoices {
    while (_pending.count) {
        AudioVoiceRecord *record = _pending.firstObject;
        NSUInteger slot = [self freeSlot];
        if (slot == NSNotFound || ![self bindRecord:record toSlot:slot]) {
            return;
        }
        [self removePendingRecord:record];
    }
}

#pragma mark - Requests

- (void)setRamp:(VibeVoiceRamp)ramp forVoice:(VibeVoiceID)voice {
    AudioVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
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
    AudioVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->readsStopped = YES;
        return;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot != NSNotFound) {
        _records[slot]->readsWithheld = NO; // stopped stays stopped, whatever its file's standing
        [self stopReadsOfSlot:slot];
    }
}

// Stops the slot's reads for good, and when this is what stopped them, wakes
// a read of its file or successor waiting at a streaming file's edge, which
// returns as an interruption. TRAP: only then. A voice whose reads were
// already stopped may have handed its file to a newer voice, whose reads an
// interrupt would refuse until that voice seeks again. Every call is on the
// player queue, before any newer voice on the file starts.
- (void)stopReadsOfSlot:(NSUInteger)slot {
    if (!atomic_exchange_explicit(&_mix->slots[slot].readsAllowed, 0, memory_order_seq_cst)) {
        return;
    }
    os_unfair_lock_lock(&_tableLock);
    AudioFileHandle *file = _records[slot]->file;
    AudioFileHandle *successor = _records[slot]->successorFile;
    os_unfair_lock_unlock(&_tableLock);
    [file interruptReads];
    [successor interruptReads];
}

// Each serial queue reports after its in-flight read and the group reports
// after them all, to the player queue, which a stalled read never holds.
- (void)stopReadingThen:(dispatch_block_t)decoderLeft {
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        [self stopReadingForVoice:_slotIdentifiers[s]];
    }
    if (_inlineDecoding) {
        decoderLeft();
        return;
    }
    dispatch_group_t stopped = dispatch_group_create();
    for (NSUInteger i = 0; i < kVoiceSlots; i++) {
        dispatch_group_async(stopped, _decodeQueues[i], ^{});
    }
    dispatch_group_notify(stopped, _queue, decoderLeft);
}

// Under the table lock, which the decoder writes a record's file pair under
// too (prepareRecord:, continueRecord:intoSuccessor:, the recycle), so the
// set is coherent with a handoff in flight: the successor is listed in one
// field or the other, never neither.
- (NSSet<AudioFileHandle *> *)filesInUse {
    NSMutableSet<AudioFileHandle *> *files = [NSMutableSet set];
    os_unfair_lock_lock(&_tableLock);
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        if (!VibeSlotIsOccupied(&_mix->slots[s])) {
            continue;
        }
        if (_records[s]->file) [files addObject:_records[s]->file];
        if (_records[s]->successorFile) [files addObject:_records[s]->successorFile];
        if (_records[s]->waitingSuccessor) [files addObject:_records[s]->waitingSuccessor];
    }
    for (AudioVoiceRecord *record in _pending) {
        if (record->file) [files addObject:record->file];
        if (record->waitingSuccessor) [files addObject:record->waitingSuccessor];
    }
    os_unfair_lock_unlock(&_tableLock);
    return files;
}

- (void)withholdReadsOfFile:(AudioFileHandle *)file {
    [_withheldFiles addObject:file];
}

// The voices started on the file while it was withheld read from here: a
// fill is asked for at once, as a start asks for its first.
- (void)allowReadsOfFile:(AudioFileHandle *)file {
    [_withheldFiles removeObject:file];
    for (NSUInteger s = 0; s < kVoiceSlots; s++) {
        AudioVoiceRecord *record = _records[s];
        if (!record->readsWithheld || record->file != file) {
            continue;
        }
        record->readsWithheld = NO;
        int32_t state = atomic_load_explicit(&_mix->slots[s].state, memory_order_acquire);
        if (state != VibeVoiceStateArmed && state != VibeVoiceStateLive) {
            continue;
        }
        atomic_store_explicit(&_mix->slots[s].readsAllowed, 1, memory_order_release);
        [self scheduleFillForSlot:s];
    }
}

#if DEBUG
- (void)debugHoldDecoder:(BOOL)hold {
    atomic_store_explicit(&_debugHoldDecoder, hold ? 1 : 0, memory_order_relaxed);
}

- (void)debugHoldRender:(BOOL)hold {
    atomic_store_explicit(&_mix->holdRender, hold ? 1 : 0, memory_order_seq_cst);
}

- (NSUInteger)debugRendersHeld {
    return (NSUInteger)atomic_load_explicit(&_mix->rendersHeld, memory_order_seq_cst);
}

- (NSDictionary<NSString *, id> *)debugResamplerCostsResetting:(BOOL)reset {
    uint64_t nanos = reset ? atomic_exchange_explicit(&_debugResampleNanos, 0, memory_order_relaxed)
                           : atomic_load_explicit(&_debugResampleNanos, memory_order_relaxed);
    uint64_t frames = reset ? atomic_exchange_explicit(&_debugResampledFrames, 0, memory_order_relaxed)
                            : atomic_load_explicit(&_debugResampledFrames, memory_order_relaxed);
    double seconds = frames / _format.sampleRate;
    return @{
        @"cpuSeconds": @(nanos / 1e9),
        @"audioSeconds": @(seconds),
        // Percent of one core to keep up in real time.
        @"corePercent": @(seconds > 0 ? 100.0 * nanos / 1e9 / seconds : 0),
    };
}
#endif

- (BOOL)queueSuccessor:(AudioFileHandle *)file startFrame:(AVAudioFramePosition)startFrame
              endFrame:(AVAudioFramePosition)endFrame forVoice:(VibeVoiceID)voice {
    if ([_withheldFiles containsObject:file]) {
        return NO; // a retired decoder may be inside it; the transport asks again once it has left
    }
    AudioVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->waitingSuccessor = file;
        pending->successorStartFrame = startFrame;
        pending->successorEndFrame = MAX(0, endFrame);
        return YES;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound || !VibeSlotTakesSuccessor(&_mix->slots[slot])) {
        return NO;
    }
    // Written with the file, and read by the decoder only after its claim of
    // it, which the successorState CAS orders; VibeSlotTakesSuccessor refuses
    // until an earlier successor's claim has ended, so none is overwritten
    // mid-switch.
    os_unfair_lock_lock(&_tableLock);
    _records[slot]->waitingSuccessor = file;
    _records[slot]->successorStartFrame = startFrame;
    _records[slot]->successorEndFrame = MAX(0, endFrame);
    os_unfair_lock_unlock(&_tableLock);
    [self publishWaitingSuccessorForSlot:slot];
    return YES;
}

// Hands the waiting successor to the decoder once no other queue reads its
// file; until then every drain asks again. Only the player queue moves the
// hand-off from none to queued.
- (void)publishWaitingSuccessorForSlot:(NSUInteger)slot {
    AudioVoiceRecord *record = _records[slot];
    VibeVoiceSlot *s = &_mix->slots[slot];
    AudioFileHandle *file = record->waitingSuccessor;
    if (!file || !VibeSlotTakesSuccessor(s) || [_withheldFiles containsObject:file]) {
        return;
    }
    dispatch_queue_t reader = [self decodeQueueReadingFile:file];
    if (reader && reader != record->decodeQueue) {
        return;
    }
    os_unfair_lock_lock(&_tableLock);
    record->successorFile = file;
    record->waitingSuccessor = nil;
    os_unfair_lock_unlock(&_tableLock);
    atomic_store_explicit(&s->successorState, VibeSuccessorQueued, memory_order_release);
    // The decoder may have no turn scheduled — its stream drained or ended —
    // so one is asked for; a turn with nothing to do returns.
    [self scheduleFillForSlot:slot];
}

- (BOOL)unqueueSuccessorForVoice:(VibeVoiceID)voice {
    AudioVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        pending->waitingSuccessor = nil;
        return YES;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return YES;
    }
    os_unfair_lock_lock(&_tableLock);
    BOOL waiting = _records[slot]->waitingSuccessor != nil;
    _records[slot]->waitingSuccessor = nil;
    os_unfair_lock_unlock(&_tableLock);
    if (waiting) {
        return YES; // never the decoder's; a boundary here is an earlier successor's
    }
    VibeVoiceSlot *s = &_mix->slots[slot];
    int32_t expected = VibeSuccessorQueued;
    if (atomic_compare_exchange_strong_explicit(&s->successorState, &expected, VibeSuccessorNone,
                                                memory_order_acq_rel, memory_order_acquire)) {
        os_unfair_lock_lock(&_tableLock);
        _records[slot]->successorFile = nil;
        os_unfair_lock_unlock(&_tableLock);
        return YES;
    }
    // The decoder won the race, or had already switched: successor frames
    // are in the ring, or on their way. Its claim commits the voice from the
    // moment it is made — before the boundary is published — and the None
    // after a switch leaves the boundary behind as the sign.
    return expected == VibeSuccessorNone && atomic_load_explicit(&s->boundary, memory_order_acquire) == kUnset;
}

- (void)killVoice:(VibeVoiceID)voice {
    _promptDrainDue = YES;
    AudioVoiceRecord *pending = [self pendingRecordForIdentifier:voice];
    if (pending) {
        [self removePendingRecord:pending];
        [_endedPending addObject:@(voice)];
        return;
    }
    NSUInteger slot = [self ownedSlotForIdentifier:voice];
    if (slot == NSNotFound) {
        return;
    }
    [self stopReadsOfSlot:slot]; // an armed voice's first read may be waiting
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
    AudioFileHandle *file = nil;
    if (slot != NSNotFound) {
        // Under the lock the decoder moves a record's file pair under.
        file = _records[slot]->file;
        snapshot.waitingForBytes = file.waitingForBytes;
        snapshot.decoding = atomic_load_explicit(&_records[slot]->fillScheduled, memory_order_acquire) != 0;
    }
    os_unfair_lock_unlock(&_tableLock);
    // Outside the table lock: a stream's count takes its availability's lock.
    snapshot.bytesWritten = file.bytesWritten;
    if (slot == NSNotFound) {
        // A pending voice is armed; an unknown or cancelled identity is gone.
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
        uint64_t armedWritten = atomic_load_explicit(&s->armedWritten, memory_order_relaxed);
        uint64_t armedConsumed = atomic_load_explicit(&s->armedConsumed, memory_order_relaxed);
        uint64_t consumed = atomic_load_explicit(&s->consumed, memory_order_acquire);
        uint64_t written = atomic_load_explicit(&s->written, memory_order_acquire);
        uint64_t boundary = atomic_load_explicit(&s->boundary, memory_order_acquire);
        uint64_t endOfStream = atomic_load_explicit(&s->endOfStream, memory_order_acquire);
        snapshot.paused = atomic_load_explicit(&s->paused, memory_order_relaxed) != 0;
        snapshot.ended = (VibeVoiceEnd)atomic_load_explicit(&s->endedReason, memory_order_relaxed);
        snapshot.underrunFrames = atomic_load_explicit(&s->underrun, memory_order_relaxed);
        snapshot.gain = atomic_load_explicit(&s->gain, memory_order_relaxed); // diagnostic, never a decision
        uint32_t version = atomic_load_explicit(&s->stampVersion, memory_order_acquire);
        snapshot.startOfConsumption = VibeStampRead(&s->startStamp);
        atomic_thread_fence(memory_order_acquire);
        BOOL stampsTorn = (version & 1) || atomic_load_explicit(&s->stampVersion, memory_order_relaxed) != version;
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

- (NSDictionary<NSString *, id> *)conversionOfVoice:(VibeVoiceID)voice {
    if (!voice) {
        return nil;
    }
    os_unfair_lock_lock(&_tableLock);
    NSUInteger slot = [self slotForIdentifier:voice];
    NSDictionary *conversion = slot == NSNotFound ? nil : _records[slot]->conversion;
    os_unfair_lock_unlock(&_tableLock);
    return conversion;
}

- (NSError *)errorOfVoice:(VibeVoiceID)voice failedFile:(AudioFileHandle **)file {
    os_unfair_lock_lock(&_tableLock);
    NSUInteger slot = [self slotForIdentifier:voice];
    NSError *failure = slot == NSNotFound ? nil : _records[slot]->failure;
    if (file) *file = failure ? _records[slot]->file : nil;
    os_unfair_lock_unlock(&_tableLock);
    return failure;
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

- (void)drainWithOutputRunning:(BOOL)outputRunning handler:(void (^)(VibeVoiceID, VibeVoiceEvent))handler {
    uint64_t renderSequence = atomic_load_explicit(&_mix->renderSequence, memory_order_acquire);
    BOOL noRenderPossible = !outputRunning && atomic_load_explicit(&_mix->inRender, memory_order_acquire) == 0;
    // Only raised after this: the handler can start or kill a voice in a slot
    // the loop has passed.
    _promptDrainDue = NO;
    for (NSUInteger slot = 0; slot < kVoiceSlots; slot++) {
        VibeVoiceSlot *s = &_mix->slots[slot];
        int32_t state = atomic_load_explicit(&s->state, memory_order_acquire);
        if (state == VibeVoiceStateNone) {
            continue;
        }
        _promptDrainDue |= state != VibeVoiceStateLive; // armed, or dead until its recycle
        AudioVoiceRecord *record = _records[slot];
        VibeVoiceID identifier = record->identifier;
        if (!identifier) {
            continue; // dead, its recycle already queued behind decode work
        }
        [self publishWaitingSuccessorForSlot:slot];
        if (state == VibeVoiceStateArmed) {
            if (VibeSlotCanWrite(s)) {
                [self scheduleFillForSlot:slot]; // withheld or stopped reads are re-asked for by whoever allows them
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
        BOOL boundaryUnreported = boundary != kUnset && boundary != record->reportedBoundary;
        if (boundaryUnreported
                && atomic_load_explicit(&s->consumed, memory_order_acquire) >= boundary
                && (atomic_load_explicit(&s->endedReason, memory_order_acquire) != VibeVoiceEndFailed
                    || atomic_load_explicit(&s->written, memory_order_acquire) > boundary)) {
            record->reportedBoundary = boundary;
            boundaryUnreported = NO;
            handler(identifier, VibeVoiceEventBoundary);
        }
        if (state == VibeVoiceStateLive) {
            // Acquired first, so `written` is at least what it was held at.
            uint64_t heldOpenAt = atomic_load_explicit(&record->heldOpenAt, memory_order_acquire);
            uint64_t written = atomic_load_explicit(&s->written, memory_order_relaxed);
            BOOL heldOpen = heldOpenAt == written;
            if (!_inlineDecoding) {
                uint64_t buffered = written - atomic_load_explicit(&s->consumed, memory_order_relaxed);
                // A stream held open past its file asks for no turn: it would
                // find the same. A successor queued since asks for its own.
                BOOL idle = heldOpen
                        && atomic_load_explicit(&s->successorState, memory_order_relaxed) == VibeSuccessorNone
                        && buffered >= kOpenStreamReserveFrames;
                if (VibeSlotCanWrite(s) && buffered < _mix->capacity / kLowWaterDivisor && !idle) {
                    [self scheduleFillForSlot:slot];
                }
            }
            // An end or a boundary on its way. The decoder reaches its file's
            // end at least half a ring ahead of the render, so a steady drain
            // still sees a boundary or an end published there in time; but a
            // held stream's end is declared only within
            // kOpenStreamReserveFrames of the render — under the steady
            // interval at 96 kHz — so the hold itself is prompt.
            _promptDrainDue |= record->waitingSuccessor || heldOpen || boundaryUnreported
                    || atomic_load_explicit(&s->endOfStream, memory_order_relaxed) != kUnset;
            continue;
        }
        if (!record->endedReported) {
            record->endedReported = YES;
            [self stopReadsOfSlot:slot]; // a crossfade's end, or the stream's, with a turn still waiting
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
                dispatch_async(record->decodeQueue, ^{ [self recycleSlot:slot generation:generation]; });
            }
        }
    }
    // After the recycles, so a slot this drain freed takes a pending start now.
    _promptDrainDue |= _pending.count > 0;
    [self bindPendingVoices];
    if (_endedPending.count) {
        NSArray<NSNumber *> *ended = [_endedPending copy];
        [_endedPending removeAllObjects];
        for (NSNumber *identifier in ended) {
            handler(identifier.unsignedLongLongValue, VibeVoiceEventEnded);
        }
    }
}

#pragma mark - Inline decoding

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

@end
