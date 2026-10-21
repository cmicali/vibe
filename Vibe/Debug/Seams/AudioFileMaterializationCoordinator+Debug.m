//
//  AudioFileMaterializationCoordinator+Debug.m
//  Vibe
//

#import "AudioFileMaterializationCoordinator+Debug.h"

#if DEBUG

#import "AudioFileMaterializationCoordinatorInternal.h"

#include <stdatomic.h>

// Guards all three, and is also the release broadcast. A hung open waits here,
// not on a semaphore, so one release frees every held open without the caller
// having to know how many there are.
static NSCondition *VibeHungOpenGate(void) {
    static NSCondition *gate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gate = [[NSCondition alloc] init]; });
    return gate;
}

static NSString *VibeHangBasename;
static NSUInteger VibeHungOpens;
static BOOL VibeHungOpensReleased = YES;

// Chained, never restated: a wrapper that reimplemented the caller's open
// would drift from it.
VibeAudioFileOpener VibeDebugHangingOpener(VibeAudioFileOpener real) {
    return ^id<ServedFileHandle>(NSURL *url, BOOL (^interrupted)(void), NSError **error) {
        NSCondition *gate = VibeHungOpenGate();
        [gate lock];
        if (VibeHangBasename && [url.lastPathComponent isEqualToString:VibeHangBasename]) {
            VibeHungOpens++;
            [gate broadcast];
            while (!VibeHungOpensReleased) {
                [gate wait];
            }
            VibeHungOpens--;
        }
        [gate unlock];
        return real(url, interrupted, error);
    };
}

@implementation AudioFileMaterializationCoordinator (Debug)

- (NSDictionary<NSString *, NSNumber *> *)debugState {
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [self stateSnapshotForTesting];
    return @{
        @"claims": @(snapshot.claimCount),
        @"waiters": @(snapshot.waiterCount),
        @"interactiveRunning": @(snapshot.interactiveRunningCount),
        @"backgroundRunning": @(snapshot.backgroundRunningCount),
        @"interactivePending": @(snapshot.interactivePendingCount),
        @"backgroundPending": @(snapshot.backgroundPendingCount),
        @"foregroundTransferActive": @(snapshot.foregroundTransferActive),
        @"readableClaims": @(snapshot.readableClaimCount),
        @"handleRuns": @(snapshot.handleRunCount),
        @"datalessProbesInFlight": @(snapshot.datalessProbesInFlight),
        // Opener calls the OS still owes an answer for. Nonzero at
        // rest is a stranded run, which no gauge above shows.
        @"handleOpensInFlight": @(snapshot.handleOpensStarted
                                  - snapshot.handleOpensCompleted),
        @"handleOpensStarted": @(snapshot.handleOpensStarted),
        @"handleOpensCompleted": @(snapshot.handleOpensCompleted),
        @"requestsReady": @(snapshot.requestsReady),
        @"requestsFailed": @(snapshot.requestsFailed),
        @"requestsYielded": @(snapshot.requestsYielded),
        @"requestsAdmissionExhausted": @(snapshot.requestsAdmissionExhausted),
    };
}

+ (void)debugHangOpensForBasename:(NSString *)basename {
    NSCondition *gate = VibeHungOpenGate();
    [gate lock];
    VibeHangBasename = [basename copy];
    VibeHungOpensReleased = (basename == nil);
    [gate broadcast];
    [gate unlock];
}

+ (void)debugReleaseHungOpens {
    NSCondition *gate = VibeHungOpenGate();
    [gate lock];
    VibeHangBasename = nil;
    VibeHungOpensReleased = YES;
    [gate broadcast];
    [gate unlock];
}

+ (NSUInteger)debugHungOpenCount {
    NSCondition *gate = VibeHungOpenGate();
    [gate lock];
    NSUInteger count = VibeHungOpens;
    [gate unlock];
    return count;
}

@end

@implementation AudioFileMaterializationCoordinator (DebugCounters)

// Started first: an open racing the two loads reads low, never one high,
// which quiescence's zero-at-rest check would report as a stranded open.
- (uint64_t)handleOpensInFlight {
    uint64_t started = atomic_load(&_handleOpensStarted);
    uint64_t completed = atomic_load(&_handleOpensCompleted);
    return started > completed ? started - completed : 0;
}

- (void)countHandleOpenStarted {
    atomic_fetch_add(&_handleOpensStarted, 1);
}

- (void)countHandleOpenCompleted {
    atomic_fetch_add(&_handleOpensCompleted, 1);
}

@end

#endif
