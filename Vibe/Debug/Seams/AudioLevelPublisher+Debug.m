//
//  AudioLevelPublisher+Debug.m
//  Vibe
//

#import "AudioLevelPublisher+Debug.h"

#if DEBUG

#import "AudioLevelPublisherInternal.h"

@implementation AudioLevelPublisher (Debug)

- (NSDictionary<NSString *, NSNumber *> *)debugState {
    VibeLevelPublisherState *state = [self publisherState];
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

@end

#endif
