//
//  AudioLoadTiming.h
//  Vibe
//
//  Phase timings for one waveform decode pass, so each observer's cost is
//  measured in-process rather than inferred from the app's total CPU.
//  The decode has no reply path, so each pass records here and dump_timing and
//  the file_cache reply read it after the fact. Plain C accumulators, so the
//  ObjC++ loader and the plain-ObjC channel share the header.
//

#import <Foundation/Foundation.h>
#import <time.h>

// Nanoseconds per phase of one decode pass. The loader pipelines the read
// against everything downstream, so the phases can sum past total: each is
// that phase's own time, total is the wall.
typedef struct {
    uint64_t read;       // AudioFileHandle readIntoBuffer — the decode itself
    uint64_t chunk;      // the shared mono downmix plus min/max chunk merging
    uint64_t total;      // the whole pass, the phases above, the observers and progress delivery
} VibeLoadPhaseNanos;

// 0 in Release, so every accumulation folds away and call sites need no #if.
static inline uint64_t VibeLoadClockNow(void) {
#if DEBUG
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

#if DEBUG

NS_ASSUME_NONNULL_BEGIN

// The recorded passes, newest first, capped. Thread-safe: decodes record off
// main while the channel reads on main.
@interface AudioLoadTiming : NSObject

// observers maps each observer's identifier to its sink's append and finish
// nanoseconds.
+ (void)recordPath:(NSString *)path
      audioSeconds:(NSTimeInterval)audioSeconds
             nanos:(VibeLoadPhaseNanos)nanos
         observers:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)observers;

// Seconds as doubles, newest first.
+ (NSArray<NSDictionary *> *)recentJSON;

// The newest entry for `path`, or nil.
+ (nullable NSDictionary *)newestJSONForPath:(NSString *)path;

+ (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif
