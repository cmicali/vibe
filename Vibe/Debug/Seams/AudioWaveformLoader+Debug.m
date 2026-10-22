//
//  AudioWaveformLoader+Debug.m
//  Vibe
//

#import "AudioWaveformLoader+Debug.h"

#if DEBUG

#import <os/lock.h>

static const NSUInteger kMaxRecordedLoads = 256;

@interface AudioLoadTiming ()
@property (copy) NSString *path;
@property NSTimeInterval audioSeconds;
@property VibeLoadPhaseNanos nanos;
@property (copy) NSDictionary<NSString *, NSArray<NSNumber *> *> *observers;
@end

@implementation AudioLoadTiming

static NSMutableArray<AudioLoadTiming *> *sRecorded = nil;
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;

+ (void)recordPath:(NSString *)path
      audioSeconds:(NSTimeInterval)audioSeconds
             nanos:(VibeLoadPhaseNanos)nanos
         observers:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)observers {
    AudioLoadTiming *entry = [AudioLoadTiming new];
    entry.path = path;
    entry.audioSeconds = audioSeconds;
    entry.nanos = nanos;
    entry.observers = observers;
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
    __block uint64_t accounted = n.read + n.chunk;
    NSMutableDictionary<NSString *, NSDictionary *> *observers = [NSMutableDictionary dictionary];
    [self.observers enumerateKeysAndObjectsUsingBlock:^(NSString *identifier, NSArray<NSNumber *> *phases, BOOL *stop) {
        uint64_t append = phases[0].unsignedLongLongValue, finish = phases[1].unsignedLongLongValue;
        accounted += append + finish;
        observers[identifier] = @{@"seconds": @(seconds(append + finish)),
                                  @"appendSeconds": @(seconds(append)),
                                  @"finishSeconds": @(seconds(finish))};
    }];
    return @{
        @"file": self.path.lastPathComponent ?: @"",
        @"audioSeconds": @(self.audioSeconds),
        @"totalSeconds": @(seconds(n.total)),
        @"readSeconds": @(seconds(n.read)),
        @"chunkSeconds": @(seconds(n.chunk)),
        @"observers": observers,
        // Progress snapshots and delivery, plus anything else in the pass.
        @"otherSeconds": @(seconds(n.total > accounted ? n.total - accounted : 0)),
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
