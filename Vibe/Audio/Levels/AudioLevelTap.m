//
//  AudioLevelTap.m
//  Vibe
//

#import "AudioLevelTap.h"

#import "AudioLevelAnalyzer.h"
#import "AudioLevelPublisherInternal.h"

#include <stdatomic.h>

_Static_assert(__atomic_always_lock_free(sizeof(double), 0), "Signal snapshots require lock-free 64-bit atomics");

// The analyzer keeps at most the stereo pair.
enum { kMeterChannels = 2 };

struct VibeLevelMeter {
    VibeAudioLevelAnalyzer *analyzer;
    VibeLevelPublisherState *publisherState;
    _Atomic uint64_t session;            // the publisher session an install began
    _Atomic uint32_t installGeneration;  // bumped per install; the render restarts its buffer on a change
    uint32_t renderGeneration;
    // The publication cadence: a tap buffer's worth of frames at the tap's
    // rate, the analyzer's windows summarized once it is reached.
    uint32_t target;
    uint32_t fill;
    double sampleRate;
#if VIBE_VERBOSE_LOGGING
    _Atomic uint64_t signalRequest, signalVersion, signalResultRequest;
    _Atomic uint64_t signalFramesResult, signalHostResult, signalOffsetResult, signalNonfiniteResult, signalLeadingFramesResult;
    _Atomic int64_t signalSampleResult;
    _Atomic double signalPeakResult, signalRMSResult, signalRateResult;
    _Atomic double signalHostOrigin, signalSampleOrigin, signalHostCutoff, signalSampleCutoff;
    _Atomic double signalObservationStartResult, signalFirstAfterStartResult;
    uint64_t signalObservedRequest, signalFrames, signalSamples, signalNonfinite;
    uint64_t signalFirstHost, signalFirstOffset, signalLeadingFrames;
    int64_t signalFirstSample;
    double signalPeak, signalSum, signalRate;
    double signalObservationStart, signalFirstAfterStart, hostSecondsPerTick;
    BOOL signalFound;
#endif
};

#pragma mark - The audio thread

// The calls the compiler cannot check: the analyzer's vDSP FFT, and the
// probe's clock read. Everything around them is under the error pragma below.
VIBE_REALTIME_UNCHECKED_BEGIN
static inline void VibeLevelMeterConsume(VibeLevelMeter *meter, float *const *channels, UInt32 channelCount,
                                         UInt32 frames) CA_REALTIME_API {
    VibeAudioLevelAnalyzerConsume(meter->analyzer, channels, channelCount, frames);
}

static inline NSUInteger VibeLevelMeterSummarize(VibeLevelMeter *meter, float levels[kLevelBandCount]) CA_REALTIME_API {
    return VibeAudioLevelAnalyzerSummarize(meter->analyzer, levels);
}

static inline void VibeLevelMeterResetAnalyzer(VibeLevelMeter *meter) CA_REALTIME_API {
    VibeAudioLevelAnalyzerReset(meter->analyzer);
}

#if VIBE_VERBOSE_LOGGING
static inline uint64_t VibeLevelMeterNow(void) CA_REALTIME_API {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
#endif
VIBE_REALTIME_END

VIBE_REALTIME_CHECKED_BEGIN
#if VIBE_VERBOSE_LOGGING
// Only the audio thread writes the accumulators. Atomic result words plus the
// version let the queue read without allocating, locking or logging here.
static void VibeLevelMeterCapture(VibeLevelMeter *meter, float *const *channels, UInt32 channelCount, UInt32 frames,
                                  double rate, const AudioTimeStamp *when) CA_REALTIME_API {
    uint64_t request = atomic_load(&meter->signalRequest);
    if (!request || VibeLevelMeterNow() - request >= 3 * NSEC_PER_SEC
            || (meter->signalObservedRequest == request && meter->signalFound)) return;
    BOOL hostValid = (when->mFlags & kAudioTimeStampHostTimeValid) != 0;
    BOOL sampleValid = (when->mFlags & kAudioTimeStampSampleTimeValid) != 0;
    // A block can still carry the previous track's audio: everything before
    // the cutoff is excluded.
    double origin = atomic_load(&meter->signalHostOrigin), cutoff = atomic_load(&meter->signalHostCutoff);
    double bufferTime = hostValid ? when->mHostTime * meter->hostSecondsPerTick : NAN;
    // On the sample clock the origin is a whole frame, so offsets from it are
    // computed in frames: two times converted to seconds and subtracted can
    // land a hair under a boundary they meet exactly.
    int64_t originFrame = -1;
    if (!isfinite(origin) || !isfinite(bufferTime)) {
        origin = atomic_load(&meter->signalSampleOrigin);
        cutoff = atomic_load(&meter->signalSampleCutoff);
        bufferTime = sampleValid && rate > 0 ? when->mSampleTime / rate : NAN;
        if (isfinite(origin)) originFrame = llround(origin * rate);
    }
    if (request != atomic_load(&meter->signalRequest) || !isfinite(origin) || !isfinite(bufferTime)
            || !isfinite(cutoff) || bufferTime + frames / rate <= cutoff) return;
    UInt32 skip = (UInt32)MIN((double)frames, MAX(0, ceil((cutoff - bufferTime) * rate - 1e-6)));
    if (meter->signalObservedRequest != request || meter->signalRate != rate) {
        meter->signalRate = rate;
        meter->signalObservedRequest = request;
        meter->signalFrames = meter->signalSamples = meter->signalNonfinite = 0;
        meter->signalPeak = meter->signalSum = 0;
        meter->signalFirstSample = -1;
        meter->signalFirstHost = meter->signalFirstOffset = 0;
        meter->signalFound = NO;
        meter->signalObservationStart = MAX(0, originFrame >= 0 ? (double)((int64_t)when->mSampleTime + skip - originFrame) / rate
                                                                : bufferTime + skip / rate - origin);
        meter->signalFirstAfterStart = -1;
    }
    uint64_t limit = (uint64_t)(rate * 3);
    if (meter->signalFrames >= limit) return;
    UInt32 count = (UInt32)MIN((uint64_t)(frames - skip), limit - meter->signalFrames);
    for (UInt32 f = skip; f < skip + count; f++) {
        for (UInt32 c = 0; c < channelCount; c++) {
            double value = channels[c][f];
            if (!isfinite(value)) { meter->signalNonfinite++; continue; }
            meter->signalSamples++;
            meter->signalSum += value * value;
            meter->signalPeak = MAX(meter->signalPeak, fabs(value));
            if (!meter->signalFound && fabs(value) >= 0.001) {
                meter->signalFound = YES;
                meter->signalLeadingFrames = meter->signalFrames + f - skip;
                meter->signalFirstAfterStart = MAX(0, originFrame >= 0 ? (double)((int64_t)when->mSampleTime + f - originFrame) / rate
                                                                       : bufferTime + f / rate - origin);
                meter->signalFirstHost = hostValid ? when->mHostTime : 0;
                meter->signalFirstOffset = f;
                meter->signalFirstSample = sampleValid ? (int64_t)when->mSampleTime + f : -1;
            }
        }
    }
    meter->signalFrames += count;
    atomic_fetch_add(&meter->signalVersion, 1);
    atomic_store(&meter->signalResultRequest, request);
    atomic_store(&meter->signalFramesResult, meter->signalFrames);
    atomic_store(&meter->signalHostResult, meter->signalFirstHost);
    atomic_store(&meter->signalOffsetResult, meter->signalFirstOffset);
    atomic_store(&meter->signalSampleResult, meter->signalFirstSample);
    atomic_store(&meter->signalNonfiniteResult, meter->signalNonfinite);
    atomic_store(&meter->signalLeadingFramesResult, meter->signalFound ? meter->signalLeadingFrames : meter->signalFrames);
    atomic_store(&meter->signalPeakResult, meter->signalPeak);
    atomic_store(&meter->signalRMSResult, meter->signalSamples ? sqrt(meter->signalSum / meter->signalSamples) : 0);
    atomic_store(&meter->signalRateResult, rate);
    atomic_store(&meter->signalObservationStartResult, meter->signalObservationStart);
    atomic_store(&meter->signalFirstAfterStartResult, meter->signalFirstAfterStart);
    atomic_fetch_add(&meter->signalVersion, 1);
}
#endif

void VibeLevelMeterRender(VibeLevelMeter *meter, float * _Nonnull const * _Nonnull channels, UInt32 channelCount, UInt32 frames,
                          const AudioTimeStamp *timestamp) CA_REALTIME_API {
    if (!meter || channelCount == 0 || frames == 0 || !channels[0]) {
        return;
    }
    // A fresh install restarts the cadence and the analyzer, so no earlier
    // audio is published. TRAP: restarting the meter's own count alone left
    // the analyzer's partial window and references in place — the tap is
    // kept across demand changes — and the first publication of a new
    // session carried the previous track's samples into the bars.
    uint32_t generation = atomic_load_explicit(&meter->installGeneration, memory_order_acquire);
    if (generation != meter->renderGeneration) {
        meter->renderGeneration = generation;
        meter->fill = 0;
        VibeLevelMeterResetAnalyzer(meter);
    }
#if VIBE_VERBOSE_LOGGING
    if (timestamp) {
        VibeLevelMeterCapture(meter, channels, channelCount, frames, meter->sampleRate, timestamp);
    }
#endif
    // The samples go to the analyzer as they come, and it analyzes each
    // window in the callback that fills it; at every tap buffer's worth the
    // windows so far are summarized and published once, the cadence the
    // engine's tap once delivered at.
    UInt32 analyzed = channelCount < kMeterChannels ? channelCount : kMeterChannels;
    UInt32 consumed = 0;
    while (consumed < frames) {
        uint32_t room = meter->target - meter->fill;
        uint32_t take = frames - consumed < room ? frames - consumed : room;
        float *slice[kMeterChannels] = { channels[0] + consumed, channels[analyzed - 1] + consumed };
        VibeLevelMeterConsume(meter, slice, analyzed, take);
        meter->fill += take;
        consumed += take;
        if (meter->fill < meter->target) {
            continue;
        }
        VibeLevelPublisherRecordCallback(meter->publisherState, meter->fill, meter->sampleRate);
        float levels[kLevelBandCount];
        NSUInteger windows = VibeLevelMeterSummarize(meter, levels);
        VibeLevelPublisherRecordAnalyzedWindows(meter->publisherState, windows);
        if (windows > 0) {
            VibeLevelPublisherPublish(meter->publisherState, atomic_load_explicit(&meter->session, memory_order_relaxed), levels);
        }
        meter->fill = 0;
    }
}
VIBE_REALTIME_END

#pragma mark - The tap

@implementation AudioLevelTap {
    VibeLevelMeter *_meter;
    AudioLevelPublisher *_publisher;
    BOOL _installed;
#if VIBE_VERBOSE_LOGGING
    void (^_signalCompletion)(NSDictionary<NSString *, id> *);
    NSDictionary<NSString *, id> *_signalSnapshot;
    BOOL _signalWaitingForRetiredAudio;
    AVAudioTime *_signalOverlapEndTime;
#endif
}

- (instancetype)initWithFormat:(AVAudioFormat *)format
                     publisher:(AudioLevelPublisher *)publisher
             normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!publisher || format.sampleRate <= 0 || format.channelCount == 0) {
        LogWarn(@"AudioLevelTap: no usable format, no levels");
        return nil;
    }
    VibeLevelMeter *meter = calloc(1, sizeof(VibeLevelMeter));
    if (!meter) {
        LogError(@"AudioLevelTap: meter allocation failed, no levels");
        return nil;
    }
    _meter = meter;
    meter->sampleRate = format.sampleRate;
    meter->target = VibeLevelTapBufferFrameCount(format.sampleRate);
    meter->analyzer = VibeAudioLevelAnalyzerCreate(format.sampleRate, normalizationMode);
    if (!meter->analyzer) {
        LogError(@"AudioLevelTap: analyzer allocation failed, no levels");
        return nil;
    }
#if VIBE_VERBOSE_LOGGING
    atomic_init(&meter->signalRequest, 0);
    atomic_init(&meter->signalVersion, 0);
    atomic_init(&meter->signalResultRequest, 0);
    atomic_init(&meter->signalFramesResult, 0);
    atomic_init(&meter->signalHostResult, 0);
    atomic_init(&meter->signalOffsetResult, 0);
    atomic_init(&meter->signalSampleResult, -1);
    atomic_init(&meter->signalNonfiniteResult, 0);
    atomic_init(&meter->signalLeadingFramesResult, 0);
    atomic_init(&meter->signalPeakResult, 0);
    atomic_init(&meter->signalRMSResult, 0);
    atomic_init(&meter->signalRateResult, 0);
    atomic_init(&meter->signalHostOrigin, NAN);
    atomic_init(&meter->signalSampleOrigin, NAN);
    atomic_init(&meter->signalHostCutoff, INFINITY);
    atomic_init(&meter->signalSampleCutoff, INFINITY);
    atomic_init(&meter->signalObservationStartResult, 0);
    atomic_init(&meter->signalFirstAfterStartResult, -1);
    meter->hostSecondsPerTick = [AVAudioTime secondsForHostTime:NSEC_PER_SEC] / NSEC_PER_SEC;
#endif
    _publisher = publisher;
    meter->publisherState = [publisher publisherState];
    LogDebug(@"AudioLevelTap: meter at %.0f Hz, %lu-frame FFT, a publication every %u frames",
             format.sampleRate, (unsigned long)VibeAudioLevelAnalyzerFFTSize(meter->analyzer), meter->target);
    return self;
}

- (void)dealloc {
    [self remove];
    if (_meter) {
        VibeAudioLevelAnalyzerDestroy(_meter->analyzer);
        free(_meter);
    }
}

- (VibeLevelMeter *)meter {
    return _meter;
}

- (double)sampleRate {
    return _meter->sampleRate;
}

- (BOOL)installed {
    return _installed;
}

- (void)install {
    if (_installed) {
        return;
    }
    atomic_store_explicit(&_meter->session, [_publisher beginSession], memory_order_relaxed);
    atomic_fetch_add_explicit(&_meter->installGeneration, 1, memory_order_release);
    _installed = YES;
}

- (void)remove {
    if (!_installed) {
        return;
    }
    [self finishSignalDiagnostics:@"tap removed"];
    [_publisher endSession:atomic_load_explicit(&_meter->session, memory_order_relaxed)];
    _installed = NO;
}

#pragma mark - The signal probe

- (void)finishSignalDiagnostics:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    if (!_signalCompletion) return;
    NSMutableDictionary *snapshot = [[self signalDiagnosticSnapshot] mutableCopy];
    snapshot[@"completion"] = reason;
    _signalSnapshot = [snapshot copy];
    atomic_store(&_meter->signalRequest, 0);
    void (^completion)(NSDictionary *) = _signalCompletion;
    _signalCompletion = nil;
    completion(_signalSnapshot);
#endif
}

- (uint64_t)beginSignalDiagnosticsAtTime:(AVAudioTime *)startTime waitingForRetiredAudio:(BOOL)waiting
                            completion:(void (^)(NSDictionary<NSString *, id> *))completion {
#if VIBE_VERBOSE_LOGGING
    if (!_installed) return 0;
    [self finishSignalDiagnostics:@"superseded"];
    _signalSnapshot = nil;
    _signalCompletion = [completion copy];
    _signalWaitingForRetiredAudio = waiting;
    // Clear the request before replacing its clock pair; the render checks
    // the request again after reading it, so clocks cannot cross requests.
    atomic_store(&_meter->signalRequest, 0);
    double host = startTime.hostTimeValid ? [AVAudioTime secondsForHostTime:startTime.hostTime] : NAN;
    double sample = startTime.sampleTimeValid && startTime.sampleRate > 0 ? startTime.sampleTime / startTime.sampleRate : NAN;
    atomic_store(&_meter->signalHostOrigin, host);
    atomic_store(&_meter->signalSampleOrigin, sample);
    atomic_store(&_meter->signalHostCutoff, waiting ? INFINITY : host);
    atomic_store(&_meter->signalSampleCutoff, waiting ? INFINITY : sample);
    if (!waiting && _signalOverlapEndTime) {
        _signalWaitingForRetiredAudio = YES;
        [self endSignalOverlapAtTime:_signalOverlapEndTime];
    }
    uint64_t request = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_store(&_meter->signalRequest, request);
    return request;
#else
    return 0;
#endif
}

- (void)endSignalOverlapAtTime:(AVAudioTime *)time {
#if VIBE_VERBOSE_LOGGING
    // The fade can settle before the deferred start publishes its capture.
    _signalOverlapEndTime = time;
    if (!_signalCompletion || !_signalWaitingForRetiredAudio) return;
    _signalWaitingForRetiredAudio = NO;
    if (time.hostTimeValid) atomic_store(&_meter->signalHostCutoff,
            MAX(atomic_load(&_meter->signalHostOrigin), [AVAudioTime secondsForHostTime:time.hostTime]));
    if (time.sampleTimeValid && time.sampleRate > 0) atomic_store(&_meter->signalSampleCutoff,
            MAX(atomic_load(&_meter->signalSampleOrigin), time.sampleTime / time.sampleRate));
#endif
}

- (BOOL)pollSignalDiagnostics:(uint64_t)request {
#if VIBE_VERBOSE_LOGGING
    if (!_signalCompletion || request != atomic_load(&_meter->signalRequest)) return NO;
    NSDictionary *snapshot = [self signalDiagnosticSnapshot];
    if ([snapshot[@"aboveThreshold"] boolValue]) {
        [self finishSignalDiagnostics:@"first signal"];
    } else if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - request >= 3 * NSEC_PER_SEC
            || ([snapshot[@"sampleRate"] doubleValue] > 0
                && [snapshot[@"frames"] doubleValue] >= 3 * [snapshot[@"sampleRate"] doubleValue])) {
        [self finishSignalDiagnostics:@"window elapsed"];
    }
    return _signalCompletion != nil;
#else
    return NO;
#endif
}

- (NSDictionary<NSString *, id> *)signalDiagnosticSnapshot {
#if VIBE_VERBOSE_LOGGING
    if (!_signalCompletion && _signalSnapshot) return _signalSnapshot;
    VibeLevelMeter *meter = _meter;
    if (!_installed) return @{@"status": @"tap unavailable"};
    uint64_t request = atomic_load(&meter->signalRequest);
    if (!request) return @{@"status": @"not armed"};
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = atomic_load(&meter->signalVersion);
        if (before & 1) continue;
        uint64_t observed = atomic_load(&meter->signalResultRequest);
        uint64_t frames = atomic_load(&meter->signalFramesResult);
        uint64_t host = atomic_load(&meter->signalHostResult);
        uint64_t offset = atomic_load(&meter->signalOffsetResult);
        int64_t sample = atomic_load(&meter->signalSampleResult);
        uint64_t nonfinite = atomic_load(&meter->signalNonfiniteResult);
        uint64_t leadingFrames = atomic_load(&meter->signalLeadingFramesResult);
        double peak = atomic_load(&meter->signalPeakResult);
        double rms = atomic_load(&meter->signalRMSResult);
        double rate = atomic_load(&meter->signalRateResult);
        double observationStart = atomic_load(&meter->signalObservationStartResult);
        double firstAfterStart = atomic_load(&meter->signalFirstAfterStartResult);
        if (before != atomic_load(&meter->signalVersion)) continue;
        if (observed != request) {
            NSString *status = !isfinite(atomic_load(&meter->signalHostOrigin))
                    && !isfinite(atomic_load(&meter->signalSampleOrigin)) ? @"start clock unavailable" : @"no buffers observed";
            return @{@"status": status, @"request": @(request)};
        }
        _signalSnapshot = @{@"status": @"captured", @"request": @(request), @"frames": @(frames),
                 @"sampleRate": @(rate), @"peak": @(peak), @"finiteRMS": @(rms), @"nonfiniteSamples": @(nonfinite),
                 @"aboveThreshold": @(peak >= 0.001), @"thresholdDBFS": @(-60),
                 @"observedLeadingSilenceMS": @(rate > 0 ? leadingFrames / rate * 1000 : 0),
                 @"observationStartMS": @(observationStart * 1000),
                 @"firstSignalAfterStartMS": @(firstAfterStart < 0 ? -1 : firstAfterStart * 1000),
                 @"firstSignalSampleTime": @(sample), @"firstSignalBufferHostTime": @(host),
                 @"firstSignalFrameOffset": @(offset)};
        return _signalSnapshot;
    }
    if (_signalSnapshot) {
        NSMutableDictionary *snapshot = [_signalSnapshot mutableCopy];
        snapshot[@"snapshotBusy"] = @YES;
        return snapshot;
    }
    return @{@"status": @"snapshot busy", @"request": @(request)};
#else
    return @{@"status": @"beta instrumentation disabled"};
#endif
}

@end
