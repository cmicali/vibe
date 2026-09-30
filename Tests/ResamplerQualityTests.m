//
//  ResamplerQualityTests.m
//  VibeTests
//
//  The voice bus's resampler, r8brain-free-src, measured through the production
//  bus (inline decoding, the tests calling the render), at every rate pair the
//  player meets:
//
//  - stepped sines at −1 dBFS: passband gain and ripple to 20 kHz, the −0.1 dB
//    and −3 dB band edges, THD and THD+N, the stopband past the output's
//    Nyquist (downsampling), and phase delay (timing and linear phase);
//  - a −60 dBFS sine: the noise floor under a quiet signal;
//  - a continuous linear sine sweep to the source's Nyquist: every spur
//    (alias, image, distortion, noise) outside the sweep's own frequency,
//    frame by frame, with the tone in band and with it past the output's
//    Nyquist;
//  - a band-limited sawtooth to the source's Nyquist: everything that is not
//    one of its harmonics;
//  - twenty tones less their ideal, computed at the output rate, with no fit,
//    so gain, phase and timing errors all count; and the same there and back,
//    less the original (the round trip);
//  - CCIF (19 + 20 kHz) and SMPTE (60 Hz + 7 kHz) intermodulation;
//  - a unit impulse: magnitude and phase every 10 Hz to 20 kHz, against zero
//    delay;
//  - a sine whose true peak is +3 dBFS between samples at 0.999: carried
//    unclipped;
//  - silence and DC; the duration, exact; and the conversion's CPU cost.
//
//  A sine is analyzed by a least-squares fit at its exact frequency over a
//  rectangular window, so the residual is everything that is not the tone,
//  with no window leakage; a sweep or a sawtooth by a Kaiser (β 20) spectrum,
//  whose own floor on the ideal signals is checked once, below every bound.
//
//  Every run attaches the measured table to the result bundle ("resampler
//  quality", markdown); docs/audio-quality.md carries the comparison with
//  Apple's converter, which it replaced.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import "AudioVoiceBusInternal.h"
#import "AudioPlayer+Debug.h"
#import "AudioFixtures.h"

typedef struct {
    double from, to;
} RatePair;

static const RatePair kPairs[] = {
    {44100, 48000}, {48000, 44100}, {44100, 96000}, {96000, 44100},
    {88200, 44100}, {96000, 48000}, {192000, 48000}, {44100, 192000},
};

static NSString *PairName(RatePair pair) {
    return [NSString stringWithFormat:@"%g>%g", pair.from / 1000, pair.to / 1000];
}

static double DB(double ratio) {
    return ratio > 0 ? 10 * log10(ratio) : -400;
}

#pragma mark - Analysis

// The least-squares fit of c + Σ a_k·cos(ω_k t) + b_k·sin(ω_k t) over
// `count` samples, t = (index + n) / rate − origin: the tones at their exact
// frequencies, jointly, and the power of everything else. `a` and `b` receive
// each tone's cos and sin terms when given.
static double FitTones(const double *x, NSUInteger count, const double *frequencies, int tones, double rate, double index,
                       double origin, double *a, double *b) {
    int size = 2 * tones + 1;
    double *m = calloc((size_t)size * size, sizeof(double)), *v = calloc((size_t)size, sizeof(double));
    double *basis = malloc((size_t)size * sizeof(double)), *coefficients = calloc((size_t)size, sizeof(double));
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin;
        basis[0] = 1;
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            basis[1 + 2 * k] = cos(phase);
            basis[2 + 2 * k] = sin(phase);
        }
        for (int i = 0; i < size; i++) {
            v[i] += basis[i] * x[n];
            for (int j = i; j < size; j++) {
                m[i * size + j] += basis[i] * basis[j];
            }
        }
    }
    for (int i = 0; i < size; i++) {
        for (int j = 0; j < i; j++) {
            m[i * size + j] = m[j * size + i];
        }
    }
    // Gaussian elimination with partial pivoting on the normal equations.
    for (int col = 0; col < size; col++) {
        int pivot = col;
        for (int row = col + 1; row < size; row++) {
            if (fabs(m[row * size + col]) > fabs(m[pivot * size + col])) pivot = row;
        }
        if (pivot != col) {
            for (int k = 0; k < size; k++) {
                double swap = m[col * size + k]; m[col * size + k] = m[pivot * size + k]; m[pivot * size + k] = swap;
            }
            double swap = v[col]; v[col] = v[pivot]; v[pivot] = swap;
        }
        for (int row = col + 1; row < size; row++) {
            double factor = m[row * size + col] / m[col * size + col];
            for (int k = col; k < size; k++) {
                m[row * size + k] -= factor * m[col * size + k];
            }
            v[row] -= factor * v[col];
        }
    }
    for (int row = size - 1; row >= 0; row--) {
        double sum = v[row];
        for (int k = row + 1; k < size; k++) {
            sum -= m[row * size + k] * coefficients[k];
        }
        coefficients[row] = sum / m[row * size + row];
    }
    double residual = 0;
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin, e = x[n] - coefficients[0];
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            e -= coefficients[1 + 2 * k] * cos(phase) + coefficients[2 + 2 * k] * sin(phase);
        }
        residual += e * e;
    }
    for (int k = 0; k < tones; k++) {
        if (a) a[k] = coefficients[1 + 2 * k];
        if (b) b[k] = coefficients[2 + 2 * k];
    }
    free(m);
    free(v);
    free(basis);
    free(coefficients);
    return residual / count;
}

typedef struct {
    double amplitude;   // hypot(a, b)
    double a, b;        // cos and sin terms
    double residualPower;
} ToneFit;

static ToneFit FitTone(const double *x, NSUInteger count, double frequency, double rate, double index, double origin) {
    ToneFit fit;
    fit.residualPower = FitTones(x, count, &frequency, 1, rate, index, origin, &fit.a, &fit.b);
    fit.amplitude = hypot(fit.a, fit.b);
    return fit;
}

static double BesselI0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 200; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
        if (term < sum * 1e-20) {
            break;
        }
    }
    return sum;
}

// A power spectrum of `count` (a power of two) samples under a Kaiser window
// of β 20: bins 0…count/2, in consistent units, so a caller compares powers
// within it or against the same analysis of a reference.
@interface KaiserSpectrum : NSObject
- (instancetype)initWithLength:(NSUInteger)count;
- (void)powerOf:(const double *)samples into:(double *)power;
@end

@implementation KaiserSpectrum {
    NSUInteger _count;
    vDSP_Length _log2;
    FFTSetupD _setup;
    double *_window, *_windowed, *_real, *_imaginary;
}

- (instancetype)initWithLength:(NSUInteger)count {
    self = [super init];
    _count = count;
    _log2 = (vDSP_Length)llround(log2((double)count));
    _setup = vDSP_create_fftsetupD(_log2, kFFTRadix2);
    _window = malloc(count * sizeof(double));
    _windowed = malloc(count * sizeof(double));
    _real = malloc(count / 2 * sizeof(double));
    _imaginary = malloc(count / 2 * sizeof(double));
    double beta = 20, denominator = BesselI0(beta);
    for (NSUInteger n = 0; n < count; n++) {
        double r = 2.0 * n / (count - 1) - 1;
        _window[n] = BesselI0(beta * sqrt(fmax(0, 1 - r * r))) / denominator;
    }
    return self;
}

- (void)dealloc {
    vDSP_destroy_fftsetupD(_setup);
    free(_window);
    free(_windowed);
    free(_real);
    free(_imaginary);
}

- (void)powerOf:(const double *)samples into:(double *)power {
    vDSP_vmulD(samples, 1, _window, 1, _windowed, 1, _count);
    DSPDoubleSplitComplex split = { _real, _imaginary };
    vDSP_ctozD((const DSPDoubleComplex *)_windowed, 2, &split, 1, _count / 2);
    vDSP_fft_zripD(_setup, &split, 1, _log2, kFFTDirection_Forward);
    power[0] = _real[0] * _real[0];
    power[_count / 2] = _imaginary[0] * _imaginary[0];
    for (NSUInteger k = 1; k < _count / 2; k++) {
        power[k] = 2 * (_real[k] * _real[k] + _imaginary[k] * _imaginary[k]);
    }
}

@end

// The power outside the given frequency zones, the zones' own power, and a
// DC zone always excluded.
static void SplitPower(const double *power, NSUInteger count, double rate, const double *zones, NSUInteger zoneCount,
                       double guardHz, double *outside, double *inside) {
    double binHz = rate / count;
    *outside = 0;
    *inside = 0;
    for (NSUInteger k = 0; k <= count / 2; k++) {
        double f = k * binHz;
        BOOL excluded = f <= guardHz;
        BOOL zoned = NO;
        for (NSUInteger z = 0; z < zoneCount && !excluded; z++) {
            if (f >= zones[2 * z] - guardHz && f <= zones[2 * z + 1] + guardHz) {
                zoned = YES;
            }
        }
        if (zoned) {
            *inside += power[k];
        }
        else if (!excluded) {
            *outside += power[k];
        }
    }
}

#pragma mark - Measurements

typedef struct {
    double rippleDB;          // max |gain| in dB, 20 Hz–20 kHz
    double edge01Hz;          // highest frequency still within −0.1 dB, from 20 kHz up
    double edge3Hz;           // interpolated −3 dB point; 0 when the band ends above it
    double worstTHDNdB;       // worst THD+N of the −1 dBFS tones, 20 Hz–20 kHz, re the tone
    double thd1kDB;           // harmonics 2–10 of 1 kHz, re the tone
    double thd6kDB;
    double noiseFloorDBFS;    // what is not the −60 dBFS 1 kHz tone, re a full-scale sine
    double stopbandDB;        // worst output past 1.02 × the output Nyquist, re the input tone; NAN when upsampling
    double stopbandEdgeDB;    // the same from the Nyquist to 1.02 ×
    double delaySamples;      // phase delay at 1 kHz, output samples
    double phaseSpreadSamples;// max − min phase delay, 100 Hz–18 kHz
    double sweepInBandDB;     // worst sweep spur, the sweep in band, re the sweep
    double sweepStopbandDB;   // worst output with the sweep past 1.02 × the output Nyquist; NAN when upsampling
    double sawSpurDB;         // everything but the saw's harmonics, re the fundamental
    double multitoneNullDB;   // twenty tones less their ideal (no fit: gain, phase and timing errors count), re the signal
    double roundTripDB;       // the multitone there and back, less the original, re the signal
    double imdCCIFdB;         // 19 + 20 kHz twin tone: products at 1, 18 and 21 kHz, re the tones
    double imdSMPTEdB;        // 60 Hz + 7 kHz at 4:1: 7 kHz ± 60 and ± 120 Hz, re the 7 kHz tone
    double impulseRippleDB;   // the impulse response's magnitude, every 10 Hz, 20 Hz–20 kHz: max |dB|
    double impulsePhaseDeg;   // its phase against zero delay over the same band: max |degrees|
    double oversGainDB;       // a sine whose true peak is +3 dBFS between samples at 0.999: fitted gain
    double oversTHDNdB;       // and what is not that sine, re it; clipping shows in both
    double silencePeak;
    double dcError;
    double corePercent;       // the bus's resampling CPU to keep up in real time
} Quality;

@interface ResamplerQualityTests : XCTestCase
@end

@implementation ResamplerQualityTests {
    NSURL *_temporary;
    dispatch_queue_t _queue;
    AudioVoiceBus *_bus;
    AudioBufferList *_output;
    float *_outputData[2];
    // Each rate's ideal multitone, synthesized once across the pairs.
    NSMutableDictionary<NSNumber *, NSData *> *_multitones;
    // Every conversion's resampling cost since the pair began.
    double _cpuSeconds;
    double _audioSeconds;
}

- (void)setUp {
    [super setUp];
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    _queue = dispatch_queue_create("resampler-quality", DISPATCH_QUEUE_SERIAL);
    _multitones = [NSMutableDictionary dictionary];
    _output = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    _output->mNumberBuffers = 2;
    for (UInt32 c = 0; c < 2; c++) {
        _outputData[c] = calloc(4096, sizeof(float));
        _output->mBuffers[c].mNumberChannels = 1;
        _output->mBuffers[c].mData = _outputData[c];
    }
}

- (void)tearDown {
    for (UInt32 c = 0; c < 2; c++) {
        free(_outputData[c]);
    }
    free(_output);
    _bus = nil;
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}

// A mono float32 WAV of `samples` at `rate`.
- (NSURL *)writeMono:(const double *)samples count:(NSUInteger)count rate:(double)rate name:(NSString *)name {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)count];
    buffer.frameLength = (AVAudioFrameCount)count;
    vDSP_vdpsp(samples, 1, buffer.floatChannelData[0], 1, count);
    NSURL *url = [_temporary URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}

// The source named `name` at the pair's source rate, `count` samples `build` fills.
- (NSURL *)source:(NSString *)name pair:(RatePair)pair count:(NSUInteger)count build:(void (^)(double *samples))build {
    NSString *key = [NSString stringWithFormat:@"%@-%g-%g", name, pair.from, pair.to];
    double *samples = calloc(count, sizeof(double));
    build(samples);
    NSURL *url = [self writeMono:samples count:count rate:pair.from name:[key stringByAppendingPathExtension:@"wav"]];
    free(samples);
    return url;
}

// The whole file through a fresh bus at `rate`: the left
// channel, widened, to the stream's end, which must be round(N × ratio)
// exactly. The right channel must equal it (the mono file is duplicated
// before resampling). The bus's resampling cost joins the pair's tally.
- (NSData *)convert:(NSURL *)url toRate:(double)rate {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    _bus = [[AudioVoiceBus alloc] initWithFormat:format queue:_queue inlineDecoding:YES];
    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(file, @"%@", error);
    AVAudioFramePosition sourceFrames = file.length;
    double sourceRate = file.processingFormat.sampleRate;
    VibeVoiceID voice = [_bus startVoiceWithFile:file atFrame:0 endFrame:0 gain:1
                                            ramp:VibeVoiceRampMake(1, 0, VibeFadeCurveLinear, VibeVoiceActionNone) paused:NO];
    __block BOOL ended = NO;
    __block uint64_t endOfStream = 0;
    double sampleTime = 0;
    NSMutableData *left = [NSMutableData data];
    NSUInteger limit = (NSUInteger)(sourceFrames * rate / sourceRate) + 2 * (NSUInteger)rate;
    BOOL mismatch = NO;
    while (!ended && left.length / sizeof(double) < limit) {
        [_bus fillInline];
        const uint32_t frames = 4096;
        for (UInt32 c = 0; c < 2; c++) {
            _output->mBuffers[c].mDataByteSize = frames * sizeof(float);
        }
        AudioTimeStamp stamp = {0};
        stamp.mSampleTime = sampleTime;
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        BOOL silence = NO;
        XCTAssertEqual(VibeVoiceBusRender(_bus.mix, &silence, &stamp, frames, _output), noErr);
        sampleTime += frames;
        NSUInteger start = left.length / sizeof(double);
        [left increaseLengthBy:frames * sizeof(double)];
        vDSP_vspdp(_outputData[0], 1, (double *)left.mutableBytes + start, 1, frames);
        mismatch = mismatch || memcmp(_outputData[0], _outputData[1], frames * sizeof(float)) != 0;
        [_bus drainWithOutputRunning:YES handler:^(VibeVoiceID identifier, VibeVoiceEvent event) {
            if (identifier == voice && event == VibeVoiceEventEnded) {
                ended = YES;
                endOfStream = [self->_bus snapshotOfVoice:voice].endOfStream;
            }
        }];
    }
    XCTAssertTrue(ended, @"%@ never ended", url.lastPathComponent);
    XCTAssertFalse(mismatch, @"the channels differ");
    XCTAssertEqual((int64_t)endOfStream, llround((double)sourceFrames * rate / sourceRate),
                   @"%@ duration", url.lastPathComponent);
    NSDictionary *cost = [_bus debugResamplerCostsResetting:NO];
    _cpuSeconds += [cost[@"cpuSeconds"] doubleValue];
    _audioSeconds += [cost[@"audioSeconds"] doubleValue];
    left.length = MIN(left.length, (NSUInteger)endOfStream * sizeof(double));
    return left;
}

#pragma mark - Signals

typedef struct {
    double frequency;
    double amplitude;
} Tone;

static const NSUInteger kSegmentOutputFrames = 32768;
static const NSUInteger kAnalysisFrames = 8192;

// Tones for a pair: the passband, the band edge as fractions of the lower
// Nyquist, the stopband as multiples of the output's (downsampling), and a
// quiet tone for the noise floor.
static NSArray<NSValue *> *TonesForPair(RatePair pair) {
    NSMutableArray<NSValue *> *tones = [NSMutableArray array];
    void (^add)(double, double) = ^(double frequency, double amplitude) {
        Tone tone = { frequency, amplitude };
        [tones addObject:[NSValue valueWithBytes:&tone objCType:@encode(Tone)]];
    };
    double full = pow(10, -1 / 20.0);
    for (NSNumber *f in @[@20, @100, @1000, @3000, @6000, @10000, @15000, @18000, @19000, @20000]) {
        add(f.doubleValue, full);
    }
    double lowerNyquist = MIN(pair.from, pair.to) / 2;
    for (NSNumber *fraction in @[@0.92, @0.94, @0.95, @0.96, @0.97, @0.975, @0.98, @0.985, @0.99, @0.995, @0.999]) {
        if (fraction.doubleValue * lowerNyquist > 20000) {
            add(fraction.doubleValue * lowerNyquist, full);
        }
    }
    if (pair.from > pair.to) {
        for (NSNumber *multiple in @[@1.0005, @1.005, @1.01, @1.02, @1.05, @1.1, @1.3, @1.6, @1.9]) {
            double f = multiple.doubleValue * pair.to / 2;
            if (f < 0.99 * pair.from / 2) {
                add(f, full);
            }
        }
    }
    add(1000, pow(10, -60 / 20.0));
    return tones;
}

- (void)measureTonesForPair:(RatePair)pair into:(Quality *)q {
    NSArray<NSValue *> *tones = TonesForPair(pair);
    double ratio = pair.to / pair.from;
    NSUInteger segmentIn = (NSUInteger)ceil(kSegmentOutputFrames / ratio);
    NSURL *url = [self source:@"tones" pair:pair count:segmentIn * tones.count build:^(double *source) {
        for (NSUInteger s = 0; s < tones.count; s++) {
            Tone tone;
            [tones[s] getValue:&tone];
            for (NSUInteger m = 0; m < segmentIn; m++) {
                source[s * segmentIn + m] = tone.amplitude * sin(2 * M_PI * tone.frequency * m / pair.from);
            }
        }
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const double *y = output.bytes;
    NSUInteger available = output.length / sizeof(double);

    q->rippleDB = 0;
    q->worstTHDNdB = -400;
    q->stopbandDB = pair.from > pair.to ? -400 : NAN;
    q->stopbandEdgeDB = pair.from > pair.to ? -400 : NAN;
    q->edge01Hz = 0;
    q->edge3Hz = 0;
    double minDelay = INFINITY, maxDelay = -INFINITY;
    double previousF = 0, previousGainDB = 0;
    BOOL edge01Open = YES;
    double outNyquist = pair.to / 2, lowerNyquist = MIN(pair.from, pair.to) / 2;
    for (NSUInteger s = 0; s < tones.count; s++) {
        Tone tone;
        [tones[s] getValue:&tone];
        double origin = (double)(s * segmentIn) / pair.from; // the segment's first source frame, in seconds
        double center = origin * pair.to + (segmentIn * ratio) / 2;
        NSUInteger first = (NSUInteger)llround(center - kAnalysisFrames / 2.0);
        XCTAssertLessThanOrEqual(first + kAnalysisFrames, available);
        const double *window = y + first;
        double inputPower = tone.amplitude * tone.amplitude / 2;
        if (tone.frequency >= outNyquist) {
            double power = 0;
            for (NSUInteger n = 0; n < kAnalysisFrames; n++) {
                power += window[n] * window[n];
            }
            double level = DB(power / kAnalysisFrames / inputPower);
            if (tone.frequency >= 1.02 * outNyquist) {
                q->stopbandDB = MAX(q->stopbandDB, level);
            }
            else {
                q->stopbandEdgeDB = MAX(q->stopbandEdgeDB, level);
            }
            continue;
        }
        ToneFit fit = FitTone(window, kAnalysisFrames, tone.frequency, pair.to, first, origin);
        double gainDB = 20 * log10(fit.amplitude / tone.amplitude);
        if (tone.amplitude < 0.5) {
            q->noiseFloorDBFS = DB(fit.residualPower / 0.5);
            continue;
        }
        if (tone.frequency <= 20000) {
            q->rippleDB = MAX(q->rippleDB, fabs(gainDB));
            q->worstTHDNdB = MAX(q->worstTHDNdB, DB(fit.residualPower / (fit.amplitude * fit.amplitude / 2)));
            double delay = atan2(-fit.a, fit.b) / (2 * M_PI * tone.frequency) * pair.to;
            if (tone.frequency >= 100 && tone.frequency <= 18000) {
                minDelay = MIN(minDelay, delay);
                maxDelay = MAX(maxDelay, delay);
            }
            if (tone.frequency == 1000) {
                q->delaySamples = delay;
            }
            if (tone.frequency == 1000 || tone.frequency == 6000) {
                // Harmonics 2–10 below both Nyquists, fitted in what the
                // fundamental's fit left.
                double *residual = malloc(kAnalysisFrames * sizeof(double));
                for (NSUInteger n = 0; n < kAnalysisFrames; n++) {
                    double t = (first + n) / pair.to - origin, phase = 2 * M_PI * tone.frequency * t;
                    residual[n] = window[n] - fit.a * cos(phase) - fit.b * sin(phase);
                }
                double harmonics = 0;
                for (int h = 2; h <= 10 && h * tone.frequency < 0.98 * lowerNyquist; h++) {
                    ToneFit harmonic = FitTone(residual, kAnalysisFrames, h * tone.frequency, pair.to, first, origin);
                    harmonics += harmonic.amplitude * harmonic.amplitude / 2;
                }
                free(residual);
                double thd = DB(harmonics / (fit.amplitude * fit.amplitude / 2));
                if (tone.frequency == 1000) {
                    q->thd1kDB = thd;
                }
                else {
                    q->thd6kDB = thd;
                }
            }
        }
        if (tone.frequency >= 20000) {
            if (edge01Open && gainDB >= -0.1) {
                q->edge01Hz = tone.frequency;
            }
            else {
                edge01Open = NO;
            }
            if (q->edge3Hz == 0 && gainDB < -3 && previousF > 0) {
                q->edge3Hz = previousF + (tone.frequency - previousF) * (previousGainDB + 3) / (previousGainDB - gainDB);
            }
        }
        previousF = tone.frequency;
        previousGainDB = gainDB;
    }
    q->phaseSpreadSamples = maxDelay - minDelay;
}

// A linear sweep from 20 Hz to 0.999 × the source's Nyquist at −6 dBFS,
// analyzed in Kaiser frames of 8192 output samples, hop 4096: in each, every
// spur outside the band the sweep crossed during the frame.
static const double kSweepSeconds = 12, kSweepAmplitude = 0.5, kSweepStart = 20;
static const NSUInteger kSweepFrame = 8192, kSweepHop = 4096;

static double SweepRate(RatePair pair) {
    return (0.999 * pair.from / 2 - kSweepStart) / kSweepSeconds;
}

static double SweepAt(double t, RatePair pair) {
    return kSweepAmplitude * sin(2 * M_PI * (kSweepStart * t + SweepRate(pair) * t * t / 2));
}

// The power a steady sine of the sweep's amplitude has in `spectrum`.
static double SweepReference(KaiserSpectrum *spectrum, double rate, double *scratch, double *power) {
    for (NSUInteger n = 0; n < kSweepFrame; n++) {
        scratch[n] = kSweepAmplitude * sin(2 * M_PI * 1000.5 * n / rate);
    }
    [spectrum powerOf:scratch into:power];
    double reference = 0;
    for (NSUInteger b = 0; b <= kSweepFrame / 2; b++) {
        reference += power[b];
    }
    return reference;
}

- (void)measureSweepForPair:(RatePair)pair into:(Quality *)q {
    const double f0 = kSweepStart, k = SweepRate(pair);
    NSUInteger count = (NSUInteger)(kSweepSeconds * pair.from);
    NSURL *url = [self source:@"sweep" pair:pair count:count build:^(double *source) {
        for (NSUInteger m = 0; m < count; m++) {
            source[m] = SweepAt(m / pair.from, pair);
        }
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const double *y = output.bytes;
    NSUInteger available = output.length / sizeof(double);

    const NSUInteger frame = kSweepFrame, hop = kSweepHop;
    KaiserSpectrum *spectrum = [[KaiserSpectrum alloc] initWithLength:frame];
    double *power = malloc((frame / 2 + 1) * sizeof(double));
    double *scratch = malloc(frame * sizeof(double));
    double outNyquist = pair.to / 2, guardHz = 12 * pair.to / frame;
    q->sweepInBandDB = -400;
    q->sweepStopbandDB = pair.from > pair.to ? -400 : NAN;
    double reference = SweepReference(spectrum, pair.to, scratch, power);
    for (NSUInteger start = hop; start + frame + hop <= available; start += hop) {
        double t0 = (double)start / pair.to, t1 = (double)(start + frame) / pair.to;
        double fa = f0 + k * t0, fb = f0 + k * t1;
        double zone[2] = { fa, fb };
        double outside, inside;
        [spectrum powerOf:y + start into:power];
        SplitPower(power, frame, pair.to, zone, 1, guardHz, &outside, &inside);
        double level = DB(outside / reference);
        if (fb <= 20000) {
            q->sweepInBandDB = MAX(q->sweepInBandDB, level);
        }
        else if (pair.from > pair.to && fa >= 1.02 * outNyquist) {
            SplitPower(power, frame, pair.to, NULL, 0, guardHz, &outside, &inside);
            q->sweepStopbandDB = MAX(q->sweepStopbandDB, DB(outside / reference));
        }
    }
    free(power);
    free(scratch);
}

// A band-limited sawtooth, fundamental 1003.7 Hz, every harmonic below the
// source's Nyquist: in one Kaiser spectrum of 65536 output samples, the power
// that is not at a harmonic, re the fundamental. Harmonics past the output's
// Nyquist must be removed, not folded; images of those below the source's
// must not appear.
static const double kSawFundamental = 1003.7, kSawSeconds = 2.5;
static const NSUInteger kSawFrame = 65536;

// Adds the saw's harmonics 1…`last` at `rate` to `samples`, from sample
// `index`: each by a rotation per sample, not a sine.
static void AddSaw(double *samples, NSUInteger count, NSUInteger index, int last, double rate) {
    for (int h = 1; h <= last; h++) {
        double gain = 0.5 * 2 / M_PI / h * (h % 2 ? 1 : -1), step = 2 * M_PI * h * kSawFundamental / rate;
        double c = cos(step * index), s = sin(step * index), dc = cos(step), ds = sin(step);
        for (NSUInteger m = 0; m < count; m++) {
            samples[m] += gain * s;
            double next = c * dc - s * ds;
            s = s * dc + c * ds;
            c = next;
        }
    }
}

// The saw's non-harmonic power re its fundamental, in one Kaiser spectrum.
static double SawSpur(const double *samples, double rate) {
    KaiserSpectrum *spectrum = [[KaiserSpectrum alloc] initWithLength:kSawFrame];
    double *power = malloc((kSawFrame / 2 + 1) * sizeof(double));
    int kept = (int)floor(rate / 2 / kSawFundamental);
    double *zones = malloc(2 * (size_t)MAX(kept, 1) * sizeof(double));
    for (int h = 1; h <= kept; h++) {
        zones[2 * (h - 1)] = zones[2 * (h - 1) + 1] = h * kSawFundamental;
    }
    double guardHz = 12 * rate / kSawFrame, fundamental[2] = { kSawFundamental, kSawFundamental };
    double outside, inside, fundamentalPower, ignored;
    [spectrum powerOf:samples into:power];
    SplitPower(power, kSawFrame, rate, zones, (NSUInteger)kept, guardHz, &outside, &inside);
    SplitPower(power, kSawFrame, rate, fundamental, 1, guardHz, &ignored, &fundamentalPower);
    free(zones);
    free(power);
    return DB(outside / fundamentalPower);
}

- (void)measureSawForPair:(RatePair)pair into:(Quality *)q {
    NSUInteger count = (NSUInteger)(kSawSeconds * pair.from);
    NSURL *url = [self source:@"saw" pair:pair count:count build:^(double *source) {
        AddSaw(source, count, 0, (int)floor(0.999 * pair.from / 2 / kSawFundamental), pair.from);
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const NSUInteger frame = kSawFrame;
    NSUInteger available = output.length / sizeof(double);
    XCTAssertGreaterThanOrEqual(available, frame + 8192);
    q->sawSpurDB = SawSpur((const double *)output.bytes + (available - frame) / 2, pair.to);
}

// A second of silence, two of DC at 0.5, a second of silence: the first half
// second must be exact zeros, the plateau's middle second 0.5.
- (void)measureSilenceAndDCForPair:(RatePair)pair into:(Quality *)q {
    NSURL *url = [self source:@"dc" pair:pair count:(NSUInteger)(4 * pair.from) build:^(double *source) {
        for (NSUInteger m = (NSUInteger)pair.from; m < (NSUInteger)(3 * pair.from); m++) {
            source[m] = 0.5;
        }
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const double *y = output.bytes;
    q->silencePeak = 0;
    for (NSUInteger n = 0; n < (NSUInteger)(pair.to / 2); n++) {
        q->silencePeak = MAX(q->silencePeak, fabs(y[n]));
    }
    q->dcError = 0;
    for (NSUInteger n = (NSUInteger)(1.5 * pair.to); n < (NSUInteger)(2.5 * pair.to); n++) {
        q->dcError = MAX(q->dcError, fabs(y[n] - 0.5));
    }
}

// Twenty tones, 50 Hz to 19 kHz log-spaced, 0.04 each with seeded phases:
// the output less the ideal signal computed at the output rate (Hilmar's
// "calculate the ideal answer and subtract it"), no fit, so any gain, phase
// or timing error counts; then the output converted back to the source rate,
// less the original (the round trip).
static void MultitoneTones(double *frequencies, double *phases) {
    uint32_t state = 4242;
    for (int k = 0; k < 20; k++) {
        frequencies[k] = 50 * pow(19000.0 / 50, k / 19.0) * (1 + 0.0013 * k);
        state = state * 1664525u + 1013904223u;
        phases[k] = 2 * M_PI * (state >> 8) / 16777216.0;
    }
}

// Two seconds of the multitone at `rate`, synthesized once.
- (NSData *)multitoneAtRate:(double)rate {
    if (!_multitones[@(rate)]) {
        double frequencies[20], phases[20];
        MultitoneTones(frequencies, phases);
        NSUInteger count = (NSUInteger)(2 * rate);
        NSMutableData *samples = [NSMutableData dataWithLength:count * sizeof(double)];
        double *y = samples.mutableBytes;
        for (NSUInteger n = 0; n < count; n++) {
            for (int k = 0; k < 20; k++) {
                y[n] += 0.04 * sin(2 * M_PI * frequencies[k] * n / rate + phases[k]);
            }
        }
        _multitones[@(rate)] = samples;
    }
    return _multitones[@(rate)];
}

// The output less the ideal over its middle half, re the ideal.
static double Null(NSData *output, NSData *ideal) {
    const double *y = output.bytes, *x = ideal.bytes;
    NSUInteger count = MIN(output.length, ideal.length) / sizeof(double);
    double error = 0, signal = 0;
    for (NSUInteger n = count / 4; n < count * 3 / 4; n++) {
        error += (y[n] - x[n]) * (y[n] - x[n]);
        signal += x[n] * x[n];
    }
    return DB(error / signal);
}

- (void)measureMultitoneForPair:(RatePair)pair into:(Quality *)q {
    NSData *original = [self multitoneAtRate:pair.from];
    NSURL *url = [self source:@"multitone" pair:pair count:original.length / sizeof(double) build:^(double *source) {
        memcpy(source, original.bytes, original.length);
    }];
    NSData *there = [self convert:url toRate:pair.to];
    q->multitoneNullDB = Null(there, [self multitoneAtRate:pair.to]);
    NSString *name = [NSString stringWithFormat:@"there-%g-%g.wav", pair.from, pair.to];
    NSURL *middle = [self writeMono:there.bytes count:there.length / sizeof(double) rate:pair.to name:name];
    q->roundTripDB = Null([self convert:middle toRate:pair.from], original);
}

// CCIF: 19 and 20 kHz at 0.25 each; SMPTE: 60 Hz at 0.4 and 7 kHz at 0.1. Each
// is fitted jointly with its products, whose power is the measure. A linear
// resampler makes none, so what shows is numerical error and folding.
- (void)measureIntermodulationForPair:(RatePair)pair into:(Quality *)q {
    NSUInteger half = (NSUInteger)(1.5 * pair.from);
    NSURL *url = [self source:@"imd" pair:pair count:2 * half build:^(double *source) {
        for (NSUInteger m = 0; m < half; m++) {
            double t = m / pair.from;
            source[m] = 0.25 * sin(2 * M_PI * 19000 * t) + 0.25 * sin(2 * M_PI * 20000 * t);
            source[half + m] = 0.4 * sin(2 * M_PI * 60 * t) + 0.1 * sin(2 * M_PI * 7000 * t);
        }
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const double *y = output.bytes;
    const NSUInteger window = 32768;
    double segmentOut = half * pair.to / pair.from;
    double a[8], b[8];
    double ccif[5] = { 19000, 20000, 1000, 18000, 21000 };
    NSUInteger first = (NSUInteger)(segmentOut / 2 - window / 2);
    FitTones(y + first, window, ccif, 5, pair.to, first, 0, a, b);
    double tones = 0, products = 0;
    for (int k = 0; k < 5; k++) {
        double power = (a[k] * a[k] + b[k] * b[k]) / 2;
        if (k < 2) tones += power; else products += power;
    }
    q->imdCCIFdB = DB(products / tones);
    double smpte[6] = { 60, 7000, 6940, 7060, 6880, 7120 };
    double origin = half / pair.from;
    first = (NSUInteger)(segmentOut + segmentOut / 2 - window / 2);
    FitTones(y + first, window, smpte, 6, pair.to, first, origin, a, b);
    products = 0;
    for (int k = 2; k < 6; k++) {
        products += (a[k] * a[k] + b[k] * b[k]) / 2;
    }
    q->imdSMPTEdB = DB(products / ((a[1] * a[1] + b[1] * b[1]) / 2));
}

// A unit impulse at the middle of a second: the output's transform about the
// impulse's own instant, over the output's rate relative to the source's
// (what a band-limited impulse's samples sum to), is the frequency response,
// magnitude and phase, with zero delay as the reference — so a linear-phase
// filter whose latency was removed exactly reads 0 dB and 0°. Read at every
// bin of one FFT of the window, 20 Hz–20 kHz (bins 3–12 Hz apart).
- (void)measureImpulseForPair:(RatePair)pair into:(Quality *)q {
    NSUInteger count = (NSUInteger)pair.from, at = count / 2;
    NSURL *url = [self source:@"impulse" pair:pair count:count build:^(double *source) {
        source[at] = 1;
    }];
    NSData *output = [self convert:url toRate:pair.to];
    const double *y = output.bytes;
    double t0 = at / pair.from, scale = pair.to / pair.from;
    const vDSP_Length log2n = 14;
    const NSUInteger window = 1 << log2n;
    NSUInteger first = (NSUInteger)llround(t0 * pair.to) - window / 2;
    double *real = malloc(window / 2 * sizeof(double)), *imaginary = malloc(window / 2 * sizeof(double));
    DSPDoubleSplitComplex split = { real, imaginary };
    vDSP_ctozD((const DSPDoubleComplex *)(y + first), 2, &split, 1, window / 2);
    FFTSetupD setup = vDSP_create_fftsetupD(log2n, kFFTRadix2);
    vDSP_fft_zripD(setup, &split, 1, log2n, kFFTDirection_Forward);
    vDSP_destroy_fftsetupD(setup);
    q->impulseRippleDB = 0;
    q->impulsePhaseDeg = 0;
    for (NSUInteger bin = 1; bin < window / 2; bin++) {
        double f = bin * pair.to / window;
        if (f < 20 || f > 20000) {
            continue;
        }
        // vDSP's forward real FFT is twice the DFT; the window began at
        // `first`, so the phase is rotated back to the impulse's instant.
        double re = real[bin] / 2, im = imaginary[bin] / 2, shift = -2 * M_PI * f * (first / pair.to - t0);
        double hr = re * cos(shift) - im * sin(shift), hi = re * sin(shift) + im * cos(shift);
        q->impulseRippleDB = MAX(q->impulseRippleDB, fabs(20 * log10(hypot(hr, hi) / scale)));
        q->impulsePhaseDeg = MAX(q->impulsePhaseDeg, fabs(atan2(hi, hr) * 180 / M_PI));
    }
    free(real);
    free(imaginary);
}

// A sine sampled so that no sample lands on its peak, scaled so the largest
// sample is 0.999 while the waveform between samples reaches about +3 dBFS
// (at 44.1 kHz, 11025 Hz at 45°): the float bus must carry it unclipped.
- (void)measureOversForPair:(RatePair)pair into:(Quality *)q {
    double periodSamples = 4;
    while (pair.from / periodSamples > 12500) {
        periodSamples *= 2;
    }
    double f = pair.from / periodSamples, amplitude = 0.999 / cos(M_PI / periodSamples);
    NSUInteger count = (NSUInteger)pair.from;
    NSURL *url = [self source:@"overs" pair:pair count:count build:^(double *source) {
        for (NSUInteger m = 0; m < count; m++) {
            source[m] = amplitude * sin(2 * M_PI * f * m / pair.from + M_PI / periodSamples);
        }
    }];
    NSData *output = [self convert:url toRate:pair.to];
    NSUInteger available = output.length / sizeof(double), window = 16384, first = available / 2 - window / 2;
    double a = 0, b = 0;
    double residual = FitTones((const double *)output.bytes + first, window, &f, 1, pair.to, first, 0, &a, &b);
    double fitted = hypot(a, b);
    q->oversGainDB = 20 * log10(fitted / amplitude);
    q->oversTHDNdB = DB(residual / (fitted * fitted / 2));
}

- (Quality)qualityForPair:(RatePair)pair {
    Quality q = {0};
    _cpuSeconds = 0;
    _audioSeconds = 0;
    [self measureTonesForPair:pair into:&q];
    [self measureSweepForPair:pair into:&q];
    [self measureSawForPair:pair into:&q];
    [self measureSilenceAndDCForPair:pair into:&q];
    [self measureMultitoneForPair:pair into:&q];
    [self measureIntermodulationForPair:pair into:&q];
    [self measureImpulseForPair:pair into:&q];
    [self measureOversForPair:pair into:&q];
    q.corePercent = 100 * _cpuSeconds / _audioSeconds;
    return q;
}

static NSString *TableHeader(void) {
    return @"| pair | ripple dB | -0.1dB Hz | -3dB Hz | worst THD+N dB | THD 1k | THD 6k | "
           "noise dBFS | stopband dB | stop edge dB | delay smp | phase spread smp | sweep in-band dB | sweep stop dB | "
           "saw spur dB | multitone null dB | round trip dB | IMD CCIF dB | IMD SMPTE dB | "
           "IR ripple dB | IR phase deg | overs gain dB | overs THD+N dB | silence | DC err | core % |\n"
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n";
}

static NSString *TableRow(RatePair pair, Quality q) {
    return [NSString stringWithFormat:@"| %@ | %.1e | %.0f | %.0f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.4f | %.5f | %.1f | %.1f | "
           "%.1f | %.1f | %.1f | %.1f | %.1f | %.1e | %.1e | %.1e | %.1f | %.2g | %.2g | %.3f |\n",
           PairName(pair), q.rippleDB, q.edge01Hz, q.edge3Hz, q.worstTHDNdB,
           q.thd1kDB, q.thd6kDB, q.noiseFloorDBFS, q.stopbandDB, q.stopbandEdgeDB, q.delaySamples, q.phaseSpreadSamples,
           q.sweepInBandDB, q.sweepStopbandDB, q.sawSpurDB,
           q.multitoneNullDB, q.roundTripDB, q.imdCCIFdB, q.imdSMPTEdB, q.impulseRippleDB, q.impulsePhaseDeg,
           q.oversGainDB, q.oversTHDNdB, q.silencePeak,
           q.dcError, q.corePercent];
}

// The bar the resampler is held to, at every pair. Measured values are in the
// printed table; each bound sits a margin past the worse of r8brain and the
// Apple converter it replaced.
- (void)assertQuality:(Quality)q pair:(RatePair)pair {
    NSString *label = PairName(pair);
    XCTAssertLessThan(q.rippleDB, 0.0001, @"%@ passband ripple to 20 kHz", label);
    XCTAssertGreaterThanOrEqual(q.edge01Hz, 20000, @"%@ flat to 20 kHz", label);
    XCTAssertLessThan(q.worstTHDNdB, -140, @"%@ THD+N in the passband", label);
    XCTAssertLessThan(q.thd1kDB, -150, @"%@ THD at 1 kHz", label);
    XCTAssertLessThan(q.thd6kDB, -150, @"%@ THD at 6 kHz", label);
    XCTAssertLessThan(q.noiseFloorDBFS, -200, @"%@ noise floor", label);
    if (pair.from > pair.to) {
        XCTAssertLessThan(q.stopbandDB, -140, @"%@ stopband", label);
        XCTAssertLessThan(q.stopbandEdgeDB, -140, @"%@ stopband from the Nyquist", label);
        XCTAssertLessThan(q.sweepStopbandDB, -140, @"%@ sweep past the Nyquist", label);
    }
    XCTAssertLessThan(fabs(q.delaySamples), 0.01, @"%@ delay at 1 kHz", label);
    XCTAssertLessThan(q.phaseSpreadSamples, 0.001, @"%@ linear phase", label);
    XCTAssertLessThan(q.sweepInBandDB, -140, @"%@ sweep spurs in band", label);
    XCTAssertLessThan(q.sawSpurDB, -140, @"%@ saw spurs", label);
    XCTAssertLessThan(q.multitoneNullDB, -140, @"%@ multitone against its ideal", label);
    XCTAssertLessThan(q.roundTripDB, -138, @"%@ there and back", label);
    XCTAssertLessThan(q.imdCCIFdB, -150, @"%@ CCIF intermodulation", label);
    XCTAssertLessThan(q.imdSMPTEdB, -150, @"%@ SMPTE intermodulation", label);
    XCTAssertLessThan(q.impulseRippleDB, 0.0001, @"%@ impulse response magnitude", label);
    XCTAssertLessThan(q.impulsePhaseDeg, 0.0001, @"%@ impulse response phase", label);
    XCTAssertLessThan(fabs(q.oversGainDB), 0.0001, @"%@ inter-sample overs: gain", label);
    XCTAssertLessThan(q.oversTHDNdB, -140, @"%@ inter-sample overs: nothing clipped", label);
    XCTAssertEqual(q.silencePeak, 0, @"%@ silence", label);
    XCTAssertLessThan(q.dcError, 1e-6, @"%@ DC", label);
}

- (void)testTheResamplerAtEveryRatePair {
    NSMutableString *table = [TableHeader() mutableCopy];
    for (size_t p = 0; p < sizeof(kPairs) / sizeof(kPairs[0]); p++) {
        Quality q = [self qualityForPair:kPairs[p]];
        [table appendString:TableRow(kPairs[p], q)];
        [self assertQuality:q pair:kPairs[p]];
        XCTAssertGreaterThan(q.corePercent, 0, @"the bus accounted no resampling");
    }
    XCTAttachment *attachment = [XCTAttachment attachmentWithString:table];
    attachment.name = @"resampler quality";
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

// The sweep and saw analyses run on their ideal signals, synthesized at each
// pair's output rate: every spur bound above sits at least 10 dB over what
// the analysis itself reads.
- (void)testTheSpectralAnalysisResolvesBelowItsBounds {
    for (size_t p = 0; p < sizeof(kPairs) / sizeof(kPairs[0]); p++) {
        RatePair pair = kPairs[p];
        KaiserSpectrum *spectrum = [[KaiserSpectrum alloc] initWithLength:kSweepFrame];
        double *power = malloc((kSweepFrame / 2 + 1) * sizeof(double));
        double *ideal = malloc(MAX(kSweepFrame, kSawFrame) * sizeof(double));
        double reference = SweepReference(spectrum, pair.to, ideal, power), guardHz = 12 * pair.to / kSweepFrame;
        double sweepFloor = -400, k = SweepRate(pair);
        for (NSUInteger start = kSweepHop; kSweepStart + k * (start + kSweepFrame) / pair.to <= 20000; start += kSweepHop) {
            for (NSUInteger n = 0; n < kSweepFrame; n++) {
                ideal[n] = SweepAt((start + n) / pair.to, pair);
            }
            double zone[2] = { kSweepStart + k * start / pair.to, kSweepStart + k * (start + kSweepFrame) / pair.to };
            double outside, inside;
            [spectrum powerOf:ideal into:power];
            SplitPower(power, kSweepFrame, pair.to, zone, 1, guardHz, &outside, &inside);
            sweepFloor = MAX(sweepFloor, DB(outside / reference));
        }
        NSUInteger outputFrames = (NSUInteger)llround(kSawSeconds * pair.to);
        vDSP_vclrD(ideal, 1, kSawFrame);
        int bothNyquists = (int)floor(MIN(0.999 * pair.from, pair.to) / 2 / kSawFundamental);
        AddSaw(ideal, kSawFrame, (outputFrames - kSawFrame) / 2, bothNyquists, pair.to);
        double sawFloor = SawSpur(ideal, pair.to);
        XCTAssertLessThan(sweepFloor, -150, @"%@ the sweep analysis's own floor", PairName(pair));
        XCTAssertLessThan(sawFloor, -150, @"%@ the saw analysis's own floor", PairName(pair));
        free(power);
        free(ideal);
    }
}

@end
