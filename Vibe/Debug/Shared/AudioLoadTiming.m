//
//  AudioLoadTiming.m
//  Vibe
//
//  See AudioLoadTiming.h. Debug-only: the whole implementation sits inside the
//  same guard as the interface.
//

#import "AudioLoadTiming.h"

#if DEBUG

#import <os/lock.h>

// Enough to hold a folder-sized profiling run without growing without bound.
static const NSUInteger kMaxRecordedLoads = 256;

@interface AudioLoadTiming ()
@property (copy) NSString *path;
@property NSTimeInterval audioSeconds;
@property BOOL bpmEnabled;
@property BOOL keyEnabled;
@property VibeLoadPhaseNanos nanos;
@end

@implementation AudioLoadTiming

static NSMutableArray<AudioLoadTiming *> *sRecorded = nil;
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;

+ (void)recordPath:(NSString *)path
      audioSeconds:(NSTimeInterval)audioSeconds
        bpmEnabled:(BOOL)bpmEnabled
        keyEnabled:(BOOL)keyEnabled
             nanos:(VibeLoadPhaseNanos)nanos {
    AudioLoadTiming *entry = [AudioLoadTiming new];
    entry.path = path;
    entry.audioSeconds = audioSeconds;
    entry.bpmEnabled = bpmEnabled;
    entry.keyEnabled = keyEnabled;
    entry.nanos = nanos;
    os_unfair_lock_lock(&sLock);
    if (!sRecorded) {
        sRecorded = [NSMutableArray array];
    }
    [sRecorded insertObject:entry atIndex:0];
    while (sRecorded.count > kMaxRecordedLoads) {
        [sRecorded removeLastObject];
    }
    os_unfair_lock_unlock(&sLock);
}

- (NSDictionary *)json {
    VibeLoadPhaseNanos n = self.nanos;
    double (^seconds)(uint64_t) = ^double(uint64_t nanos) { return (double)nanos / NSEC_PER_SEC; };
    uint64_t accounted = n.read + n.chunk + n.bpmAppend + n.bpmFinish + n.keyAppend + n.keyFinish;
    return @{
        @"file": self.path.lastPathComponent ?: @"",
        @"audioSeconds": @(self.audioSeconds),
        @"bpmEnabled": @(self.bpmEnabled),
        @"keyEnabled": @(self.keyEnabled),
        @"totalSeconds": @(seconds(n.total)),
        @"readSeconds": @(seconds(n.read)),
        @"chunkSeconds": @(seconds(n.chunk)),
        @"bpmSeconds": @(seconds(n.bpmAppend + n.bpmFinish)),
        @"bpmAppendSeconds": @(seconds(n.bpmAppend)),
        @"bpmFinishSeconds": @(seconds(n.bpmFinish)),
        @"keySeconds": @(seconds(n.keyAppend + n.keyFinish)),
        @"keyAppendSeconds": @(seconds(n.keyAppend)),
        @"keyFinishSeconds": @(seconds(n.keyFinish)),
        // Progress snapshots and delivery, plus anything else in the pass.
        @"otherSeconds": @(seconds(n.total > accounted ? n.total - accounted : 0)),
        // How many seconds of audio each second of decode covers.
        @"realtimeFactor": @(n.total > 0 ? self.audioSeconds / seconds(n.total) : 0),
    };
}

+ (NSArray<NSDictionary *> *)recentJSON {
    os_unfair_lock_lock(&sLock);
    NSArray<AudioLoadTiming *> *snapshot = [sRecorded copy];
    os_unfair_lock_unlock(&sLock);
    NSMutableArray<NSDictionary *> *json = [NSMutableArray arrayWithCapacity:snapshot.count];
    for (AudioLoadTiming *entry in snapshot) {
        [json addObject:[entry json]];
    }
    return json;
}

+ (NSDictionary *)newestJSONForPath:(NSString *)path {
    os_unfair_lock_lock(&sLock);
    NSArray<AudioLoadTiming *> *snapshot = [sRecorded copy];
    os_unfair_lock_unlock(&sLock);
    for (AudioLoadTiming *entry in snapshot) {
        if ([entry.path isEqualToString:path]) {
            return [entry json];
        }
    }
    return nil;
}

+ (void)reset {
    os_unfair_lock_lock(&sLock);
    [sRecorded removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

@end

#endif
