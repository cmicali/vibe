//
//  AudioVarispeed.m
//  Vibe
//

#import "AudioVarispeed.h"
#import <Accelerate/Accelerate.h>
#include <simd/simd.h>
#include <stdatomic.h>

static const double kVarispeedZeroCrossings = 64;
static const double kVarispeedCutoff = 22000.0 / 48000.0;
static const double kVarispeedBeta = 15.6;
// The kernel's resolution: a fine table at 512 points per input frame, which
// every polyphase table is read from, and that table's rows per input frame.
// A cubic across four rows gives the kernel at any phase.
static const int kVarispeedFinePoints = 512;
static const int kVarispeedPhases = 128;
// The fader's widest throw, ±16%. The ring and an engage's history are sized
// for it.
static const double kVarispeedMaxRatio = 1.16;

#pragma mark - The kernel

// One stretch of the kernel as a polyphase table.
struct VibeVarispeedTable {
    double stretch;  // the ratio above 1, else 1
    uint32_t half;   // the half-width in input frames: ceil(64 × stretch)
    double rows[];
};

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

// The table for `ratio`: stretched by it above 1. About 0.1 ms; NULL when it
// cannot be allocated. Phase j of kVarispeedPhases is row j + 1, for j from
// −1 to kVarispeedPhases + 1, so the cubic always has four rows. A row holds
// the taps for input frames index − half + 1 through index + half, around a
// position at index + j / kVarispeedPhases.
static VibeVarispeedTable *VibeVarispeedTableCreate(double ratio) {
    const double *fine = VibeVarispeedFineKernel();
    double stretch = MIN(MAX(ratio, 1), kVarispeedMaxRatio);
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

#pragma mark - The stage

// The queue writes the table, the ratio and `wanted`, and keeps `retired`.
// The render owns the rest, and writes `engaged`, `inUse` and the counters
// for the queue to read.
struct VibeVarispeed {
    uint32_t channels;
    uint32_t history;                     // the widest kernel's half-width: the past an engage records
    _Atomic(VibeVarispeedTable *) table;  // the ratio's; NULL until the pitch first leaves zero
    _Atomic(VibeVarispeedTable *) inUse;  // the table the render's last slice used
    VibeVarispeedTable *retired;          // a replaced table the render was still using
    _Atomic double ratio;
    _Atomic int32_t wanted;
    _Atomic int32_t engaged;              // 1 while the converter is in the chain; set at a slice boundary
    // The history ring, of source frames: what the direct path plays while
    // an engage is prepared, then the source pulled ahead while the converter
    // is in the chain. Written only then.
    float *ring[2];
    uint32_t mask;
    uint64_t written;
    uint32_t recorded;                    // frames recorded for the engage; 0 when not preparing one
    uint32_t replayRemaining;             // pulled-ahead frames the direct path still plays from `index`
    // The converter's position, in ring frames: the frame at or before it and
    // the fraction past it. `applied` is where the last slice's ramp ended.
    uint64_t index;
    double fraction;
    double applied;
    _Atomic uint64_t renders;
    _Atomic uint64_t historyWrites;
};

VibeVarispeed *VibeVarispeedCreate(uint32_t channels, uint32_t maxFrames) {
    VibeVarispeed *stage = calloc(1, sizeof(VibeVarispeed));
    if (!stage) {
        return NULL;
    }
    stage->channels = channels < 2 ? 1 : 2;
    stage->history = (uint32_t)ceil(kVarispeedZeroCrossings * kVarispeedMaxRatio);
    atomic_init(&stage->ratio, 1.0);
    // The widest slice at the widest ratio, and the kernel's reach either side.
    uint32_t reach = (uint32_t)ceil(maxFrames * kVarispeedMaxRatio) + 2 * stage->history + 2;
    uint32_t capacity = 256;
    while (capacity < reach) {
        capacity <<= 1;
    }
    stage->ring[0] = calloc((size_t)capacity * 2, sizeof(float));
    if (!stage->ring[0]) {
        free(stage);
        return NULL;
    }
    // TRAP: vDSP_vclr, not memset: clang drops a memset(0) after calloc (AudioVoiceBus's pre-touch).
    vDSP_vclr(stage->ring[0], 1, (vDSP_Length)capacity * 2);
    stage->ring[1] = stage->ring[0] + capacity;
    stage->mask = capacity - 1;
    return stage;
}

void VibeVarispeedFree(VibeVarispeed *stage) {
    if (!stage) {
        return;
    }
    free(atomic_load_explicit(&stage->table, memory_order_relaxed));
    free(stage->retired);
    free(stage->ring[0]);
    free(stage);
}

BOOL VibeVarispeedSetPitch(VibeVarispeed *stage, double percent, VibeVarispeedTable **replaced) {
    *replaced = NULL;
    double ratio = MIN(MAX(1 + percent / 100, 2 - kVarispeedMaxRatio), kVarispeedMaxRatio);
    VibeVarispeedTable *old = atomic_load_explicit(&stage->table, memory_order_relaxed);
    if (percent != 0 && (!old || old->stretch != MAX(ratio, 1))) {
        VibeVarispeedTable *table = VibeVarispeedTableCreate(ratio);
        if (!table) {
            return NO;
        }
        atomic_store_explicit(&stage->table, table, memory_order_seq_cst);
        *replaced = old;
    }
    atomic_store_explicit(&stage->ratio, ratio, memory_order_relaxed);
    // After the table: a render that sees `wanted` sees a table.
    atomic_store_explicit(&stage->wanted, percent != 0, memory_order_seq_cst);
    return YES;
}

void VibeVarispeedRetire(VibeVarispeed *stage, VibeVarispeedTable *replaced) {
    VibeVarispeedTable *inUse = atomic_load_explicit(&stage->inUse, memory_order_relaxed);
    VibeVarispeedTable *candidates[2] = { stage->retired, replaced };
    stage->retired = NULL;
    for (int i = 0; i < 2; i++) {
        if (candidates[i] == inUse) {
            stage->retired = candidates[i];
        }
        else {
            free(candidates[i]);
        }
    }
}

BOOL VibeVarispeedWanted(const VibeVarispeed *stage) {
    return atomic_load_explicit(&stage->wanted, memory_order_relaxed) != 0;
}

BOOL VibeVarispeedEngaged(const VibeVarispeed *stage) {
    return atomic_load_explicit(&stage->engaged, memory_order_relaxed) != 0;
}

double VibeVarispeedRatio(const VibeVarispeed *stage) {
    return atomic_load_explicit(&stage->ratio, memory_order_relaxed);
}

double VibeVarispeedDelayFrames(const VibeVarispeed *stage) {
    VibeVarispeedTable *table = atomic_load_explicit(&stage->table, memory_order_relaxed);
    return VibeVarispeedWanted(stage) && table ? table->half / VibeVarispeedRatio(stage) : 0;
}

uint64_t VibeVarispeedRenders(const VibeVarispeed *stage) {
    return atomic_load_explicit(&stage->renders, memory_order_relaxed);
}

uint64_t VibeVarispeedHistoryWrites(const VibeVarispeed *stage) {
    return atomic_load_explicit(&stage->historyWrites, memory_order_relaxed);
}

#pragma mark - The audio thread

VIBE_REALTIME_CHECKED_BEGIN
// The last output's position past the index, read `half` frames beyond it.
// One more frame is margin, since the conversion sums the steps one at a time.
static uint64_t VibeVarispeedReach(const VibeVarispeedTable *table, double fraction, double from, double to,
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
// wrap. A mono stage reads its one channel twice, into its one buffer.
static void VibeVarispeedConvert(VibeVarispeed *stage, const VibeVarispeedTable *table, double from, double to, UInt32 frames,
                                 float *const out[2]) CA_REALTIME_API {
    double slope = (to - from) / frames;
    uint32_t half = table->half, taps = 2 * half, capacity = stage->mask + 1;
    const float *left = stage->ring[0], *right = stage->ring[stage->channels - 1];
    uint64_t at = stage->index;
    double past = stage->fraction;
    for (UInt32 n = 0; n < frames; n++) {
        double phase = past * kVarispeedPhases, mu = phase - (int)phase;
        const double *row = table->rows + (size_t)(int)phase * taps;
        double m1 = mu - 1, m2 = mu - 2, p1 = mu + 1;
        simd_double4 cubic = { -mu * m1 * m2 * (1.0 / 6), p1 * m1 * m2 * 0.5, -p1 * mu * m2 * 0.5, p1 * mu * m1 * (1.0 / 6) };
        uint32_t start = (uint32_t)(at - half + 1) & stage->mask;
        uint32_t first = taps < capacity - start ? taps : capacity - start;
        simd_double2 sum = VibeVarispeedTaps(row, taps, cubic, first, left + start, right + start)
                + VibeVarispeedTaps(row + first, taps, cubic, taps - first, left, right);
        out[0][n] = (float)sum.x;
        out[1][n] = (float)sum.y;
        past += from + slope * (n + 1);
        uint64_t whole = (uint64_t)past;
        at += whole;
        past -= (double)whole;
    }
    stage->index = at;
    stage->fraction = past;
}

// `frames` between the ring from frame `at` and `outside`, into the ring or
// out of it. The ring holds more than a slice.
static void VibeVarispeedRingCopy(VibeVarispeed *stage, uint64_t at, float *const outside[2], UInt32 frames,
                                  BOOL intoRing) CA_REALTIME_API {
    uint32_t capacity = stage->mask + 1, start = (uint32_t)at & stage->mask;
    UInt32 first = frames < capacity - start ? frames : capacity - start;
    for (uint32_t c = 0; c < stage->channels; c++) {
        if (intoRing) {
            memcpy(stage->ring[c] + start, outside[c], first * sizeof(float));
            memcpy(stage->ring[c], outside[c] + first, (frames - first) * sizeof(float));
        }
        else {
            memcpy(outside[c], stage->ring[c] + start, first * sizeof(float));
            memcpy(outside[c] + first, stage->ring[c], (frames - first) * sizeof(float));
        }
    }
}

// The source into the ring up to `until`, in ring frames: the converter's input.
static OSStatus VibeVarispeedPull(VibeVarispeed *stage, VibeVarispeedInputProc input, void *context, const AudioTimeStamp *stamp,
                                  uint64_t until) CA_REALTIME_API {
    uint32_t capacity = stage->mask + 1;
    OSStatus status = noErr;
    while (stage->written < until) {
        uint32_t at = (uint32_t)stage->written & stage->mask;
        UInt32 count = until - stage->written < capacity - at ? (UInt32)(until - stage->written) : capacity - at;
        UInt32 bytes = count * (UInt32)sizeof(float);
        VibeStereoBufferList span = { stage->channels, {{ 1, bytes, stage->ring[0] + at }, { 1, bytes, stage->ring[1] + at }} };
        OSStatus pulled = input(context, stamp, count, (AudioBufferList *)&span);
        if (pulled != noErr) {
            status = pulled;
        }
        stage->written += count;
        atomic_fetch_add_explicit(&stage->historyWrites, 1, memory_order_relaxed);
    }
    return status;
}

// The converter's slice, the ratio ramped across it from where the last
// slice ended to the queue's, so a drag glides instead of stepping. Its
// kernel is stretched for both ends of the ramp. Down, the table in use is
// stretched for where the ramp starts; the target's would let that start
// fold back. Up, a ratio the table has not caught up with waits for the next
// slice. The source is pulled into the ring first, as far as the slice reads.
static OSStatus VibeVarispeedConvertSlice(VibeVarispeed *stage, VibeVarispeedInputProc input, void *context,
                                          const AudioTimeStamp *stamp, UInt32 frames, float *const out[2]) CA_REALTIME_API {
    VibeVarispeedTable *table = atomic_load_explicit(&stage->table, memory_order_acquire);
    double from = stage->applied, to = atomic_load_explicit(&stage->ratio, memory_order_relaxed);
    if (table->stretch < from) {
        table = atomic_load_explicit(&stage->inUse, memory_order_relaxed);
    }
    if (to > table->stretch) {
        to = table->stretch;
    }
    atomic_store_explicit(&stage->inUse, table, memory_order_relaxed);
    OSStatus status = VibeVarispeedPull(stage, input, context, stamp,
                                        stage->index + VibeVarispeedReach(table, stage->fraction, from, to, frames));
    VibeVarispeedConvert(stage, table, from, to, frames, out);
    stage->applied = to;
    atomic_fetch_add_explicit(&stage->renders, 1, memory_order_relaxed);
    return status;
}

OSStatus VibeVarispeedRender(VibeVarispeed *stage, VibeVarispeedInputProc input, void *context, const AudioTimeStamp *stamp,
                             UInt32 frames, AudioBufferList *out) CA_REALTIME_API {
    // The caller checked the buffers; the analyzer cannot see that.
    float *channels[2] = { out->mBuffers[0].mData, out->mBuffers[stage->channels - 1].mData };
    if (!channels[0] || !channels[1]) {
        return noErr;
    }
    BOOL wanted = atomic_load_explicit(&stage->wanted, memory_order_seq_cst) != 0;
    if (!wanted && atomic_load_explicit(&stage->engaged, memory_order_relaxed)) {
        // Out of the chain without a skip: the frames the converter pulled
        // past its position play from the ring first, its fraction rounded.
        stage->index += stage->fraction >= 0.5 ? 1 : 0;
        stage->fraction = 0;
        stage->replayRemaining = (uint32_t)(stage->written - stage->index);
        atomic_store_explicit(&stage->engaged, 0, memory_order_release);
    }
    if (atomic_load_explicit(&stage->engaged, memory_order_relaxed)) {
        return VibeVarispeedConvertSlice(stage, input, context, stamp, frames, channels);
    }
    UInt32 replay = stage->replayRemaining < frames ? stage->replayRemaining : frames;
    OSStatus status = noErr;
    if (replay) {
        VibeVarispeedRingCopy(stage, stage->index, channels, replay, NO);
        stage->index += replay;
        stage->replayRemaining -= replay;
    }
    if (replay < frames) {
        VibeStereoBufferList rest = VibeStereoBufferListSpan(out, stage->channels, replay, frames - replay);
        status = input(context, stamp, frames - replay, (AudioBufferList *)&rest);
    }
    if (!wanted) {
        stage->recorded = 0;
        return status;
    }
    // Preparing the engage: what was heard is the kernel's past. Not while a
    // replay is left, since the source is already past its frames. Then the
    // converter joins at the next source frame, its ratio ramped from 1.
    VibeVarispeedRingCopy(stage, stage->written, channels, frames, YES);
    stage->written += frames;
    stage->recorded += frames;
    atomic_fetch_add_explicit(&stage->historyWrites, 1, memory_order_relaxed);
    if (!stage->replayRemaining && stage->recorded >= stage->history) {
        stage->index = stage->written;
        stage->fraction = 0;
        stage->applied = 1;
        atomic_store_explicit(&stage->engaged, 1, memory_order_release);
    }
    return status;
}
VIBE_REALTIME_END
