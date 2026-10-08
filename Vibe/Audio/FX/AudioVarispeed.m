//
//  AudioVarispeed.m
//  Vibe
//

#import "AudioVarispeed.h"
#include <simd/simd.h>

static const double kVarispeedZeroCrossings = 64;
static const double kVarispeedCutoff = 22000.0 / 48000.0;
static const double kVarispeedBeta = 15.6;
// The kernel's resolution: a fine table at 512 points per input frame, which
// every polyphase table is read from, and that table's rows per input frame.
// A cubic across four rows gives the kernel at any phase.
static const int kVarispeedFinePoints = 512;
static const int kVarispeedPhases = 128;

static double VibeBesselI0(double x) {
    double sum = 1, term = 1, q = x * x / 4;
    for (int k = 1; k < 200 && term > sum * 1e-17; k++) {
        term *= q / ((double)k * k);
        sum += term;
    }
    return sum;
}

// The kernel at kVarispeedFinePoints per input frame, from its center out.
// Built once: every rate shares it.
static const double *VibeVarispeedFineKernel(void) {
    static double *fine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int count = (int)kVarispeedZeroCrossings * kVarispeedFinePoints + 4;
        fine = calloc((size_t)count, sizeof(double));
        double i0 = VibeBesselI0(kVarispeedBeta);
        for (int i = 0; fine && i < count; i++) {
            double u = (double)i / kVarispeedFinePoints, x = 2 * kVarispeedCutoff * u, edge = u / kVarispeedZeroCrossings;
            double sinc = u == 0 ? 1 : sin(M_PI * x) / (M_PI * x);
            double window = edge >= 1 ? 0 : VibeBesselI0(kVarispeedBeta * sqrt(1 - edge * edge)) / i0;
            fine[i] = 2 * kVarispeedCutoff * sinc * window;
        }
    });
    return fine;
}

// The kernel `u` input frames from its center: a cubic through the four
// fine points around it.
static double VibeVarispeedKernelAt(const double *fine, double u) {
    u = fabs(u) * kVarispeedFinePoints;
    int j = (int)u;
    if (j > (int)kVarispeedZeroCrossings * kVarispeedFinePoints) {
        return 0;
    }
    double y0 = j > 0 ? fine[j - 1] : fine[1], y1 = fine[j], y2 = fine[j + 1], y3 = fine[j + 2], m = u - j;
    double c1 = y2 - y0 / 3 - y1 / 2 - y3 / 6, c2 = (y0 + y2) / 2 - y1, c3 = (y3 - y0) / 6 + (y1 - y2) / 2;
    return ((c3 * m + c2) * m + c1) * m + y1;
}

// Phase j of kVarispeedPhases is row j + 1, for j from −1 to
// kVarispeedPhases + 1, so the cubic always has four rows. A row holds the
// taps for input frames index − half + 1 through index + half, around a
// position at index + j / kVarispeedPhases.
VibeVarispeedTable *VibeVarispeedTableCreate(double ratio) {
    const double *fine = VibeVarispeedFineKernel();
    double stretch = MIN(MAX(ratio, 1), kVibeVarispeedMaxRatio);
    uint32_t half = (uint32_t)ceil(kVarispeedZeroCrossings * stretch), taps = 2 * half;
    VibeVarispeedTable *table = fine ? malloc(sizeof(VibeVarispeedTable) + (size_t)(kVarispeedPhases + 3) * taps * sizeof(double))
                                     : NULL;
    if (!table) {
        return NULL;
    }
    table->stretch = stretch;
    table->half = half;
    for (int j = -1; j <= kVarispeedPhases + 1; j++) {
        double *row = table->rows + (size_t)(j + 1) * taps;
        for (uint32_t i = 0; i < taps; i++) {
            double x = (double)i - half + 1 - (double)j / kVarispeedPhases;
            row[i] = VibeVarispeedKernelAt(fine, x / stretch) / stretch;
        }
    }
    return table;
}

VIBE_REALTIME_CHECKED_BEGIN
// The last output's position past the index, read `half` frames beyond it.
// One more frame is margin, since the conversion sums the steps one at a time.
uint64_t VibeVarispeedReach(const VibeVarispeedTable *table, double fraction, double from, double to,
                            uint32_t frames) CA_REALTIME_API {
    double slope = (to - from) / frames;
    double last = fraction + (frames - 1) * from + slope * (frames - 1) * frames / 2;
    return (uint64_t)last + table->half + 2;
}

// Four taps' weights from the cubic's four rows, from tap `i`.
static inline simd_double4 VibeVarispeedWeights(const double *r0, const double *r1, const double *r2, const double *r3,
                                                simd_double4 cubic, uint32_t i) CA_REALTIME_API {
    return cubic.x * *(const simd_packed_double4 *)(r0 + i) + cubic.y * *(const simd_packed_double4 *)(r1 + i)
            + cubic.z * *(const simd_packed_double4 *)(r2 + i) + cubic.w * *(const simd_packed_double4 *)(r3 + i);
}

// Four ring frames from `i`, widened to double.
static inline simd_double4 VibeVarispeedWide(const float *x, uint32_t i) CA_REALTIME_API {
    return __builtin_convertvector(*(const simd_packed_float4 *)(x + i), simd_double4);
}

// `count` taps of the kernel, from `r0` in the first of the cubic's four rows
// (the others follow a row of `taps` apart), weighted by `cubic` and dotted
// with the ring frames from `left` and `right`, in double. Each four taps'
// weights serve both channels. Written in vectors because -Os, the shipping
// optimization, leaves the scalar loop unvectorized at three times the cost;
// eight taps a pass, into two sums per channel, so no add waits on the last
// one (7% at the wider kernels, the `pitch` benchmarks).
static inline simd_double2 VibeVarispeedTaps(const double *r0, uint32_t taps, simd_double4 cubic, uint32_t count,
                                             const float *left, const float *right) CA_REALTIME_API {
    const double *r1 = r0 + taps, *r2 = r1 + taps, *r3 = r2 + taps;
    simd_double4 left0 = 0, left1 = 0, right0 = 0, right1 = 0;
    uint32_t i = 0;
    for (; i + 8 <= count; i += 8) {
        simd_double4 w0 = VibeVarispeedWeights(r0, r1, r2, r3, cubic, i), w1 = VibeVarispeedWeights(r0, r1, r2, r3, cubic, i + 4);
        left0 += VibeVarispeedWide(left, i) * w0;
        right0 += VibeVarispeedWide(right, i) * w0;
        left1 += VibeVarispeedWide(left, i + 4) * w1;
        right1 += VibeVarispeedWide(right, i + 4) * w1;
    }
    if (i + 4 <= count) {
        simd_double4 w = VibeVarispeedWeights(r0, r1, r2, r3, cubic, i);
        left0 += VibeVarispeedWide(left, i) * w;
        right0 += VibeVarispeedWide(right, i) * w;
        i += 4;
    }
    simd_double2 sum = { simd_reduce_add(left0 + left1), simd_reduce_add(right0 + right1) };
    for (; i < count; i++) {
        double w = cubic.x * r0[i] + cubic.y * r1[i] + cubic.z * r2[i] + cubic.w * r3[i];
        sum += (simd_double2){ left[i] * w, right[i] * w };
    }
    return sum;
}

// Each output frame is the kernel at its phase, a cubic across the table's
// four rows around it, dotted with the ring around its position, which may
// wrap.
void VibeVarispeedConvert(const VibeVarispeedTable *table, const float *ringLeft, const float *ringRight, uint32_t mask,
                          uint64_t *index, double *fraction, double from, double to, uint32_t frames,
                          float *left, float *right) CA_REALTIME_API {
    double slope = (to - from) / frames;
    uint32_t half = table->half, taps = 2 * half, capacity = mask + 1;
    uint64_t at = *index;
    double past = *fraction;
    for (uint32_t n = 0; n < frames; n++) {
        double phase = past * kVarispeedPhases, mu = phase - (int)phase;
        const double *row = table->rows + (size_t)(int)phase * taps;
        double m1 = mu - 1, m2 = mu - 2, p1 = mu + 1;
        simd_double4 cubic = { -mu * m1 * m2 * (1.0 / 6), p1 * m1 * m2 * 0.5, -p1 * mu * m2 * 0.5, p1 * mu * m1 * (1.0 / 6) };
        uint32_t start = (uint32_t)(at - half + 1) & mask;
        uint32_t first = taps < capacity - start ? taps : capacity - start;
        simd_double2 sum = VibeVarispeedTaps(row, taps, cubic, first, ringLeft + start, ringRight + start)
                + VibeVarispeedTaps(row + first, taps, cubic, taps - first, ringLeft, ringRight);
        left[n] = (float)sum.x;
        right[n] = (float)sum.y;
        past += from + slope * (n + 1);
        uint64_t whole = (uint64_t)past;
        at += whole;
        past -= (double)whole;
    }
    *index = at;
    *fraction = past;
}
VIBE_REALTIME_END
