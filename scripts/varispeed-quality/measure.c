// Measures the pitch fader's varispeed (docs/audio-quality.md, "The pitch
// fader"): Apple's Varispeed unit hosted as AudioPlayer+Pipeline.m hosted it
// before Vibe's own converter, r8brain at the same fixed ratio as the
// reference, and a prototype of that converter. Audio/FX/AudioVarispeed.m is
// this one's design, and testPitchQuality measures it in the player. Input
// and output are both on a 48 kHz grid, so at ratio r an input tone at f / r
// comes out at f.
//
// Each output tone is fitted at its frequency with free gain and phase, after
// refining the frequency, and the residual is distortion + noise. That is more
// lenient than ResamplerQualityTests, so the numbers do not compare with
// docs/audio-quality.md's. The float32 test signal is the floor: about -150 dB
// for one tone and -141 dB for twenty.
//
// Built and run by run.sh beside this file.
#include <AudioToolbox/AudioToolbox.h>
#include <Accelerate/Accelerate.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// r8brain's C entry points (DLL/r8bsrc.h is C++ only).
typedef void *CR8BResampler;
enum { r8brr24 = 2 };
CR8BResampler r8b_create(double SrcSampleRate, double DstSampleRate, int MaxInLen, double ReqTransBand, int Res);
void r8b_delete(CR8BResampler rs);
int r8b_process(CR8BResampler rs, double *ip0, int l, double **op0);

#define FS 48000.0
#define SLICE 512     // frames per render slice
#define SKIP 16384    // frames left out of every analysis, past each converter's start
#define M 65536       // frames analyzed

typedef struct {
    float *ch[2];
    size_t len, pos;
} Source;

static Source make_source(size_t len) {
    Source s = {{calloc(len, sizeof(float)), calloc(len, sizeof(float))}, len, 0};
    return s;
}

static void free_source(Source *s) {
    free(s->ch[0]);
    free(s->ch[1]);
}

static void add_tone(Source *s, double f, double amp, double phase) {
    for (size_t n = 0; n < s->len; n++) {
        double v = amp * sin(2 * M_PI * f * (double)n / FS + phase);
        s->ch[0][n] += (float)v;
        s->ch[1][n] += (float)v;
    }
}

static double seconds_since(uint64_t start) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)(mach_absolute_time() - start) * tb.numer / tb.denom / 1e9;
}

// The ratio for the slice starting at output frame n; NULL holds the ratio.
typedef double (*RateFn)(size_t n, double base);

#pragma mark - Apple's Varispeed

static OSStatus apple_input(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                            UInt32 frames, AudioBufferList *data) {
    Source *s = ref;
    for (int c = 0; c < 2; c++) {
        float *d = data->mBuffers[c].mData;
        for (UInt32 i = 0; i < frames; i++) {
            size_t p = s->pos + i;
            d[i] = p < s->len ? s->ch[c][p] : 0;
        }
    }
    s->pos += frames;
    return noErr;
}

// As AudioPlayer+Pipeline.m hosted it: stereo float32 at the bus rate,
// 4096 frames per slice at most, the highest render quality. `mastering` also
// asks for Apple's Mastering converter, which the unit refuses.
static AudioUnit apple_make(Source *src, int mastering, OSStatus *masteringStatus) {
    AudioComponentDescription d = {kAudioUnitType_FormatConverter, kAudioUnitSubType_Varispeed, kAudioUnitManufacturer_Apple, 0, 0};
    AudioUnit u = NULL;
    AudioComponentInstanceNew(AudioComponentFindNext(NULL, &d), &u);
    AudioStreamBasicDescription asbd = {
        .mSampleRate = FS, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    UInt32 maxFrames = 4096, quality = kRenderQuality_Max;
    AURenderCallbackStruct input = {apple_input, src};
    OSStatus status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, sizeof(asbd));
    status |= AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, sizeof(asbd));
    status |= AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    status |= AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, sizeof(input));
    status |= AudioUnitSetProperty(u, kAudioUnitProperty_RenderQuality, kAudioUnitScope_Global, 0, &quality, sizeof(quality));
    if (mastering) {
        UInt32 complexity = kAudioUnitSampleRateConverterComplexity_Mastering;
        *masteringStatus = AudioUnitSetProperty(u, kAudioUnitProperty_SampleRateConverterComplexity, kAudioUnitScope_Global, 0,
                                                &complexity, sizeof(complexity));
    }
    status |= AudioUnitInitialize(u);
    if (status != noErr) {
        fprintf(stderr, "hosting the Varispeed failed (%d)\n", (int)status);
        exit(1);
    }
    return u;
}

static void apple_report(void) {
    Source s = make_source(16);
    OSStatus mastering = noErr;
    AudioUnit u = apple_make(&s, 1, &mastering);
    Float64 latency = 0;
    UInt32 size = sizeof(latency);
    AudioUnitGetProperty(u, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    printf("declared latency: %.1f frames\n", latency * FS);
    printf("Mastering converter: %s (%d)\n", mastering == noErr ? "accepted" : "refused", (int)mastering);
    AudioUnitUninitialize(u);
    AudioComponentInstanceDispose(u);
    free_source(&s);
}

static void run_apple(Source *src, double r, size_t N, float *out[2], RateFn fn) {
    src->pos = 0;
    AudioUnit u = apple_make(src, 0, NULL);
    AudioUnitSetParameter(u, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, (Float32)r, 0);
    struct { UInt32 count; AudioBuffer buffers[2]; } list;
    AudioTimeStamp stamp = {.mFlags = kAudioTimeStampSampleTimeValid};
    for (size_t done = 0; done < N;) {
        UInt32 frames = (UInt32)(N - done < SLICE ? N - done : SLICE);
        if (fn) AudioUnitSetParameter(u, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, (Float32)fn(done, r), 0);
        list.count = 2;
        for (int c = 0; c < 2; c++) {
            list.buffers[c] = (AudioBuffer){1, frames * 4, out[c] + done};
        }
        AudioUnitRenderActionFlags flags = 0;
        if (AudioUnitRender(u, &flags, &stamp, 0, frames, (AudioBufferList *)&list) != noErr) {
            fprintf(stderr, "render failed\n");
            exit(1);
        }
        stamp.mSampleTime += frames;
        done += frames;
    }
    AudioUnitUninitialize(u);
    AudioComponentInstanceDispose(u);
}

#pragma mark - r8brain

// As Audio/AudioResampler.mm sets it up, at a fixed ratio: the source is
// declared at FS * r.
static void run_r8brain(Source *src, double r, size_t N, float *out[2]) {
    double *in = malloc(4096 * sizeof(double));
    for (int c = 0; c < 2; c++) {
        CR8BResampler rs = r8b_create(FS * r, FS, 4096, 1.0, r8brr24);
        size_t pos = 0, done = 0;
        while (done < N) {
            for (int i = 0; i < 4096; i++) in[i] = pos + i < src->len ? src->ch[c][pos + i] : 0;
            pos += 4096;
            double *o = NULL;
            int made = r8b_process(rs, in, 4096, &o);
            for (int i = 0; i < made && done < N; i++) out[c][done++] = (float)o[i];
        }
        r8b_delete(rs);
    }
    free(in);
}

#pragma mark - The custom converter

// A Kaiser-windowed sinc, stretched by the ratio above 1 so its cutoff follows
// the output's Nyquist. The environment overrides the design:
//   VS_T     zero crossings each side (default 64)
//   VS_FC    the -6 dB cutoff in Hz at 48 kHz (default 22000)
//   VS_BETA  the Kaiser beta (default 15.6, about 150 dB of stopband)
//   VS_P     polyphase table phases per input sample (default 128)
typedef struct {
    double T, fc, beta;
    int P;
    // The kernel at 512 points per input sample, which the polyphase rows are
    // read from by a cubic.
    double *fine;
    int fineLen;
} Kernel;

// One stretch's polyphase table: phase j at row j + 1, j in [-1, P + 1], so the
// cubic always has four rows.
typedef struct {
    double stretch;
    int K, taps;
    double *rows;
    float *rowsFloat;
} Table;

#define FINE 512

static double env_or(const char *name, double fallback) {
    const char *v = getenv(name);
    return v ? atof(v) : fallback;
}

static double bessel_i0(double x) {
    double sum = 1, term = 1, q = x * x / 4;
    for (int k = 1; k < 200 && term > sum * 1e-17; k++) {
        term *= q / ((double)k * k);
        sum += term;
    }
    return sum;
}

static double lagrange4(const double *y, double m) {
    double c1 = y[2] - y[0] / 3 - y[1] / 2 - y[3] / 6;
    double c2 = (y[0] + y[2]) / 2 - y[1];
    double c3 = (y[3] - y[0]) / 6 + (y[1] - y[2]) / 2;
    return ((c3 * m + c2) * m + c1) * m + y[1];
}

static Kernel *kernel(void) {
    static Kernel *k = NULL;
    if (k) return k;
    k = calloc(1, sizeof(Kernel));
    k->T = env_or("VS_T", 64);
    k->fc = env_or("VS_FC", 22000) / FS;
    k->beta = env_or("VS_BETA", 15.6);
    k->P = (int)env_or("VS_P", 128);
    k->fineLen = (int)(k->T * FINE) + 4;
    k->fine = calloc(k->fineLen, sizeof(double));
    double i0 = bessel_i0(k->beta);
    for (int i = 0; i < k->fineLen; i++) {
        double u = (double)i / FINE, x = 2 * k->fc * u;
        double sinc = u == 0 ? 1 : sin(M_PI * x) / (M_PI * x);
        double window = u >= k->T ? 0 : bessel_i0(k->beta * sqrt(1 - (u / k->T) * (u / k->T))) / i0;
        k->fine[i] = 2 * k->fc * sinc * window;
    }
    return k;
}

static double kernel_at(const Kernel *k, double u) {
    u = fabs(u) * FINE;
    int j = (int)u;
    if (j >= k->fineLen - 3) return 0;
    double y[4] = {j > 0 ? k->fine[j - 1] : k->fine[1], k->fine[j], k->fine[j + 1], k->fine[j + 2]};
    return lagrange4(y, u - j);
}

static Table *table_build(double stretch) {
    Kernel *k = kernel();
    Table *t = calloc(1, sizeof(Table));
    t->stretch = stretch;
    t->K = (int)ceil(k->T * stretch);
    t->taps = 2 * t->K;
    size_t count = (size_t)(k->P + 3) * t->taps;
    t->rows = malloc(count * sizeof(double));
    t->rowsFloat = malloc(count * sizeof(float));
    for (int j = -1; j <= k->P + 1; j++) {
        for (int i = 0; i < t->taps; i++) {
            double x = (double)(i - t->K + 1) - (double)j / k->P;
            size_t at = (size_t)(j + 1) * t->taps + i;
            t->rows[at] = kernel_at(k, x / stretch) / stretch;
            t->rowsFloat[at] = (float)t->rows[at];
        }
    }
    return t;
}

static void table_free(Table *t) {
    free(t->rows);
    free(t->rowsFloat);
    free(t);
}

static double g_tableSeconds = 0;

// Per output frame: the four rows around the position, combined by a cubic
// into one weight vector, which each channel dots with its history. The input
// is widened once, as a double history ring would be. With `fn`, the ratio is
// read once a slice and the table rebuilt for its stretch; `ramp` moves the
// step linearly across the slice from the last ratio, where Apple's unit
// steps.
static void run_custom(Source *src, double r, size_t N, float *out[2], RateFn fn, int ramp, int useFloat) {
    Kernel *k = kernel();
    int P = k->P, pad = (int)ceil(k->T * 1.25) + 2;
    size_t len = src->len + 2 * (size_t)pad;
    double *xd[2];
    float *xf[2];
    for (int c = 0; c < 2; c++) {
        xd[c] = calloc(len, sizeof(double));
        xf[c] = calloc(len, sizeof(float));
        for (size_t i = 0; i < src->len; i++) {
            xd[c][i + pad] = src->ch[c][i];
            xf[c][i + pad] = src->ch[c][i];
        }
    }
    uint64_t start = mach_absolute_time();
    Table *t = table_build(r > 1 ? r : 1);
    g_tableSeconds = seconds_since(start);
    // Room for any stretch up to 1.25, the widest the history pad allows.
    double *w = malloc(2 * (size_t)pad * sizeof(double));
    float *wf = malloc(2 * (size_t)pad * sizeof(float));
    uint64_t index = 0;
    double frac = 0, from = r, to = r;
    for (size_t n = 0; n < N; n++) {
        if (fn && n % SLICE == 0) {
            from = to;
            to = fn(n, r);
            double stretch = to > 1 ? to : 1;
            if (stretch != t->stretch) {
                table_free(t);
                t = table_build(stretch);
            }
        }
        double step = fn && ramp ? from + (to - from) * (double)(n % SLICE + 1) / SLICE : to;
        int taps = t->taps;
        double position = frac * P;
        int j = (int)position;
        double mu = position - j;
        double cm1 = -mu * (mu - 1) * (mu - 2) / 6, c0 = (mu + 1) * (mu - 1) * (mu - 2) / 2;
        double c1 = -(mu + 1) * mu * (mu - 2) / 2, c2 = (mu + 1) * mu * (mu - 1) / 6;
        // Input frames index - K + 1 ... index + K.
        size_t base = index + pad - t->K + 1;
        if (!useFloat) {
            const double *r0 = t->rows + (size_t)j * taps, *r1 = r0 + taps, *r2 = r1 + taps, *r3 = r2 + taps;
            for (int i = 0; i < taps; i++) w[i] = cm1 * r0[i] + c0 * r1[i] + c1 * r2[i] + c2 * r3[i];
            for (int c = 0; c < 2; c++) {
                const double *x = xd[c] + base;
                double sum = 0;
                {
#pragma clang fp reassociate(on)
                    for (int i = 0; i < taps; i++) sum += x[i] * w[i];
                }
                out[c][n] = (float)sum;
            }
        } else {
            const float *r0 = t->rowsFloat + (size_t)j * taps, *r1 = r0 + taps, *r2 = r1 + taps, *r3 = r2 + taps;
            float fm1 = (float)cm1, f0 = (float)c0, f1 = (float)c1, f2 = (float)c2;
            for (int i = 0; i < taps; i++) wf[i] = fm1 * r0[i] + f0 * r1[i] + f1 * r2[i] + f2 * r3[i];
            for (int c = 0; c < 2; c++) {
                const float *x = xf[c] + base;
                float sum = 0;
                {
#pragma clang fp reassociate(on)
                    for (int i = 0; i < taps; i++) sum += x[i] * wf[i];
                }
                out[c][n] = sum;
            }
        }
        frac += step;
        double whole = floor(frac);
        index += (uint64_t)whole;
        frac -= whole;
    }
    table_free(t);
    free(w);
    free(wf);
    for (int c = 0; c < 2; c++) {
        free(xd[c]);
        free(xf[c]);
    }
}

#pragma mark - Engines

typedef enum { ENGINE_APPLE, ENGINE_R8BRAIN, ENGINE_CUSTOM, ENGINE_CUSTOM_FLOAT, ENGINE_COUNT } Engine;
static const char *kEngineArgs[] = {"apple", "r8brain", "custom", "custom-float"};
static const char *kEngineNames[] = {"Apple Varispeed", "r8brain, fixed ratio", "custom converter", "custom converter, float32 sums"};

static void run(Engine e, Source *src, double r, size_t N, float *out[2]) {
    switch (e) {
        case ENGINE_APPLE: run_apple(src, r, N, out, NULL); break;
        case ENGINE_R8BRAIN: run_r8brain(src, r, N, out); break;
        case ENGINE_CUSTOM: run_custom(src, r, N, out, NULL, 0, 0); break;
        default: run_custom(src, r, N, out, NULL, 0, 1); break;
    }
}

#pragma mark - Analysis

static double dB(double power) {
    return power > 0 ? 10 * log10(power) : -400;
}

// The least-squares fit of DC and `k` tones at `freqs` over x[0, n): the
// residual's mean square, and each tone's amplitude in `amps`.
static double fit(const float *x, size_t n, const double *freqs, int k, double *amps) {
    int size = 2 * k + 1;
    double *A = calloc((size_t)size * size, sizeof(double)), *v = calloc(size, sizeof(double));
    double *basis = malloc(size * sizeof(double)), *coef = calloc(size, sizeof(double));
    for (size_t i = 0; i < n; i++) {
        basis[0] = 1;
        for (int t = 0; t < k; t++) {
            double phase = 2 * M_PI * freqs[t] * (double)i / FS;
            basis[1 + 2 * t] = cos(phase);
            basis[2 + 2 * t] = sin(phase);
        }
        for (int a = 0; a < size; a++) {
            v[a] += basis[a] * x[i];
            for (int b = a; b < size; b++) A[a * size + b] += basis[a] * basis[b];
        }
    }
    for (int a = 0; a < size; a++) {
        for (int b = 0; b < a; b++) A[a * size + b] = A[b * size + a];
    }
    // Gaussian elimination with partial pivoting.
    for (int col = 0; col < size; col++) {
        int pivot = col;
        for (int row = col + 1; row < size; row++) {
            if (fabs(A[row * size + col]) > fabs(A[pivot * size + col])) pivot = row;
        }
        for (int q = 0; q < size && pivot != col; q++) {
            double swap = A[col * size + q];
            A[col * size + q] = A[pivot * size + q];
            A[pivot * size + q] = swap;
        }
        if (pivot != col) {
            double swap = v[col];
            v[col] = v[pivot];
            v[pivot] = swap;
        }
        for (int row = col + 1; row < size; row++) {
            double f = A[row * size + col] / A[col * size + col];
            for (int q = col; q < size; q++) A[row * size + q] -= f * A[col * size + q];
            v[row] -= f * v[col];
        }
    }
    for (int row = size - 1; row >= 0; row--) {
        double sum = v[row];
        for (int q = row + 1; q < size; q++) sum -= A[row * size + q] * coef[q];
        coef[row] = sum / A[row * size + row];
    }
    double residual = 0;
    for (size_t i = 0; i < n; i++) {
        double e = x[i] - coef[0];
        for (int t = 0; t < k; t++) {
            double phase = 2 * M_PI * freqs[t] * (double)i / FS;
            e -= coef[1 + 2 * t] * cos(phase) + coef[2 + 2 * t] * sin(phase);
        }
        residual += e * e;
    }
    for (int t = 0; t < k && amps; t++) amps[t] = hypot(coef[1 + 2 * t], coef[2 + 2 * t]);
    free(A);
    free(v);
    free(basis);
    free(coef);
    return residual / n;
}

// The scale on f0 that minimizes a one-tone fit: a grid over ±200 ppm, then a
// golden-section search. Apple's rate is a Float32, a little off the ratio.
static double refine(const float *x, size_t n, double f0, double *residual, double *amp) {
    double lo = 1 - 2e-4, hi = 1 + 2e-4, best = 1, bestResidual = INFINITY;
    for (int i = 0; i <= 80; i++) {
        double s = lo + (hi - lo) * i / 80, f = f0 * s;
        double r = fit(x, n, &f, 1, NULL);
        if (r < bestResidual) {
            bestResidual = r;
            best = s;
        }
    }
    const double g = 0.6180339887498949;
    double a = best - (hi - lo) / 80, b = best + (hi - lo) / 80;
    double c = b - g * (b - a), d = a + g * (b - a);
    double fc = f0 * c, fd = f0 * d;
    double rc = fit(x, n, &fc, 1, NULL), rd = fit(x, n, &fd, 1, NULL);
    for (int i = 0; i < 60; i++) {
        if (rc < rd) {
            b = d; d = c; rd = rc;
            c = b - g * (b - a); fc = f0 * c; rc = fit(x, n, &fc, 1, NULL);
        } else {
            a = c; c = d; rc = rd;
            d = a + g * (b - a); fd = f0 * d; rd = fit(x, n, &fd, 1, NULL);
        }
    }
    double s = (a + b) / 2, f = f0 * s;
    *residual = fit(x, n, &f, 1, amp);
    return s;
}

#pragma mark - Measurements

static const double kRatios[] = {0.84, 0.92, 0.96, 0.99, 1.0, 1.01, 1.04, 1.08, 1.16};
static const double kOutputTones[] = {100, 1000, 5000, 10000, 15000, 18000, 20000, 21000, 22000, 23000};
static float *g_out[2];
static const size_t kFrames = SKIP + M + 4096;

static Source source_for(size_t frames) {
    return make_source((size_t)(frames * 1.3) + 8192);
}

// A tone at fo out: its gain, its distortion + noise against itself, the
// residual against full scale, and the frequency scale the fit found.
static void tone(Engine e, double r, double fo, double amp, double *gain, double *thdn, double *floorDBFS, double *scale) {
    Source s = source_for(kFrames);
    add_tone(&s, fo / r, amp, 0.3);
    run(e, &s, r, kFrames, g_out);
    double residual, fitted;
    *scale = refine(g_out[0] + SKIP, M, fo, &residual, &fitted);
    *gain = 20 * log10(fitted / amp);
    *thdn = dB(residual / (fitted * fitted / 2));
    *floorDBFS = dB(residual / 0.5);
    free_source(&s);
}

// Twenty tones, 40 Hz to 19.5 kHz out (lower when slowing down), each fitted
// with free gain and phase: the residual against their total.
static double twenty_tones(Engine e, double r, double scale) {
    double fo[20];
    Source s = source_for(kFrames);
    double top = fmin(19500, r < 1 ? 23500 * r : 19500);
    for (int k = 0; k < 20; k++) {
        fo[k] = 40 * pow(top / 40, k / 19.0);
        add_tone(&s, fo[k] / r, 0.045, 0.7 * k);
        fo[k] *= scale;
    }
    run(e, &s, r, kFrames, g_out);
    double amps[20], signal = 0;
    double residual = fit(g_out[0] + SKIP, M, fo, 20, amps);
    for (int k = 0; k < 20; k++) signal += amps[k] * amps[k] / 2;
    free_source(&s);
    return dB(residual / signal);
}

// An input tone whose output would sit above Nyquist: everything that comes
// out, against the tone.
static double false_tones(Engine e, double r, double fi) {
    Source s = source_for(kFrames);
    add_tone(&s, fi, 0.891, 0.1);
    run(e, &s, r, kFrames, g_out);
    double power = 0;
    for (size_t i = 0; i < M; i++) power += (double)g_out[0][SKIP + i] * g_out[0][SKIP + i];
    free_source(&s);
    return dB(power / M / (0.891 * 0.891 / 2));
}

static void quality(Engine e) {
    printf("\n## %s\n", kEngineNames[e]);
    if (e == ENGINE_APPLE) apple_report();
    if (e >= ENGINE_CUSTOM) {
        Kernel *k = kernel();
        printf("kernel: %g zero crossings each side, -6 dB at %.0f Hz, beta %g, %d phases\n", k->T, k->fc * FS, k->beta, k->P);
    }
    for (size_t ri = 0; ri < sizeof(kRatios) / sizeof(kRatios[0]); ri++) {
        double r = kRatios[ri];
        if (e == ENGINE_R8BRAIN && r == 1.0) continue;
        printf("\n### ratio %.2f\n\n| out Hz | gain dB | distortion + noise dB | ratio error ppm |\n| --- | --- | --- | --- |\n", r);
        double scale10k = 1;
        for (size_t ti = 0; ti < sizeof(kOutputTones) / sizeof(kOutputTones[0]); ti++) {
            double fo = kOutputTones[ti];
            if (fo / r >= 23950) continue;
            double gain, thdn, floorDBFS, scale;
            tone(e, r, fo, 0.891, &gain, &thdn, &floorDBFS, &scale);
            if (fo == 10000) scale10k = scale;
            printf("| %.0f | %.4f | %.1f | %.3f |\n", fo, gain, thdn, (scale - 1) * 1e6);
            fflush(stdout);
        }
        double gain, thdn, floorDBFS, scale;
        tone(e, r, 1000, 0.001, &gain, &thdn, &floorDBFS, &scale);
        printf("\nnoise under a 1 kHz tone at -60 dBFS: %.1f dBFS\n", floorDBFS);
        printf("twenty tones: %.1f dB\n", twenty_tones(e, r, scale10k));
        if (r > 1) {
            double edge = 24000 / r, inputs[] = {edge + 150, (edge + 24000) / 2, 23800};
            printf("false tones (input above %.0f Hz):", edge);
            for (int i = 0; i < 3; i++) printf(" %.0f Hz %.1f dB;", inputs[i], false_tones(e, r, inputs[i]));
            printf("\n");
        }
        fflush(stdout);
    }
}

// The fader dragged from 0 to +8% over 2 s, the ratio read once a slice: the
// power outside the swept band against the tone, from a Kaiser (beta 20)
// spectrum of the 2^17 frames that span the drag.
static double drag_rate(size_t n, double base) {
    size_t length = (size_t)(2 * FS);
    if (n < SKIP) return 1.0;
    if (n >= SKIP + length) return 1.08;
    return 1.0 + 0.08 * (double)(n - SKIP) / length;
}

static double drag(Engine e, double fi, int ramp) {
    size_t n = 131072, frames = SKIP + n + 4096;
    float *o[2] = {calloc(frames, sizeof(float)), calloc(frames, sizeof(float))};
    Source s = source_for(frames);
    add_tone(&s, fi, 0.891, 0.2);
    if (e == ENGINE_APPLE) run_apple(&s, 1.0, frames, o, drag_rate);
    else run_custom(&s, 1.0, frames, o, drag_rate, ramp, 0);
    double *re = calloc(n, sizeof(double)), *im = calloc(n, sizeof(double)), i0 = bessel_i0(20);
    for (size_t i = 0; i < n; i++) {
        double u = 2.0 * i / (n - 1) - 1;
        re[i] = o[0][SKIP + i] * bessel_i0(20 * sqrt(fmax(0, 1 - u * u))) / i0;
    }
    FFTSetupD setup = vDSP_create_fftsetupD(17, kFFTRadix2);
    DSPDoubleSplitComplex z = {re, im};
    vDSP_fft_zipD(setup, &z, 1, 17, kFFTDirection_Forward);
    double inside = 0, outside = 0, lo = fi - 60, hi = fi * 1.08 + 60;
    for (size_t k = 1; k < n / 2; k++) {
        double f = (double)k * FS / n, p = re[k] * re[k] + im[k] * im[k];
        if (f >= lo && f <= hi) inside += p;
        else outside += p;
    }
    vDSP_destroy_fftsetupD(setup);
    free(re);
    free(im);
    free(o[0]);
    free(o[1]);
    free_source(&s);
    return dB(outside / inside);
}

static double cpu_percent(Engine e, double r) {
    size_t frames = (size_t)(FS * 30);
    float *o[2] = {malloc(frames * sizeof(float)), malloc(frames * sizeof(float))};
    Source s = source_for(frames);
    add_tone(&s, 997, 0.5, 0);
    add_tone(&s, 6007, 0.3, 0);
    uint64_t start = mach_absolute_time();
    run(e, &s, r, frames, o);
    double seconds = seconds_since(start);
    free_source(&s);
    free(o[0]);
    free(o[1]);
    return 100 * seconds / 30;
}

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static int usage(void) {
    fprintf(stderr, "usage: measure quality apple|r8brain|custom|custom-float ...\n"
                    "       measure drag\n"
                    "       measure cpu\n");
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    g_out[0] = calloc(kFrames, sizeof(float));
    g_out[1] = calloc(kFrames, sizeof(float));
    if (!strcmp(argv[1], "quality")) {
        if (argc < 3) return usage();
        for (int a = 2; a < argc; a++) {
            Engine e = ENGINE_COUNT;
            for (int i = 0; i < ENGINE_COUNT; i++) {
                if (!strcmp(argv[a], kEngineArgs[i])) e = (Engine)i;
            }
            if (e == ENGINE_COUNT) return usage();
            quality(e);
        }
    } else if (!strcmp(argv[1], "drag")) {
        printf("| tone | Apple Varispeed | custom, stepped | custom, ramped |\n| --- | --- | --- | --- |\n");
        double tones[] = {1000, 8000};
        for (int i = 0; i < 2; i++) {
            printf("| %.0f Hz | %.1f dB | %.1f dB | %.1f dB |\n", tones[i], drag(ENGINE_APPLE, tones[i], 0),
                   drag(ENGINE_CUSTOM, tones[i], 0), drag(ENGINE_CUSTOM, tones[i], 1));
            fflush(stdout);
        }
    } else if (!strcmp(argv[1], "cpu")) {
        // Medians of five 30 s stereo runs, as a share of one core.
        double ratios[] = {0.92, 1.04, 1.16};
        printf("| engine | 0.92 | 1.04 | 1.16 |\n| --- | --- | --- | --- |\n");
        for (int e = 0; e < ENGINE_COUNT; e++) {
            printf("| %s |", kEngineNames[e]);
            for (int j = 0; j < 3; j++) {
                double v[5];
                for (int k = 0; k < 5; k++) v[k] = cpu_percent((Engine)e, ratios[j]);
                qsort(v, 5, sizeof(double), compare_doubles);
                printf(" %.3f%%", v[2]);
                if (e >= ENGINE_CUSTOM) printf(" (table %.2f ms)", g_tableSeconds * 1000);
                printf(" |");
            }
            printf("\n");
            fflush(stdout);
        }
    } else {
        return usage();
    }
    return 0;
}
