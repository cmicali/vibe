//
//  AudioLoadTiming.h
//  Vibe
//
//  Phase timings for one waveform decode pass, so the cost of the BPM and key
//  analyzers can be measured in-process rather than inferred from the app's
//  total CPU. The decode runs on a background queue with no reply path of its
//  own, so each pass records into the store below and the debug channel reads
//  it after the fact (dump_timing, and the file_cache reply).
//
//  Plain C accumulators, so the ObjC++ loader and the plain-ObjC debug channel
//  can both use this header.
//

#import <Foundation/Foundation.h>
#import <time.h>

// Nanoseconds spent in each phase of one decode pass. read and chunk are the
// baseline every load pays; the analyzer phases are what a setting turns off.
// The loader pipelines the read against everything downstream, so the phases
// can sum past total: each is that phase's own CPU, total is the wall.
typedef struct {
    uint64_t read;       // AVAudioFile readIntoBuffer — the decode itself
    uint64_t chunk;      // the shared mono downmix plus min/max chunk merging
    uint64_t bpmAppend;  // streaming samples into AudioBPMAnalyzer
    uint64_t bpmFinish;  // its end-of-file tempo estimation
    uint64_t keyAppend;  // streaming samples into AudioKeyAnalyzer
    uint64_t keyFinish;  // its end-of-file profile correlation
    uint64_t total;      // the whole pass, the phases above plus progress delivery
} VibeLoadPhaseNanos;

// The clock the accumulators read. It returns 0 in Release, where nothing
// consumes a timing, so every accumulation folds to a constant and drops out:
// the shipping binary carries no measurement code, and the call sites need no
// #if around them.
static inline uint64_t VibeLoadClockNow(void) {
#if DEBUG
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    return 0;
#endif
}

#if DEBUG

NS_ASSUME_NONNULL_BEGIN

// The recorded passes, newest first, capped and process-lifetime. Thread-safe:
// decodes run on a global queue while the debug channel reads from main.
@interface AudioLoadTiming : NSObject

+ (void)recordPath:(NSString *)path
      audioSeconds:(NSTimeInterval)audioSeconds
        bpmEnabled:(BOOL)bpmEnabled
        keyEnabled:(BOOL)keyEnabled
             nanos:(VibeLoadPhaseNanos)nanos;

// JSON-ready, seconds as doubles, newest first.
+ (NSArray<NSDictionary *> *)recentJSON;

// The newest entry for one file, or nil. The file_cache reply uses it to
// return the timing of the decode it just ran.
+ (nullable NSDictionary *)newestJSONForPath:(NSString *)path;

+ (void)reset;

@end

NS_ASSUME_NONNULL_END

#endif
