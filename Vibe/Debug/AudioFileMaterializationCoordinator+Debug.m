//
//  AudioFileMaterializationCoordinator+Debug.m
//  Vibe
//

#import "AudioFileMaterializationCoordinator+Debug.h"

#if DEBUG

#import "AudioFileMaterializationCoordinatorInternal.h"

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
static BOOL VibeHangInstalled;

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
        @"handleRuns": @(snapshot.handleRunCount),
        @"datalessProbesInFlight": @(snapshot.datalessProbesInFlight),
        // The stranded-open signal: an AVAudioFile call the OS still owes an
        // answer for. Nonzero at rest means a run will never finish, which no
        // gauge above can say — see docs/testing/materialization-coverage-plan.md.
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
    [gate unlock];
    if (VibeHangInstalled) {
        return;
    }
    VibeHangInstalled = YES;
    AudioFileMaterializationCoordinator *coordinator = self.sharedCoordinator;
    // Chained, never restated: a wrapper that reimplemented the production open
    // would drift from it, and the preflight it performs is load-bearing.
    VibeAudioFileOpener real = coordinator.fileOpener;
    coordinator.fileOpener = ^AVAudioFile *(NSURL *url, NSError **error) {
        NSCondition *inner = VibeHungOpenGate();
        [inner lock];
        if (VibeHangBasename && [url.lastPathComponent isEqualToString:VibeHangBasename]) {
            VibeHungOpens++;
            [inner broadcast];
            while (!VibeHungOpensReleased) {
                [inner wait];
            }
            VibeHungOpens--;
        }
        [inner unlock];
        return real(url, error);
    };
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

#endif
