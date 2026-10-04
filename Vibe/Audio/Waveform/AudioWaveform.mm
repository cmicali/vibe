//
//  AudioWaveform.mm
//  Vibe
//

#import "AudioWaveform.h"

#include <algorithm>
#include <cfloat>
#include <memory>
#include <vector>

#define NUM_CHUNKS     (4096*2)

void AudioWaveform::allocate(NSUInteger count, bool withBands) {
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(count, sizeof(AudioWaveformCacheChunk)));
    this->bandSums = withBands && this->chunks
            ? static_cast<float*>(calloc(count, kBandBytes)) : nullptr;
    // A NULL allocation would make setChunkAtIndex dereference NULL, whereas a
    // zero count turns every access into a safe no-op. Bands that would not
    // allocate leave a waveform without them.
    this->numChunks = this->chunks ? count : 0;
}

AudioWaveform::AudioWaveform(bool withBands) {
    allocate(NUM_CHUNKS, withBands);
    complete = false;
}

AudioWaveform::AudioWaveform(NSUInteger numChunks, const void* chunks, const void* bandSums) {
    allocate(numChunks, bandSums != nullptr);
    this->complete = true;
    if (this->chunks && chunks) {
        memcpy(this->chunks, chunks, this->getNumBytes());
        if (this->bandSums) {
            memcpy(this->bandSums, bandSums, this->getNumBandBytes());
        }
    } else {
        this->numChunks = 0;
    }
}

AudioWaveform::AudioWaveform(const AudioWaveform& other)
        : AudioWaveform(other.numChunks, other.chunks, other.bandSums) {
    this->complete = other.complete;
}

AudioWaveform::~AudioWaveform() {
    free(this->chunks);
    free(this->bandSums);
}

// Column i combines [start(i), start(i+1)), so consecutive columns tile the
// source exactly. A floored fixed width skips a source chunk on most steps of
// a fractional ratio, which makes transient peaks vanish at some view widths.
// In bounds by construction: end = numChunks*(index+1)/size and index < size,
// so start + count <= numChunks; a column finer than a chunk repeats it.
void AudioWaveform::getColumnRange(NSUInteger index, NSUInteger size, NSUInteger* start, NSUInteger* count) {
    NSUInteger startIndex = numChunks * index / size;
    NSUInteger endIndex = numChunks * (index + 1) / size;
    *start = startIndex;
    *count = endIndex > startIndex ? endIndex - startIndex : 1;
}

// A chunk as one vector: min, max, sum of squares, frame count.
static inline simd_float4 AudioWaveformChunkValues(const AudioWaveformCacheChunk* chunk) {
    return *reinterpret_cast<const simd_packed_float4*>(chunk);
}

AudioWaveformCacheChunk AudioWaveform::getChunkAtIndex(NSUInteger index, NSUInteger size)  {
    AudioWaveformCacheChunk result;
    // A failed calloc leaves chunks NULL and numChunks 0; see the
    // constructors. Guard here so that a renderer read cannot dereference NULL.
    if (chunks == nullptr || numChunks == 0) return result;
    if (index >= size) return result;
    if (size == numChunks) { return chunks[index]; }
    NSUInteger startIndex, numChunksToCombine;
    getColumnRange(index, size, &startIndex, &numChunksToCombine);
    // The minimum of the minima, the maximum of the maxima and plain sums of
    // the two energy fields, every field in one pass.
    simd_float4 lows = AudioWaveformChunkValues(&chunks[startIndex]), highs = lows, sums = lows;
    for (NSUInteger i = 1; i < numChunksToCombine; i++) {
        simd_float4 values = AudioWaveformChunkValues(&chunks[startIndex + i]);
        lows = simd_min(lows, values);
        highs = simd_max(highs, values);
        sums += values;
    }
    result.set(lows[0], highs[1], sums[2], sums[3]);
    return result;
}

void AudioWaveform::getBandMeanSquares(NSUInteger index, float* meanSquares) {
    float frames = bandSums && index < numChunks ? chunks[index].getFrameCount() : 0;
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        meanSquares[b] = frames > 0 ? bandSums[index * kAudioWaveformBandCount + b] / frames : 0;
    }
}

// Cells a quarter bar long, their edges exact in the chunks, and a bar-long
// window at every cell: a bar's own, and the two either side that the reach
// compares it with. Without reach a bar is one cell and its own window.
void AudioWaveform::getBarMeanSquares(NSUInteger size, float reach, float* meanSquares, float* bandMeanSquares) {
    // Silence where there is nothing to read: no chunks, or the bands of a
    // waveform without them.
    bool empty = chunks == nullptr || numChunks == 0 || size == 0;
    bool wantsBands = bandMeanSquares && bandSums && !empty;
    if (meanSquares && empty) std::fill(meanSquares, meanSquares + size, 0.0f);
    if (bandMeanSquares && !wantsBands) {
        std::fill(bandMeanSquares, bandMeanSquares + size * kAudioWaveformBandCount, 0.0f);
    }
    if (empty || !(meanSquares || wantsBands)) return;

    // One plane of cells per value — the frames, the mix's squares, the three
    // bands' — with the half bar of nothing either side that the first and
    // last bars' windows reach into.
    enum { kFrames, kMix, kBands, kPlaneCount = kBands + kAudioWaveformBandCount };
    bool slides = reach > 0;
    NSUInteger cellsPerBar = slides ? 4 : 1, padding = cellsPerBar / 2;
    NSUInteger numCells = size * cellsPerBar, planeLength = numCells + 2 * padding;
    NSUInteger numWindows = planeLength - cellsPerBar + 1;
    std::unique_ptr<float[]> scratch(new float[planeLength * kPlaneCount + numWindows * 2]);
    float* cell[kPlaneCount];
    for (NSUInteger plane = 0; plane < kPlaneCount; plane++) {
        float* padded = scratch.get() + plane * planeLength;
        memset(padded, 0, padding * sizeof(float));
        memset(padded + padding + numCells, 0, padding * sizeof(float));
        cell[plane] = padded + padding;
    }
    float* perFrame = scratch.get() + planeLength * kPlaneCount;
    float* windows = perFrame + numWindows;

    // An edge is chunk + part / numCells, stepped in integers so that every
    // cell's edges are exact.
    NSUInteger wholeStep = numChunks / numCells, partStep = numChunks % numCells;
    float partScale = 1.0f / (float)numCells;
    NSUInteger chunk = 0, part = 0;
    float startShare = 0;
    for (NSUInteger j = 0; j < numCells; j++) {
        NSUInteger endChunk = chunk + wholeStep, endPart = part + partStep;
        if (endPart >= numCells) {
            endPart -= numCells;
            endChunk++;
        }
        float endShare = (float)endPart * partScale;
        // The first chunk's share, the whole chunks between, then the last's:
        // none of it when the edge is the chunk's own, which past the last
        // chunk is not there to read.
        float firstShare = endChunk == chunk ? endShare - startShare : 1 - startShare;
        float lastShare = endChunk == chunk ? 0 : endShare;
        NSUInteger lastChunk = lastShare > 0 ? endChunk : chunk;
        simd_float4 sums = AudioWaveformChunkValues(&chunks[chunk]) * firstShare
                + AudioWaveformChunkValues(&chunks[lastChunk]) * lastShare;
        for (NSUInteger i = chunk + 1; i < endChunk; i++) {
            sums += AudioWaveformChunkValues(&chunks[i]);
        }
        cell[kMix][j] = sums[2];
        cell[kFrames][j] = sums[3];
        if (wantsBands) {
            const float* first = bandSums + chunk * kAudioWaveformBandCount;
            const float* last = bandSums + lastChunk * kAudioWaveformBandCount;
            float low = first[0] * firstShare + last[0] * lastShare;
            float mid = first[1] * firstShare + last[1] * lastShare;
            float high = first[2] * firstShare + last[2] * lastShare;
            for (const float* band = first + kAudioWaveformBandCount; band < bandSums + endChunk * kAudioWaveformBandCount;
                 band += kAudioWaveformBandCount) {
                low += band[0];
                mid += band[1];
                high += band[2];
            }
            cell[kBands][j] = low;
            cell[kBands + 1][j] = mid;
            cell[kBands + 2][j] = high;
        }
        chunk = endChunk;
        part = endPart;
        startShare = endShare;
    }

    // A window is four cells. One division a window, shared by the mix and
    // the bands; a window no frame reaches divides nothing by the least
    // float, which is silence.
    auto sumWindows = [&](NSUInteger plane, float* sums) {
        const float* padded = cell[plane] - padding;
        vDSP_vadd(padded, 1, padded + 1, 1, sums, 1, numWindows);
        vDSP_vadd(padded + 2, 1, sums, 1, sums, 1, numWindows);
        vDSP_vadd(padded + 3, 1, sums, 1, sums, 1, numWindows);
    };
    auto fillBars = [&](NSUInteger plane, float* out, NSUInteger stride) {
        if (!slides) {
            vDSP_vmul(cell[plane], 1, perFrame, 1, out, (vDSP_Stride)stride, size);
            return;
        }
        sumWindows(plane, windows);
        vDSP_vmul(windows, 1, perFrame, 1, windows, 1, numWindows);
        // The five around a bar start at its first cell's index, its own in
        // the middle.
        for (NSUInteger i = 0; i < size; i++) {
            const float* around = windows + i * cellsPerBar;
            float own = around[2];
            float loudest = fmaxf(fmaxf(fmaxf(around[0], around[1]), fmaxf(around[3], around[4])), own);
            out[i * stride] = own + reach * (loudest - own);
        }
    };
    const float least = FLT_MIN, one = 1;
    if (slides) sumWindows(kFrames, perFrame);
    vDSP_vthr(slides ? perFrame : cell[kFrames], 1, &least, perFrame, 1, numWindows);
    vDSP_svdiv(&one, perFrame, 1, perFrame, 1, numWindows);
    if (meanSquares) fillBars(kMix, meanSquares, 1);
    for (NSUInteger b = 0; wantsBands && b < kAudioWaveformBandCount; b++) {
        fillBars(kBands + b, bandMeanSquares + b, kAudioWaveformBandCount);
    }
}

void AudioWaveform::setBandMeanSquares(const float* meanSquares) {
    if (!bandSums) {
        bandSums = static_cast<float*>(calloc(numChunks, kBandBytes));
    }
    for (NSUInteger i = 0; bandSums && i < numChunks; i++) {
        float frames = chunks[i].getFrameCount();
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            bandSums[i * kAudioWaveformBandCount + b] = meanSquares[i * kAudioWaveformBandCount + b] * frames;
        }
    }
}

void AudioWaveform::copyChunk(NSUInteger from, NSUInteger to) {
    if (from >= numChunks || to >= numChunks) return;
    chunks[to] = chunks[from];
    if (bandSums) {
        memmove(&bandSums[to * kAudioWaveformBandCount], &bandSums[from * kAudioWaveformBandCount], kBandBytes);
    }
}

// 2nd-order Butterworth crossovers at the handovers cdj3k-mods measured off a
// CDJ-3000's 3-band display: wide ones, at 280 Hz low and mid still answer
// almost equally, which is a shallow crossover's shape. Mid is the low
// crossover's highpass into the high one's lowpass.
static const double kAudioWaveformLowCrossoverHz = 300;
static const double kAudioWaveformHighCrossoverHz = 2500;

// The RBJ cookbook's 2nd-order Butterworth (Q = 1/√2), normalized by a0: b0,
// b1, b2, then the feedback negated, as direct form I adds it.
static void AudioWaveformButterworthSection(double cutoffHz, double sampleRate, bool highpass,
                                            double *section) {
    double w = 2 * M_PI * cutoffHz / sampleRate;
    double cosw = cos(w);
    double alpha = sin(w) / (2 * M_SQRT1_2);
    double a0 = 1 + alpha;
    double edge = highpass ? (1 + cosw) / 2 : (1 - cosw) / 2;
    section[0] = edge / a0;
    section[1] = (highpass ? -2 : 2) * edge / a0;
    section[2] = edge / a0;
    section[3] = 2 * cosw / a0;
    section[4] = -(1 - alpha) / a0;
}

AudioWaveformBandSplit::AudioWaveformBandSplit(double sampleRate) {
    double sections[4][5];
    AudioWaveformButterworthSection(kAudioWaveformLowCrossoverHz, sampleRate, false, sections[0]);
    AudioWaveformButterworthSection(kAudioWaveformLowCrossoverHz, sampleRate, true, sections[1]);
    AudioWaveformButterworthSection(kAudioWaveformHighCrossoverHz, sampleRate, false, sections[2]);
    AudioWaveformButterworthSection(kAudioWaveformHighCrossoverHz, sampleRate, true, sections[3]);
    for (int lane = 0; lane < 4; lane++) {
        b0[lane] = sections[lane][0];
        b1[lane] = sections[lane][1];
        b2[lane] = sections[lane][2];
        a1[lane] = sections[lane][3];
        a2[lane] = sections[lane][4];
    }
}

// The four sections run side by side, so a sample costs one section's
// latency: mid's lowpass takes its highpass's output from two samples back,
// which leaves no lane waiting on another within a sample, and direct form I
// leaves one FMA on each recurrence. vDSP_biquad runs a setup's sections one
// after another, at 2.6x the cost. The mid band lags the others by two
// samples, a shift no chunk can see. Double, since a 300 Hz pole at 352.8 kHz
// sits close enough to the unit circle that float's rounding shows in the
// energies.
void AudioWaveformBandSplit::addSumSquares(const float* mono, NSUInteger numFrames, float* sums) {
    // Locals, so the stores through sums cannot alias the state.
    simd_double4 x1 = this->x1, x2 = this->x2, y1 = this->y1, y2 = this->y2;
    simd_double4 squares = 0;
    for (NSUInteger i = 0; i < numFrames; i++) {
        double x = mono[i];
        simd_double4 in = {x, x, y2[1], x};
        simd_double4 y = a1 * y1 + (b0 * in + b1 * x1 + b2 * x2 + a2 * y2);
        squares += y * y;
        x2 = x1;
        x1 = in;
        y2 = y1;
        y1 = y;
    }
    // A corrupt file's NaN or Inf stays in a section's state forever: reset
    // it, so the band loses this slice rather than the rest of the file.
    for (int lane = 0; lane < 4; lane++) {
        if (!std::isfinite(x1[lane] + x2[lane] + y1[lane] + y2[lane])) {
            x1[lane] = x2[lane] = y1[lane] = y2[lane] = 0;
        }
    }
    this->x1 = x1;
    this->x2 = x2;
    this->y1 = y1;
    this->y2 = y2;
    const int bandLanes[kAudioWaveformBandCount] = {0, 2, 3};
    for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
        if (std::isfinite(squares[bandLanes[b]])) sums[b] += (float)squares[bandLanes[b]];
    }
}

// See the declaration in AudioWaveform.h.
const int kCodableAudioWaveformVersion = 5;

// The archive has no checksum, so a bit-rotted entry can decode non-finite
// floats, which would poison the renderers' geometry on every play until the
// entry ages out.
// TRAP: decodeBytesForKey: returns an unaligned pointer into the unarchiver's
// buffer, so reading it through a float pointer is UB and lets the vectorizer
// emit alignment-faulting loads. memcpy each value into an aligned local.
static BOOL VibeArchivedFloatsAreFinite(const void *data, NSUInteger length) {
    const char *bytes = (const char *)data;
    for (NSUInteger i = 0; i < length / sizeof(float); i++) {
        float value;
        memcpy(&value, bytes + i * sizeof(float), sizeof(value));
        if (!std::isfinite(value)) {
            return NO;
        }
    }
    return YES;
}

// The bands are archived as each chunk's mean squares in float16, half the
// bytes of the float32 sums held in memory. Means, not sums: a long chunk's
// sum — a two-hour mix at 192 kHz puts some 170,000 frames in one — overflows
// float16's 65,504, the finite check refuses it, and that file decodes again
// on every play.
static void VibeArchiveBands(NSCoder *coder, AudioWaveform *waveform) {
    NSUInteger numChunks = waveform->getNumChunks();
    vImagePixelCount count = numChunks * kAudioWaveformBandCount;
    std::vector<float> meanSquares(count);
    for (NSUInteger i = 0; i < numChunks; i++) {
        waveform->getBandMeanSquares(i, &meanSquares[i * kAudioWaveformBandCount]);
    }
    std::vector<uint16_t> halves(count);
    vImage_Buffer from = {meanSquares.data(), 1, count, count * sizeof(float)};
    vImage_Buffer to = {halves.data(), 1, count, count * sizeof(uint16_t)};
    vImageConvert_PlanarFtoPlanar16F(&from, &to, kvImageNoFlags);
    [coder encodeBytes:(const uint8_t *)halves.data() length:count * sizeof(uint16_t) forKey:@"bands"];
}

// Whole bands only: bad ones degrade to none rather than reject the waveform,
// since the next request for them decodes them again.
static void VibeRestoreArchivedBands(NSCoder *coder, AudioWaveform *waveform) {
    vImagePixelCount count = waveform->getNumChunks() * kAudioWaveformBandCount;
    NSUInteger length;
    const void *bytes = [coder decodeBytesForKey:@"bands" returnedLength:&length];
    if (!bytes || count == 0 || length != count * sizeof(uint16_t)) {
        return;
    }
    // The unaligned pointer again (see VibeArchivedFloatsAreFinite).
    std::vector<uint16_t> halves(count);
    memcpy(halves.data(), bytes, length);
    std::vector<float> meanSquares(count);
    vImage_Buffer from = {halves.data(), 1, count, count * sizeof(uint16_t)};
    vImage_Buffer to = {meanSquares.data(), 1, count, count * sizeof(float)};
    vImageConvert_Planar16FtoPlanarF(&from, &to, kvImageNoFlags);
    for (float meanSquare : meanSquares) {
        if (!std::isfinite(meanSquare) || meanSquare < 0) {
            return;
        }
    }
    waveform->setBandMeanSquares(meanSquares.data());
}

@implementation CodableAudioWaveform

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    [coder encodeObject:@(self.waveform->getNumChunks()) forKey:@"numChunks"];
    [coder encodeBytes:(const uint8_t*)self.waveform->getBytes() length:self.waveform->getNumBytes() forKey:@"chunks"];
    if (self.waveform->hasBands()) {
        VibeArchiveBands(coder, self.waveform);
    }
    [coder encodeFloat:self.bpm forKey:@"bpm"];
    // As an object, not encodeInteger: an absent integer decodes as 0, which
    // as a key means C major, whereas an absent object is unambiguously nil.
    [coder encodeObject:@(self.key) forKey:@"key"];
    [coder encodeBool:self.bpmAnalyzed forKey:@"bpmAnalyzed"];
    [coder encodeBool:self.keyAnalyzed forKey:@"keyAnalyzed"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // A missing or mismatched version, or a malformed payload, is
        // rejected; the waveform regenerates.
        if ([coder decodeIntForKey:@"version"] != kCodableAudioWaveformVersion) {
            return nil;
        }
        // Validate the class before messaging. A bit-rotted entry that decodes
        // numChunks as some other object would otherwise crash with an
        // unrecognized selector inside the decode, before the payload checks
        // below ever ran.
        NSNumber *numChunksValue = [coder decodeObjectForKey:@"numChunks"];
        if (![numChunksValue isKindOfClass:[NSNumber class]]) {
            return nil;
        }
        NSUInteger numChunks = [numChunksValue unsignedIntegerValue];
        NSUInteger length;
        const void* data = [coder decodeBytesForKey:@"chunks" returnedLength:&length];
        // The encoder only ever writes NUM_CHUNKS. Requiring exact equality
        // rejects corrupt and bit-rotted entries, and removes the unchecked
        // multiply overflow the length comparison would otherwise carry.
        if (!data || numChunks != NUM_CHUNKS || length != numChunks * sizeof(AudioWaveformCacheChunk)) {
            return nil;
        }
        if (!VibeArchivedFloatsAreFinite(data, length)) {
            return nil;
        }
        self.waveform = new AudioWaveform(numChunks, data);
        VibeRestoreArchivedBands(coder, self.waveform);
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = std::isfinite(bpm) && bpm > 0 ? bpm : 0;
        // Like bpm, a bad key degrades to "unknown" rather than rejecting the
        // entry — it is not a reason to throw away good waveform data. Absent
        // decodes nil, and nil falls to -1, never C major.
        id keyValue = [coder decodeObjectForKey:@"key"];
        NSInteger key = [keyValue isKindOfClass:[NSNumber class]] ? [keyValue integerValue] : -1;
        self.key = (key >= 0 && key < 24) ? key : -1;
        self.bpmAnalyzed = ![coder containsValueForKey:@"bpmAnalyzed"] || [coder decodeBoolForKey:@"bpmAnalyzed"];
        self.keyAnalyzed = ![coder containsValueForKey:@"keyAnalyzed"] || [coder decodeBoolForKey:@"keyAnalyzed"];
    }
    return self;
}

- (id)initWithWaveform:(AudioWaveform *)waveform {
    self = [super init];
    if (self) {
        self.waveform = waveform;
        self.key = -1; // 0 is C major; see the property comment
    }
    return self;
}

- (CodableAudioWaveform *)snapshot {
    if (!self.waveform) {
        return nil;
    }
    CodableAudioWaveform *copy = [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform(*self.waveform)];
    copy.bpm = self.bpm;
    copy.key = self.key;
    copy.bpmAnalyzed = self.bpmAnalyzed;
    copy.keyAnalyzed = self.keyAnalyzed;
    return copy;
}

- (void)dealloc {
    if (self.waveform) {
        delete self.waveform;
    }
}


@end
