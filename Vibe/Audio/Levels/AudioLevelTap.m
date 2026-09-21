//
//  AudioLevelTap.m
//  Vibe
//

#import "AudioLevelTap.h"

#import "AudioLevelAnalyzer.h"
#import "AudioLevelPublisherInternal.h"

#include <stdatomic.h>

_Static_assert(__atomic_always_lock_free(sizeof(double), 0), "Signal snapshots require lock-free 64-bit atomics");

// The installed block owns this object, and the object owns every raw pointer
// it uses. That ownership is the reset guarantee: abandon may drop AudioPlayer's
// reference without freeing state underneath a late defunct-engine callback.
@interface AudioLevelTapSession : NSObject {
@public
    VibeAudioLevelAnalyzer *_analyzer;
    AudioLevelPublisher *_publisher;
    VibeLevelPublisherState *_publisherState;
    uint64_t _session;
    // The happens-before edge between this queue's setup writes — the analyzer
    // allocation, every session field, and the block copy installTapOnBus:
    // performs — and the tap thread's reads of the same memory. AVFAudio hands
    // the block to its tap thread through machinery that publishes no ordering
    // a checker can see (TSan reported the whole family as races), so the
    // callback acquire-loads this and stays out of the session until the
    // installer's release-store after installTapOnBus: returns. The armed=1
    // store is the LAST setup write, which is what makes the acquire cover all
    // of the earlier ones.
    _Atomic uint32_t _armed;
#if VIBE_VERBOSE_LOGGING
    _Atomic uint64_t _signalRequest, _signalVersion, _signalResultRequest;
    _Atomic uint64_t _signalFramesResult, _signalHostResult, _signalOffsetResult, _signalNonfiniteResult, _signalLeadingFramesResult;
    _Atomic int64_t _signalSampleResult;
    _Atomic double _signalPeakResult, _signalRMSResult, _signalRateResult;
    _Atomic double _signalHostOrigin, _signalSampleOrigin, _signalHostCutoff, _signalSampleCutoff;
    _Atomic double _signalObservationStartResult, _signalFirstAfterStartResult;
    uint64_t _signalObservedRequest, _signalFrames, _signalSamples, _signalNonfinite;
    uint64_t _signalFirstHost, _signalFirstOffset, _signalLeadingFrames;
    int64_t _signalFirstSample;
    double _signalPeak, _signalSum, _signalRate;
    double _signalObservationStart, _signalFirstAfterStart, _hostSecondsPerTick;
    BOOL _signalFound;
#endif
}
@end

@implementation AudioLevelTapSession
- (void)dealloc {
    VibeAudioLevelAnalyzerDestroy(_analyzer);
}
#if VIBE_VERBOSE_LOGGING
// Only the tap thread writes accumulators. Atomic result words plus the version
// let the queue read without allocating, locking or logging on this thread.
- (void)captureSignal:(AVAudioPCMBuffer *)buffer when:(AVAudioTime *)when {
    uint64_t request = atomic_load(&_signalRequest);
    if (!request || clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - request >= 3 * NSEC_PER_SEC
            || (_signalObservedRequest == request && _signalFound)) return;
    double rate = buffer.format.sampleRate;
    // A delivered buffer can still contain the previous track's audio.
    double origin = atomic_load(&_signalHostOrigin), cutoff = atomic_load(&_signalHostCutoff);
    double bufferTime = when.hostTimeValid ? when.hostTime * _hostSecondsPerTick : NAN;
    if (!isfinite(origin) || !isfinite(bufferTime)) {
        origin = atomic_load(&_signalSampleOrigin);
        cutoff = atomic_load(&_signalSampleCutoff);
        bufferTime = when.sampleTimeValid && when.sampleRate > 0 ? when.sampleTime / when.sampleRate : NAN;
    }
    if (request != atomic_load(&_signalRequest) || !isfinite(origin) || !isfinite(bufferTime)
            || !isfinite(cutoff) || bufferTime + buffer.frameLength / rate <= cutoff) return;
    AVAudioFrameCount skip = (AVAudioFrameCount)MIN(buffer.frameLength, MAX(0, ceil((cutoff - bufferTime) * rate - 1e-6)));
    if (_signalObservedRequest != request || _signalRate != rate) {
        _signalRate = rate;
        _signalObservedRequest = request;
        _signalFrames = _signalSamples = _signalNonfinite = 0;
        _signalPeak = _signalSum = 0;
        _signalFirstSample = -1;
        _signalFirstHost = _signalFirstOffset = 0;
        _signalFound = NO;
        _signalObservationStart = MAX(0, bufferTime + skip / rate - origin);
        _signalFirstAfterStart = -1;
    }
    uint64_t limit = (uint64_t)(rate * 3);
    if (_signalFrames >= limit) return;
    AVAudioFrameCount frames = (AVAudioFrameCount)MIN(buffer.frameLength - skip, limit - _signalFrames);
    AVAudioChannelCount channels = buffer.format.channelCount;
    float *const *samples = buffer.floatChannelData;
    for (AVAudioFrameCount f = skip; f < skip + frames; f++) {
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            double value = samples[c][f];
            if (!isfinite(value)) { _signalNonfinite++; continue; }
            _signalSamples++;
            _signalSum += value * value;
            _signalPeak = MAX(_signalPeak, fabs(value));
            if (!_signalFound && fabs(value) >= 0.001) {
                _signalFound = YES;
                _signalLeadingFrames = _signalFrames + f - skip;
                _signalFirstAfterStart = MAX(0, bufferTime + f / rate - origin);
                _signalFirstHost = when.hostTimeValid ? when.hostTime : 0;
                _signalFirstOffset = f;
                _signalFirstSample = when.sampleTimeValid ? when.sampleTime + f : -1;
            }
        }
    }
    _signalFrames += frames;
    atomic_fetch_add(&_signalVersion, 1);
    atomic_store(&_signalResultRequest, request);
    atomic_store(&_signalFramesResult, _signalFrames);
    atomic_store(&_signalHostResult, _signalFirstHost);
    atomic_store(&_signalOffsetResult, _signalFirstOffset);
    atomic_store(&_signalSampleResult, _signalFirstSample);
    atomic_store(&_signalNonfiniteResult, _signalNonfinite);
    atomic_store(&_signalLeadingFramesResult, _signalFound ? _signalLeadingFrames : _signalFrames);
    atomic_store(&_signalPeakResult, _signalPeak);
    atomic_store(&_signalRMSResult, _signalSamples ? sqrt(_signalSum / _signalSamples) : 0);
    atomic_store(&_signalRateResult, rate);
    atomic_store(&_signalObservationStartResult, _signalObservationStart);
    atomic_store(&_signalFirstAfterStartResult, _signalFirstAfterStart);
    atomic_fetch_add(&_signalVersion, 1);
}
#endif
@end

@implementation AudioLevelTap {
    AudioLevelTapSession *_tapSession;
    AVAudioNode *_node;
    BOOL _installed;
#if VIBE_VERBOSE_LOGGING
    void (^_signalCompletion)(NSDictionary<NSString *, id> *);
    NSDictionary<NSString *, id> *_signalSnapshot;
    BOOL _signalWaitingForRetiredAudio;
    AVAudioTime *_signalOverlapEndTime;
#endif
}

- (instancetype)initWithNode:(AVAudioNode *)node
                     publisher:(AudioLevelPublisher *)publisher
             normalizationMode:(VibeAudioLevelNormalizationMode)normalizationMode {
    self = [super init];
    if (!self) {
        return nil;
    }
    AVAudioFormat *format = [node outputFormatForBus:0];
    if (!publisher || format.sampleRate <= 0 || format.channelCount == 0) {
        LogWarn(@"AudioLevelTap: bus 0 has no usable format, no levels");
        return nil;
    }

    AudioLevelTapSession *tapSession = [[AudioLevelTapSession alloc] init];
    if (!tapSession) {
        LogError(@"AudioLevelTap: session allocation failed, no levels");
        return nil;
    }
    tapSession->_analyzer = VibeAudioLevelAnalyzerCreate(format.sampleRate,
                                                         normalizationMode);
    if (!tapSession->_analyzer) {
        LogError(@"AudioLevelTap: analyzer allocation failed, no levels");
        return nil;
    }
#if VIBE_VERBOSE_LOGGING
    atomic_init(&tapSession->_signalRequest, 0);
    atomic_init(&tapSession->_signalVersion, 0);
    atomic_init(&tapSession->_signalResultRequest, 0);
    atomic_init(&tapSession->_signalFramesResult, 0);
    atomic_init(&tapSession->_signalHostResult, 0);
    atomic_init(&tapSession->_signalOffsetResult, 0);
    atomic_init(&tapSession->_signalSampleResult, -1);
    atomic_init(&tapSession->_signalNonfiniteResult, 0);
    atomic_init(&tapSession->_signalLeadingFramesResult, 0);
    atomic_init(&tapSession->_signalPeakResult, 0);
    atomic_init(&tapSession->_signalRMSResult, 0);
    atomic_init(&tapSession->_signalRateResult, 0);
    atomic_init(&tapSession->_signalHostOrigin, NAN);
    atomic_init(&tapSession->_signalSampleOrigin, NAN);
    atomic_init(&tapSession->_signalHostCutoff, INFINITY);
    atomic_init(&tapSession->_signalSampleCutoff, INFINITY);
    atomic_init(&tapSession->_signalObservationStartResult, 0);
    atomic_init(&tapSession->_signalFirstAfterStartResult, -1);
    tapSession->_hostSecondsPerTick = [AVAudioTime secondsForHostTime:NSEC_PER_SEC] / NSEC_PER_SEC;
#endif
    tapSession->_publisher = publisher;
    tapSession->_publisherState = [publisher publisherState];
    tapSession->_session = [publisher beginSession];

    @try {
        [node installTapOnBus:0
                   bufferSize:(AVAudioFrameCount)VibeLevelTapBufferFrameCount(format.sampleRate)
                       format:nil
                        block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            // Before anything in the session: see _armed. A callback delivered
            // before the installer's release-store simply drops its buffer —
            // at ~24 decisions a second that is at most a few silent
            // milliseconds, against reading the analyzer mid-construction.
            if (atomic_load_explicit(&tapSession->_armed, memory_order_acquire) == 0) {
                return;
            }
#if DEBUG
            VibeLevelPublisherRecordCallback(tapSession->_publisherState,
                                              buffer.frameLength,
                                              buffer.format.sampleRate);
#endif
            // Mixer/output taps normally deliver non-interleaved float32. Fail
            // closed if a graph ever violates that shape, and rebind the pure
            // analyzer from the format actually delivered rather than the
            // pre-install query used for its initial configuration and the
            // requested callback size.
            if (buffer.format.interleaved || !buffer.floatChannelData
                    || !VibeAudioLevelAnalyzerSetSampleRate(
                            tapSession->_analyzer, buffer.format.sampleRate)) {
                return;
            }
#if VIBE_VERBOSE_LOGGING
            [tapSession captureSignal:buffer when:when];
#endif
            float callbackLevels[kLevelBandCount];
            NSUInteger windows = VibeAudioLevelAnalyzerConsume(
                    tapSession->_analyzer,
                    buffer.floatChannelData,
                    buffer.format.channelCount,
                    buffer.frameLength,
                    callbackLevels);
#if DEBUG
            VibeLevelPublisherRecordAnalyzedWindows(tapSession->_publisherState,
                                                     windows);
#endif
            if (windows > 0) {
                VibeLevelPublisherPublish(tapSession->_publisherState,
                                          tapSession->_session,
                                          callbackLevels);
            }
        }];
    }
    @catch (NSException *exception) {
        [publisher endSession:tapSession->_session];
        LogWarn(@"AudioLevelTap: install failed (%@)", exception.reason);
        return nil;
    }

    // Publishes every setup write above to the tap thread; see _armed.
    atomic_store_explicit(&tapSession->_armed, 1, memory_order_release);

    _tapSession = tapSession;
    _node = node;
    _installed = YES;
    LogDebug(@"AudioLevelTap: installed at %.0f Hz, %lu-frame FFT, %u-frame request",
             format.sampleRate,
             (unsigned long)VibeAudioLevelAnalyzerFFTSize(tapSession->_analyzer),
             VibeLevelTapBufferFrameCount(format.sampleRate));
    return self;
}

- (void)finishSignalDiagnostics:(NSString *)reason {
#if VIBE_VERBOSE_LOGGING
    if (!_signalCompletion) return;
    NSMutableDictionary *snapshot = [[self signalDiagnosticSnapshot] mutableCopy];
    snapshot[@"completion"] = reason;
    _signalSnapshot = [snapshot copy];
    atomic_store(&_tapSession->_signalRequest, 0);
    void (^completion)(NSDictionary *) = _signalCompletion;
    _signalCompletion = nil;
    completion(_signalSnapshot);
#endif
}

- (uint64_t)beginSignalDiagnosticsAtTime:(AVAudioTime *)startTime waitingForRetiredAudio:(BOOL)waiting
                            completion:(void (^)(NSDictionary<NSString *, id> *))completion {
#if VIBE_VERBOSE_LOGGING
    if (!_installed || !_tapSession) return 0;
    [self finishSignalDiagnostics:@"superseded"];
    _signalSnapshot = nil;
    _signalCompletion = [completion copy];
    _signalWaitingForRetiredAudio = waiting;
    // Clear the request before replacing its clock pair; the callback checks
    // the request again after reading it, so clocks cannot cross requests.
    atomic_store(&_tapSession->_signalRequest, 0);
    double host = startTime.hostTimeValid ? [AVAudioTime secondsForHostTime:startTime.hostTime] : NAN;
    double sample = startTime.sampleTimeValid && startTime.sampleRate > 0 ? startTime.sampleTime / startTime.sampleRate : NAN;
    atomic_store(&_tapSession->_signalHostOrigin, host);
    atomic_store(&_tapSession->_signalSampleOrigin, sample);
    atomic_store(&_tapSession->_signalHostCutoff, waiting ? INFINITY : host);
    atomic_store(&_tapSession->_signalSampleCutoff, waiting ? INFINITY : sample);
    if (!waiting && _signalOverlapEndTime) {
        _signalWaitingForRetiredAudio = YES;
        [self endSignalOverlapAtTime:_signalOverlapEndTime];
    }
    uint64_t request = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_store(&_tapSession->_signalRequest, request);
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
    if (time.hostTimeValid) atomic_store(&_tapSession->_signalHostCutoff,
            MAX(atomic_load(&_tapSession->_signalHostOrigin), [AVAudioTime secondsForHostTime:time.hostTime]));
    if (time.sampleTimeValid && time.sampleRate > 0) atomic_store(&_tapSession->_signalSampleCutoff,
            MAX(atomic_load(&_tapSession->_signalSampleOrigin), time.sampleTime / time.sampleRate));
#endif
}

- (BOOL)pollSignalDiagnostics:(uint64_t)request {
#if VIBE_VERBOSE_LOGGING
    if (!_signalCompletion || request != atomic_load(&_tapSession->_signalRequest)) return NO;
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
    AudioLevelTapSession *session = _tapSession;
    if (!_installed || !session) return @{@"status": @"tap unavailable"};
    uint64_t request = atomic_load(&session->_signalRequest);
    if (!request) return @{@"status": @"not armed"};
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t before = atomic_load(&session->_signalVersion);
        if (before & 1) continue;
        uint64_t observed = atomic_load(&session->_signalResultRequest);
        uint64_t frames = atomic_load(&session->_signalFramesResult);
        uint64_t host = atomic_load(&session->_signalHostResult);
        uint64_t offset = atomic_load(&session->_signalOffsetResult);
        int64_t sample = atomic_load(&session->_signalSampleResult);
        uint64_t nonfinite = atomic_load(&session->_signalNonfiniteResult);
        uint64_t leadingFrames = atomic_load(&session->_signalLeadingFramesResult);
        double peak = atomic_load(&session->_signalPeakResult);
        double rms = atomic_load(&session->_signalRMSResult);
        double rate = atomic_load(&session->_signalRateResult);
        double observationStart = atomic_load(&session->_signalObservationStartResult);
        double firstAfterStart = atomic_load(&session->_signalFirstAfterStartResult);
        if (before != atomic_load(&session->_signalVersion)) continue;
        if (observed != request) {
            NSString *status = !isfinite(atomic_load(&session->_signalHostOrigin))
                    && !isfinite(atomic_load(&session->_signalSampleOrigin)) ? @"start clock unavailable" : @"no buffers observed";
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

- (void)remove {
    if (!_installed) {
        return;
    }
    [self finishSignalDiagnostics:@"tap removed"];
    [_tapSession->_publisher endSession:_tapSession->_session];
    [_node removeTapOnBus:0];
    _installed = NO;
    _node = nil;
    _tapSession = nil;
}

- (void)abandon {
    [self finishSignalDiagnostics:@"tap abandoned"];
    if (_installed) {
        [_tapSession->_publisher endSession:_tapSession->_session];
    }
    _installed = NO;
    _node = nil;
    _tapSession = nil;
}

- (void)dealloc {
    [self remove];
}

@end
