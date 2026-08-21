//
//  AudioLevelPublisher.m
//  Vibe
//

#import "AudioLevelPublisherInternal.h"

#import <stdatomic.h>

struct VibeLevelPublisherState {
    _Atomic uint64_t activeSession;
    _Atomic uint64_t nextSession;
    _Atomic uint64_t nextSequence;
    // Odd means a writer is changing the five level words; equal even values
    // before and after a read prove they came from one coherent publication.
    _Atomic uint64_t writeVersion;
    _Atomic bool writeClaimed;
    _Atomic uint64_t publishedSession;
    _Atomic uint64_t publishedSequence;
    _Atomic uint32_t levelBits[kLevelBandCount];
#if DEBUG
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t analyzedWindowCount;
    _Atomic uint64_t publicationCount;
    _Atomic uint64_t lastCallbackFrameLength;
    _Atomic uint64_t lastSampleRateBits;
#endif
};

@implementation AudioLevelPublisher {
    VibeLevelPublisherState _publisherState;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&_publisherState.activeSession, 0);
        atomic_init(&_publisherState.nextSession, 0);
        atomic_init(&_publisherState.nextSequence, 0);
        atomic_init(&_publisherState.writeVersion, 0);
        atomic_init(&_publisherState.writeClaimed, false);
        atomic_init(&_publisherState.publishedSession, 0);
        atomic_init(&_publisherState.publishedSequence, 0);
        for (NSUInteger band = 0; band < kLevelBandCount; band++) {
            atomic_init(&_publisherState.levelBits[band], 0);
        }
#if DEBUG
        atomic_init(&_publisherState.callbackCount, 0);
        atomic_init(&_publisherState.analyzedWindowCount, 0);
        atomic_init(&_publisherState.publicationCount, 0);
        atomic_init(&_publisherState.lastCallbackFrameLength, 0);
        atomic_init(&_publisherState.lastSampleRateBits, 0);
#endif
    }
    return self;
}

- (VibeLevelPublisherState *)publisherState {
    return &_publisherState;
}

- (uint64_t)beginSession {
    uint64_t session = atomic_fetch_add_explicit(&_publisherState.nextSession, 1,
                                                  memory_order_relaxed) + 1;
    atomic_store_explicit(&_publisherState.activeSession, session, memory_order_release);
    return session;
}

- (void)endSession:(uint64_t)session {
    uint64_t expected = session;
    atomic_compare_exchange_strong_explicit(&_publisherState.activeSession,
                                             &expected, 0,
                                             memory_order_release,
                                             memory_order_relaxed);
}

- (BOOL)copyLevels:(float *)out count:(NSUInteger)count
           sequence:(uint64_t *)sequence {
    if (!out || count == 0 || count > kLevelBandCount) {
        return NO;
    }
    VibeLevelPublisherState *state = &_publisherState;
    // A render-thread publication is only a few stores. If one overlaps this
    // read, retry briefly; never expose a mixture of two band snapshots.
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t activeSession = atomic_load_explicit(&state->activeSession,
                                                       memory_order_acquire);
        uint64_t before = atomic_load_explicit(&state->writeVersion,
                                                memory_order_acquire);
        if (activeSession == 0 || (before & 1) != 0) {
            continue;
        }
        float copied[kLevelBandCount];
        for (NSUInteger band = 0; band < count; band++) {
            uint32_t bits = atomic_load_explicit(&state->levelBits[band],
                                                 memory_order_relaxed);
            memcpy(&copied[band], &bits, sizeof(bits));
        }
        uint64_t publishedSession = atomic_load_explicit(&state->publishedSession,
                                                          memory_order_relaxed);
        uint64_t copiedSequence = atomic_load_explicit(&state->publishedSequence,
                                                        memory_order_relaxed);
        // Keep every snapshot load before the version validation on weakly
        // ordered CPUs; otherwise a matching version could validate too soon.
        atomic_thread_fence(memory_order_acquire);
        uint64_t after = atomic_load_explicit(&state->writeVersion,
                                               memory_order_acquire);
        uint64_t activeAfter = atomic_load_explicit(&state->activeSession,
                                                     memory_order_acquire);
        if (before != after || (after & 1) != 0 || activeSession != activeAfter
                || publishedSession != activeAfter || copiedSequence == 0) {
            continue;
        }
        memcpy(out, copied, count * sizeof(float));
        if (sequence) {
            *sequence = copiedSequence;
        }
        return YES;
    }
    return NO;
}

#if DEBUG
- (NSDictionary<NSString *, NSNumber *> *)debugState {
    VibeLevelPublisherState *state = &_publisherState;
    uint64_t sampleRateBits = atomic_load_explicit(&state->lastSampleRateBits,
                                                    memory_order_relaxed);
    double sampleRate = 0;
    memcpy(&sampleRate, &sampleRateBits, sizeof(sampleRate));
    return @{
        @"installed": @(atomic_load_explicit(&state->activeSession, memory_order_acquire) != 0),
        @"callbacks": @(atomic_load_explicit(&state->callbackCount, memory_order_relaxed)),
        @"analyzedWindows": @(atomic_load_explicit(&state->analyzedWindowCount, memory_order_relaxed)),
        @"publications": @(atomic_load_explicit(&state->publicationCount, memory_order_relaxed)),
        @"sequence": @(atomic_load_explicit(&state->publishedSequence, memory_order_relaxed)),
        @"lastFrameLength": @(atomic_load_explicit(&state->lastCallbackFrameLength, memory_order_relaxed)),
        @"sampleRate": @(sampleRate),
    };
}
#endif

@end

BOOL VibeLevelPublisherPublish(VibeLevelPublisherState *state, uint64_t session,
                               const float levels[kLevelBandCount]) {
    if (atomic_load_explicit(&state->activeSession, memory_order_acquire) != session) {
        return NO;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&state->writeClaimed,
                                                  &expected, true,
                                                  memory_order_acquire,
                                                  memory_order_relaxed)) {
        return NO;
    }
    if (atomic_load_explicit(&state->activeSession, memory_order_acquire) != session) {
        atomic_store_explicit(&state->writeClaimed, false, memory_order_release);
        return NO;
    }

    atomic_fetch_add_explicit(&state->writeVersion, 1, memory_order_acq_rel);
    for (NSUInteger band = 0; band < kLevelBandCount; band++) {
        float level = isfinite(levels[band]) ? MIN(MAX(levels[band], 0.0f), 1.0f) : 0.0f;
        uint32_t bits = 0;
        memcpy(&bits, &level, sizeof(bits));
        atomic_store_explicit(&state->levelBits[band], bits, memory_order_relaxed);
    }

    BOOL stillCurrent = atomic_load_explicit(&state->activeSession,
                                              memory_order_acquire) == session;
    if (stillCurrent) {
        uint64_t sequence = atomic_fetch_add_explicit(&state->nextSequence, 1,
                                                       memory_order_relaxed) + 1;
        atomic_store_explicit(&state->publishedSession, session, memory_order_relaxed);
        atomic_store_explicit(&state->publishedSequence, sequence, memory_order_relaxed);
#if DEBUG
        atomic_fetch_add_explicit(&state->publicationCount, 1, memory_order_relaxed);
#endif
    }
    atomic_fetch_add_explicit(&state->writeVersion, 1, memory_order_release);
    atomic_store_explicit(&state->writeClaimed, false, memory_order_release);
    return stillCurrent;
}

void VibeLevelPublisherRecordCallback(VibeLevelPublisherState *state,
                                      uint64_t frameLength, double sampleRate) {
#if DEBUG
    atomic_fetch_add_explicit(&state->callbackCount, 1, memory_order_relaxed);
    atomic_store_explicit(&state->lastCallbackFrameLength, frameLength,
                          memory_order_relaxed);
    uint64_t sampleRateBits = 0;
    memcpy(&sampleRateBits, &sampleRate, sizeof(sampleRateBits));
    atomic_store_explicit(&state->lastSampleRateBits, sampleRateBits,
                          memory_order_relaxed);
#endif
}

void VibeLevelPublisherRecordAnalyzedWindows(VibeLevelPublisherState *state,
                                             uint64_t count) {
#if DEBUG
    atomic_fetch_add_explicit(&state->analyzedWindowCount, count,
                              memory_order_relaxed);
#endif
}
