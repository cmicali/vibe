//
//  AudioWaveform.mm
//  Vibe
//

#import "AudioWaveform.h"

#include <algorithm>
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

float AudioWaveform::getMaxMeanSquare(NSUInteger columns) {
    float loudest = 0;
    for (NSUInteger i = 0; i < columns; i++) {
        float meanSquare = getChunkAtIndex(i, columns).getMeanSquare();
        if (meanSquare > loudest) {
            loudest = meanSquare;
        }
    }
    return loudest;
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

AudioWaveformCacheChunk AudioWaveform::getChunkAtIndex(NSUInteger index, NSUInteger size)  {
    AudioWaveformCacheChunk result;
    // A failed calloc leaves chunks NULL and numChunks 0; see the
    // constructors. Guard here so that a renderer read cannot dereference NULL.
    if (chunks == nullptr || numChunks == 0) return result;
    if (index >= size) return result;
    if (size == numChunks) { return chunks[index]; }
    NSUInteger startIndex, numChunksToCombine;
    getColumnRange(index, size, &startIndex, &numChunksToCombine);
    if (numChunksToCombine == 1) {
        return chunks[startIndex];
    }
    if (numChunksToCombine < 16) {
        // vDSP setup overhead dominates for tiny strided ranges, so use a
        // plain loop.
        result = chunks[startIndex];
        for (NSUInteger i = 1; i < numChunksToCombine; i++) {
            result.merge(&chunks[startIndex + i]);
        }
        return result;
    }
    // chunks[] holds float[4] groups: min, max, sum of squares, frame count.
    // Stride-4 vDSP: the minimum of the minima, the maximum of the maxima, and
    // plain sums of the two energy fields.
    float *base = reinterpret_cast<float*>(&chunks[startIndex]);
    float minVal, maxVal, sumSquares, frameCount;
    vDSP_minv(base,     4, &minVal, numChunksToCombine);
    vDSP_maxv(base + 1, 4, &maxVal, numChunksToCombine);
    vDSP_sve(base + 2,  4, &sumSquares, numChunksToCombine);
    vDSP_sve(base + 3,  4, &frameCount, numChunksToCombine);
    result.set(minVal, maxVal, sumSquares, frameCount);
    return result;
}

void AudioWaveform::getBandMeanSquares(NSUInteger index, NSUInteger size, float* meanSquares) {
    std::fill(meanSquares, meanSquares + kAudioWaveformBandCount, 0.0f);
    if (bandSums == nullptr || numChunks == 0 || index >= size) return;
    NSUInteger start, count;
    getColumnRange(index, size, &start, &count);
    float frames = 0;
    float sums[kAudioWaveformBandCount] = {};
    for (NSUInteger i = start; i < start + count; i++) {
        frames += chunks[i].getFrameCount();
        for (NSUInteger b = 0; b < kAudioWaveformBandCount; b++) {
            sums[b] += bandSums[i * kAudioWaveformBandCount + b];
        }
    }
    for (NSUInteger b = 0; frames > 0 && b < kAudioWaveformBandCount; b++) {
        meanSquares[b] = sums[b] / frames;
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

// The RBJ cookbook's 2nd-order Butterworth (Q = 1/√2), as vDSP_biquad wants a
// section: b0, b1, b2, a1, a2, normalized by a0.
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
    section[3] = -2 * cosw / a0;
    section[4] = (1 - alpha) / a0;
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
        a1[lane] = -sections[lane][3];
        a2[lane] = -sections[lane][4];
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
        waveform->getBandMeanSquares(i, numChunks, &meanSquares[i * kAudioWaveformBandCount]);
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
    return copy;
}

- (void)dealloc {
    if (self.waveform) {
        delete self.waveform;
    }
}


@end
