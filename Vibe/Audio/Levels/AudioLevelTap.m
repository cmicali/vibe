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
    uint64_t session;
    // The accumulator: sized for a tap buffer at the highest supported rate,
    // filled to a tap buffer at the delivered rate, analyzed when full.
    float *accumulator[kMeterChannels];
    uint32_t capacity;
    uint32_t target;
    uint32_t fill;
    double sampleRate; // the rate the analyzer is bound to
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
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
#endif
static inline NSUInteger VibeLevelMeterAnalyze(VibeLevelMeter *meter, UInt32 channels, float levels[kLevelBandCount]) CA_REALTIME_API {
    return VibeAudioLevelAnalyzerConsume(meter->analyzer, meter->accumulator, channels, meter->fill, levels);
}

static inline BOOL VibeLevelMeterRebind(VibeLevelMeter *meter, double sampleRate) CA_REALTIME_API {
    return VibeAudioLevelAnalyzerSetSampleRate(meter->analyzer, sampleRate);
}

#if VIBE_VERBOSE_LOGGING
static inline uint64_t VibeLevelMeterNow(void) CA_REALTIME_API {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
#endif
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wfunction-effects"
#endif
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
                          double sampleRate, const AudioTimeStamp *timestamp) CA_REALTIME_API {
    if (!meter || channelCount == 0 || frames == 0 || sampleRate <= 0 || !channels[0]) {
        return;
    }
    // A delivered rate change rebinds the analyzer and restarts the buffer.
    if (sampleRate != meter->sampleRate) {
        if (!VibeLevelMeterRebind(meter, sampleRate)) {
            return;
        }
        meter->sampleRate = sampleRate;
        uint32_t target = VibeLevelTapBufferFrameCount(sampleRate);
        meter->target = target < meter->capacity ? target : meter->capacity;
        meter->fill = 0;
    }
#if VIBE_VERBOSE_LOGGING
    if (timestamp) {
        VibeLevelMeterCapture(meter, channels, channelCount, frames, sampleRate, timestamp);
    }
#endif
    UInt32 analyzed = channelCount < kMeterChannels ? channelCount : kMeterChannels;
    UInt32 consumed = 0;
    while (consumed < frames) {
        uint32_t room = meter->target - meter->fill;
        uint32_t take = frames - consumed < room ? frames - consumed : room;
        for (UInt32 c = 0; c < analyzed; c++) {
            memcpy(meter->accumulator[c] + meter->fill, channels[c] + consumed, take * sizeof(float));
        }
        meter->fill += take;
        consumed += take;
        if (meter->fill < meter->target) {
            continue;
        }
        VibeLevelPublisherRecordCallback(meter->publisherState, meter->fill, sampleRate);
        float levels[kLevelBandCount];
        NSUInteger windows = VibeLevelMeterAnalyze(meter, analyzed, levels);
        VibeLevelPublisherRecordAnalyzedWindows(meter->publisherState, windows);
        if (windows > 0) {
            VibeLevelPublisherPublish(meter->publisherState, meter->session, levels);
        }
        meter->fill = 0;
    }
}
#if defined(__has_warning) && __has_warning("-Wfunction-effects")
#pragma clang diagnostic pop
#endif

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
    // A tap buffer at the highest supported rate, so a rate rebind never
    // allocates; the target is the buffer at the delivered rate.
    meter->capacity = VibeLevelTapBufferFrameCount(192000);
    meter->accumulator[0] = calloc((size_t)meter->capacity * kMeterChannels, sizeof(float));
    if (!meter->accumulator[0]) {
        LogError(@"AudioLevelTap: accumulator allocation failed, no levels");
        return nil;
    }
    meter->accumulator[1] = meter->accumulator[0] + meter->capacity;
    meter->analyzer = VibeAudioLevelAnalyzerCreate(format.sampleRate, normalizationMode);
    if (!meter->analyzer) {
        LogError(@"AudioLevelTap: analyzer allocation failed, no levels");
        return nil;
    }
    meter->sampleRate = format.sampleRate;
    uint32_t target = VibeLevelTapBufferFrameCount(format.sampleRate);
    meter->target = target < meter->capacity ? target : meter->capacity;
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
    meter->session = [publisher beginSession];
    _installed = YES;
    LogDebug(@"AudioLevelTap: meter at %.0f Hz, %lu-frame FFT, %u-frame buffer",
             format.sampleRate, (unsigned long)VibeAudioLevelAnalyzerFFTSize(meter->analyzer), meter->target);
    return self;
}

- (void)dealloc {
    [self remove];
    if (_meter) {
        VibeAudioLevelAnalyzerDestroy(_meter->analyzer);
        free(_meter->accumulator[0]);
        free(_meter);
    }
}

- (VibeLevelMeter *)meter {
    return _meter;
}

- (void)remove {
    if (!_installed) {
        return;
    }
    [self finishSignalDiagnostics:@"tap removed"];
    [_publisher endSession:_meter->session];
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
