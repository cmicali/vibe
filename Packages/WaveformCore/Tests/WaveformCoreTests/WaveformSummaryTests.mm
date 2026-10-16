//
//  WaveformSummaryTests.mm
//  VibeTests
//
//  WaveformCore's summary: the builder, the exact column reads, the windowed
//  energy reads, the tent, the references and the archive.
//

#import <XCTest/XCTest.h>

#include "WaveformSummary.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <random>
#include <vector>

using wavecore::Column;
using wavecore::Summary;
using wavecore::SummaryBuilder;

@interface WaveformSummaryTests : XCTestCase
@end

// One frame a bin: bin i carries mean square i, bands i, 2i and 3i, and
// peaks of ±i, so a read reports which bins it covered.
static std::unique_ptr<Summary> VibeRampSummary(NSUInteger count) {
    auto summary = std::make_unique<Summary>(1, 1, true, 44100);
    for (NSUInteger i = 0; i < count; i++) {
        float lo = -(float)i, hi = (float)i;
        double bands[wavecore::kBandCount] = {(double)i, (double)i * 2, (double)i * 3};
        summary->appendBin(&lo, &hi, (double)i, bands, 1);
    }
    summary->markComplete();
    return summary;
}

// Bins of binFrames frames with the given mean squares and peaks of ±1.
static std::unique_ptr<Summary> VibeLevelSummary(const std::vector<float> &meanSquares, uint32_t binFrames) {
    auto summary = std::make_unique<Summary>(binFrames, 1, false, 44100);
    for (float meanSquare : meanSquares) {
        float lo = -1, hi = 1;
        summary->appendBin(&lo, &hi, (double)meanSquare * binFrames, nullptr, binFrames);
    }
    summary->markComplete();
    return summary;
}

@implementation WaveformSummaryTests

#pragma mark - Bins

// Short files take finer bins, so even a one-shot draws at sample detail.
- (void)testShortFilesTakeFinerBins {
    XCTAssertEqual(wavecore::BinFramesForLength(60 * 44100), 256u);
    XCTAssertEqual(wavecore::BinFramesForLength(8192 * 256), 256u);
    XCTAssertEqual(wavecore::BinFramesForLength(8192 * 256 - 1), 128u);
    XCTAssertEqual(wavecore::BinFramesForLength(4410), 1u);
    XCTAssertEqual(wavecore::BinFramesForLength(0), 256u, @"an unknown length takes the full bin");
}

#pragma mark - The builder

- (void)testBuilderKeepsEachBinsExtremesAndEnergy {
    // Stereo in, the mix's peaks kept: Vibe draws one lane.
    std::vector<float> interleaved = {0.5f, -0.5f, 0.25f, 0.75f, -1.0f, 0.0f};
    std::vector<float> mono = {0.0f, 0.5f, -0.5f};
    SummaryBuilder builder(2, 1, false, 3, 44100);
    builder.append(interleaved.data(), mono.data(), 3);
    auto summary = builder.finish(true);
    XCTAssertEqual(summary->channels(), 1u);
    XCTAssertEqual(summary->binFrames(), 1u);
    Column all = summary->column(0, 3);
    XCTAssertEqual(all.lo, -0.5f);
    XCTAssertEqual(all.hi, 0.5f);
    XCTAssertEqualWithAccuracy(all.meanSquare(), (0.0f + 0.25f + 0.25f) / 3, 1e-6);
    XCTAssertEqual(all.frames, 3);

    // Two stored channels keep each one's own.
    SummaryBuilder stereo(2, 2, false, 3, 44100);
    stereo.append(interleaved.data(), mono.data(), 3);
    auto both = stereo.finish(true);
    XCTAssertEqual(both->channels(), 2u);
    XCTAssertEqual(both->column(0, 3, 0).hi, 0.5f);
    XCTAssertEqual(both->column(0, 3, 1).lo, -0.5f);
    XCTAssertEqual(both->column(0, 3, 1).hi, 0.75f);
    XCTAssertEqual(both->column(0, 3).hi, 0.75f, @"the union of the channels");
}

// A block edge never splits a bin: ragged appends build what one append does.
- (void)testRaggedAppendsBuildTheSameSummary {
    std::mt19937 rng(3);
    std::normal_distribution<float> noise(0, 0.3f);
    std::vector<float> mono(100000);
    for (float &sample : mono) sample = noise(rng);
    SummaryBuilder whole(1, 1, true, (int64_t)mono.size(), 48000);
    whole.append(mono.data(), mono.data(), mono.size());
    SummaryBuilder ragged(1, 1, true, (int64_t)mono.size(), 48000);
    for (size_t at = 0; at < mono.size();) {
        size_t n = std::min<size_t>(mono.size() - at, 1 + rng() % 9000);
        ragged.append(mono.data() + at, mono.data() + at, n);
        at += n;
    }
    auto a = whole.finish(true), b = ragged.finish(true);
    XCTAssertEqual(a->binCount(), b->binCount());
    for (double first = 0; first < 100000; first += 3333) {
        Column x = a->column(first, first + 5000), y = b->column(first, first + 5000);
        XCTAssertEqual(x.lo, y.lo);
        XCTAssertEqual(x.hi, y.hi);
        XCTAssertEqualWithAccuracy(x.sumSquares, y.sumSquares, 1e-6 * x.sumSquares);
        XCTAssertEqualWithAccuracy(x.bandSumSquares[0], y.bandSumSquares[0], 1e-4 * x.bandSumSquares[0]);
    }
}

// A corrupt decode must not reach the views: NaN would make NaN geometry and,
// since the decode still completes, be persisted under the file's key.
- (void)testNonFiniteSamplesAreClampedNotPropagated {
    std::vector<float> samples = {0.5f, NAN, -0.25f, INFINITY, -INFINITY};
    SummaryBuilder builder(1, 1, true, 5, 44100);
    builder.append(samples.data(), samples.data(), samples.size());
    auto summary = builder.finish(true);
    Column column = summary->column(0, 5);
    XCTAssertTrue(std::isfinite(column.lo) && std::isfinite(column.hi));
    XCTAssertTrue(std::isfinite(column.sumSquares));
    XCTAssertTrue(std::isfinite(column.bandSumSquares[0]));
}

- (void)testDecodedFractionIsWhatTheBinsHoldOfTheExpectedLength {
    SummaryBuilder builder(1, 1, false, 4096, 44100);
    std::vector<float> silence(1024, 0);
    builder.append(silence.data(), silence.data(), silence.size());
    auto partial = builder.snapshot();
    XCTAssertEqual(partial->decodedFraction(), 0.25);
    XCTAssertEqual(partial->totalFrames(), 4096, @"a partial waveform spans its expected length");
    XCTAssertFalse(partial->isComplete());
    auto complete = builder.finish(true);
    XCTAssertEqual(complete->decodedFraction(), 1);
    XCTAssertEqual(complete->totalFrames(), 1024, @"a complete waveform spans what was read");
}

#pragma mark - Columns

// Every column against a direct reduction over the frames, at random ranges
// from a few frames to the whole file. Extremes may include a straddling
// bin's frames but never miss one inside; sums count a straddling bin by its
// part.
- (void)testColumnsAreExactAtEveryRange {
    std::mt19937 rng(7);
    std::normal_distribution<float> noise(0, 0.2f);
    const int64_t frames = 2000000;
    std::vector<float> mono(frames);
    for (int64_t i = 0; i < frames; i++) mono[i] = noise(rng) * (1 + 0.5f * sinf((float)i * 1e-4f));
    SummaryBuilder builder(1, 1, false, frames, 44100);
    builder.append(mono.data(), mono.data(), frames);
    auto summary = builder.finish(true);
    double binFrames = summary->binFrames();
    for (int t = 0; t < 300; t++) {
        double first = (double)(rng() % 1000000) / 1e6 * frames;
        double last = std::min<double>(frames, first + pow(10.0, (rng() % 6000) / 1000.0));
        if (last <= first) continue;
        Column column = summary->column(first, last);
        float inside = -INFINITY, touched = -INFINITY;
        for (int64_t i = (int64_t)floor(first); i < (int64_t)ceil(last); i++) inside = std::max(inside, mono[i]);
        int64_t b0 = (int64_t)(floor(first / binFrames) * binFrames);
        int64_t b1 = std::min<int64_t>(frames, (int64_t)(ceil(last / binFrames) * binFrames));
        for (int64_t i = b0; i < b1; i++) touched = std::max(touched, mono[i]);
        XCTAssertGreaterThanOrEqual(column.hi, inside - 1e-3f, @"%f..%f", first, last);
        XCTAssertLessThanOrEqual(column.hi, touched + 1e-3f, @"%f..%f", first, last);
        XCTAssertEqualWithAccuracy(column.frames, last - first, 1e-6 * frames);
        double sum = 0;
        for (int64_t bin = b0; bin < b1; bin += (int64_t)binFrames) {
            int64_t end = std::min<int64_t>(frames, bin + (int64_t)binFrames);
            double binSum = 0;
            for (int64_t i = bin; i < end; i++) binSum += (double)mono[i] * mono[i];
            double overlap = std::min<double>(last, end) - std::max<double>(first, bin);
            if (overlap > 0) sum += binSum * overlap / (double)(end - bin);
        }
        XCTAssertEqualWithAccuracy(column.sumSquares, sum, 1e-3 * sum + 1e-9, @"%f..%f", first, last);
    }
}

// Why a column is the exact union, never a sample of the bins: a transient
// must show at every width.
- (void)testASpikeShowsAtEveryColumnCount {
    for (NSUInteger spikeAt : {(NSUInteger)0, (NSUInteger)37, (NSUInteger)63}) {
        auto summary = std::make_unique<Summary>(1, 1, false, 44100);
        for (NSUInteger i = 0; i < 64; i++) {
            float lo = i == spikeAt ? -1 : 0, hi = i == spikeAt ? 1 : 0;
            summary->appendBin(&lo, &hi, 0, nullptr, 1);
        }
        for (NSUInteger count = 1; count <= 256; count++) {
            std::vector<Column> columns(count);
            summary->columns(64.0 / count, 0, count, columns.data());
            float widest = 0;
            for (const Column &column : columns) widest = std::max(widest, column.hi);
            XCTAssertEqual(widest, 1.0f, @"spike at bin %lu lost at %lu columns", spikeAt, count);
        }
    }
}

- (void)testAColumnPastTheFramesHeldIsEmpty {
    auto summary = VibeRampSummary(64);
    Column past = summary->column(64, 80);
    XCTAssertEqual(past.lo, 0.0f);
    XCTAssertEqual(past.hi, 0.0f);
    XCTAssertEqual(past.frames, 0);
    Column empty = Summary(256, 1, false, 44100).column(0, 1000);
    XCTAssertEqual(empty.frames, 0);
}

// A column is a grid cell counted from frame 0, so a window that starts
// further in reads the same columns a whole-track read does.
- (void)testGridColumnsDoNotDependOnTheFirstIndex {
    auto summary = VibeRampSummary(64);
    std::vector<Column> whole(32), window(8);
    summary->columns(2, 0, 32, whole.data());
    summary->columns(2, 12, 8, window.data());
    for (NSUInteger i = 0; i < 8; i++) {
        XCTAssertEqual(window[i].hi, whole[12 + i].hi);
        XCTAssertEqual(window[i].sumSquares, whole[12 + i].sumSquares);
    }
}

// Energy is a sum over frames, so a column counts a partly covered bin by its
// part.
- (void)testAColumnWeighsEachBinByTheFramesItCovers {
    auto summary = VibeLevelSummary({1, 0}, 4);
    XCTAssertEqualWithAccuracy(summary->column(2, 6).meanSquare(), 0.5f, 1e-6);
    XCTAssertEqualWithAccuracy(summary->column(0, 6).meanSquare(), 4.0f / 6, 1e-6);
}

- (void)testCopyIsDeep {
    auto original = VibeRampSummary(8);
    auto copy = original->copy();
    float lo = -99, hi = 99;
    original->appendBin(&lo, &hi, 0, nullptr, 1);
    XCTAssertEqual(copy->binCount(), 8u);
    XCTAssertEqual(copy->column(0, 100).hi, 7.0f, @"the copy must not see writes to the original");
}

#pragma mark - Loudest windows

// Bins of 256 frames at 44.1 kHz, so a loudest window spans three. All are
// quiet but one loud bin.
static const double kQuietLevel = 0.1;
static std::unique_ptr<Summary> VibeHitSummary(size_t bins, size_t hit) {
    std::vector<float> levels(bins, float(kQuietLevel * kQuietLevel));
    levels[hit] = 1;
    return VibeLevelSummary(levels, 256);
}

// Every window holding the hit's bin: the hit and two quiet bins.
static const double kHitLevel = std::sqrt((1 + 2 * kQuietLevel * kQuietLevel) / 3);

// A column's level is the loudest window it covers. At every width the hit
// shows whole in the columns over it, and a column away from it is quiet: no
// column averages the hit away, and no edge hides it.
- (void)testALevelIsTheLoudestWindowAColumnCovers {
    auto summary = VibeHitSummary(400, 200);
    double total = (double)summary->totalFrames();
    for (size_t count : {(size_t)1, (size_t)7, (size_t)100, (size_t)333, (size_t)399, (size_t)1000}) {
        double frames = total / (double)count;
        std::vector<Column> columns(count);
        summary->columns(frames, 0, count, columns.data());
        size_t over = size_t(200.5 * 256 / frames);
        XCTAssertEqualWithAccuracy(columns[over].loudest, kHitLevel, 1e-3, @"count %zu", count);
        for (size_t c = 0; c < count; c++) {
            double first = (double)c * frames / 256, last = (double)(c + 1) * frames / 256;
            if (last < 198 || first > 203) {
                XCTAssertEqualWithAccuracy(columns[c].loudest, kQuietLevel, 1e-4, @"count %zu column %zu", count, c);
            }
            XCTAssertLessThanOrEqual(columns[c].loudest, kHitLevel + 1e-3);
        }
    }
    // The whole track's is the reference no view can move.
    XCTAssertEqualWithAccuracy(summary->column(0, total).loudest, kHitLevel, 1e-3);
}

// Each band keeps its own loudest window.
- (void)testEachBandKeepsItsLoudestWindow {
    auto summary = std::make_unique<Summary>(256, 1, true, 44100);
    for (size_t i = 0; i < 400; i++) {
        float lo = -1, hi = 1;
        double low = (i == 200 ? 1 : kQuietLevel * kQuietLevel) * 256;
        double bands[wavecore::kBandCount] = {low, 0.04 * 256, 0};
        summary->appendBin(&lo, &hi, low, bands, 256);
    }
    Column hit = summary->column(200 * 256, 201 * 256), away = summary->column(0, 100 * 256);
    XCTAssertEqualWithAccuracy(hit.bandLoudest[0], kHitLevel, 1e-3);
    XCTAssertEqualWithAccuracy(hit.bandLoudest[1], 0.2, 1e-3);
    XCTAssertEqual(hit.bandLoudest[2], 0);
    XCTAssertEqualWithAccuracy(away.bandLoudest[0], kQuietLevel, 1e-4);
}

// A load still streaming reads what it holds: its front is not dragged toward
// the silence past it, and past it there is nothing.
- (void)testAStreamingLoadsFrontReadsItsOwnLevel {
    auto half = VibeLevelSummary(std::vector<float>(200, 0.25f), 256);
    half->setTotalFrames(400 * 256);
    std::vector<Column> columns(40);
    half->columns(10 * 256, 0, 40, columns.data());
    XCTAssertEqualWithAccuracy(columns[19].loudest, 0.5, 1e-3);
    XCTAssertEqual(columns[20].loudest, 0);
}

// The tent is symmetric about the column's centre, so on a ramp it reads the
// column's own mean, except at the edge columns, where the track clips it.
- (void)testTheTentReadsAColumnsOwnMeanOnARamp {
    auto ramp = VibeRampSummary(64);
    for (NSUInteger count : {(NSUInteger)64, (NSUInteger)32, (NSUInteger)8}) {
        double columnFrames = 64.0 / count;
        std::vector<Column> columns(count);
        std::vector<float> tent(count * wavecore::kBandCount);
        ramp->columns(columnFrames, 0, count, columns.data());
        ramp->tentBandMeanSquares(columnFrames, 0, count, columnFrames, tent.data());
        for (NSUInteger i = 1; i + 1 < count; i++) {
            for (NSUInteger b = 0; b < wavecore::kBandCount; b++) {
                XCTAssertEqualWithAccuracy(tent[i * wavecore::kBandCount + b], columns[i].bandMeanSquare(b), 1e-3f,
                                           @"count %lu column %lu", count, i);
            }
        }
        XCTAssertGreaterThanOrEqual(tent[0], columns[0].bandMeanSquare(0));
        XCTAssertLessThanOrEqual(tent[(count - 1) * wavecore::kBandCount], columns[count - 1].bandMeanSquare(0));
    }
}

// The tent's half-width is its own, centred on the column and clipped to the
// track.
- (void)testTheTentWeighsItsNeighbours {
    auto summary = std::make_unique<Summary>(1, 1, true, 44100);
    for (NSUInteger i = 0; i < 8; i++) {
        float lo = -0.1f, hi = 0.1f;
        double bands[wavecore::kBandCount] = {(double)i, 0, 1};
        summary->appendBin(&lo, &hi, 0.01, bands, 1);
    }
    std::vector<float> bands(8 * wavecore::kBandCount);
    // Four bins foot to foot about a one-bin column: 7/8 of the tent's area
    // over the column's own bin, 1/2 over each neighbour, 1/16 over the next.
    summary->tentBandMeanSquares(1, 0, 8, 2, bands.data());
    XCTAssertEqualWithAccuracy(bands[3 * wavecore::kBandCount], 3, 1e-5);
    XCTAssertEqualWithAccuracy(bands[3 * wavecore::kBandCount + 2], 1, 1e-5);
    const float edge = 0.875f + 0.5f + 0.0625f;
    XCTAssertEqualWithAccuracy(bands[0], (1 * 0.5f + 2 * 0.0625f) / edge, 1e-5);
    XCTAssertEqualWithAccuracy(bands[7 * wavecore::kBandCount], (7 * 0.875f + 6 * 0.5f + 5 * 0.0625f) / edge, 1e-5);
    // Without bands, silence.
    auto plain = VibeLevelSummary(std::vector<float>(8, 0.01f), 1);
    plain->tentBandMeanSquares(4, 0, 2, 4, bands.data());
    XCTAssertEqual(bands[0], 0);
}

// The widget bakes off main while a view reads on main, and the first tent
// read builds the running sums. Each round races a fresh summary's build.
- (void)testTheTentIsTheSameOnEveryThread {
    auto make = [] {
        auto summary = std::make_unique<Summary>(1, 1, true, 44100);
        for (NSUInteger i = 0; i < 8192; i++) {
            float lo = -0.1f, hi = 0.1f;
            double bands[wavecore::kBandCount] = {(double)(i % 7), (double)(i % 13), (double)(i % 5)};
            summary->appendBin(&lo, &hi, 0.01, bands, 1);
        }
        return summary;
    };
    const std::array<NSUInteger, 3> counts = {1024, 333, 2};
    std::vector<std::vector<float>> expected;
    auto alone = make();
    for (NSUInteger count : counts) {
        expected.emplace_back(count * wavecore::kBandCount);
        alone->tentBandMeanSquares(8192.0 / count, 0, count, std::max(8192.0 / count, 16.0), expected.back().data());
    }
    for (NSUInteger round = 0; round < 20; round++) {
        auto shared = make();
        Summary *summary = shared.get();
        std::vector<std::vector<float>> answers(16);
        std::vector<std::vector<float>> *out = &answers;
        dispatch_apply(16, DISPATCH_APPLY_AUTO, ^(size_t i) {
            NSUInteger count = counts[i % counts.size()];
            (*out)[i].resize(count * wavecore::kBandCount);
            summary->tentBandMeanSquares(8192.0 / count, 0, count, std::max(8192.0 / count, 16.0), (*out)[i].data());
        });
        for (size_t i = 0; i < 16; i++) {
            XCTAssertTrue(answers[i] == expected[i % counts.size()], @"round %lu thread %zu", round, i);
        }
    }
}

#pragma mark - Archive

- (void)testTheArchiveRoundTripsEveryRead {
    std::mt19937 rng(11);
    std::normal_distribution<float> noise(0, 0.25f);
    std::vector<float> interleaved(2 * 300000), mono(300000);
    for (size_t i = 0; i < mono.size(); i++) {
        interleaved[2 * i] = noise(rng);
        interleaved[2 * i + 1] = noise(rng);
        mono[i] = 0.5f * (interleaved[2 * i] + interleaved[2 * i + 1]);
    }
    for (uint32_t channels : {1u, 2u}) {
        SummaryBuilder builder(2, channels, true, (int64_t)mono.size(), 48000);
        builder.append(interleaved.data(), mono.data(), mono.size());
        auto summary = builder.finish(true);
        std::vector<uint8_t> blob = summary->encode();
        auto decoded = Summary::decode(blob.data(), blob.size());
        XCTAssertTrue(decoded != nullptr);
        if (!decoded) continue;
        XCTAssertEqual(decoded->channels(), channels);
        XCTAssertEqual(decoded->frames(), summary->frames());
        XCTAssertEqual(decoded->binFrames(), summary->binFrames());
        XCTAssertEqual(decoded->sampleRate(), 48000);
        XCTAssertTrue(decoded->isComplete());
        XCTAssertTrue(decoded->hasBands());
        for (double first = 0; first < 300000; first += 7919) {
            Column a = summary->column(first, first + 3001), b = decoded->column(first, first + 3001);
            XCTAssertEqualWithAccuracy(a.hi, b.hi, 1e-3f);
            XCTAssertEqualWithAccuracy(a.lo, b.lo, 1e-3f);
            XCTAssertEqualWithAccuracy(a.sumSquares, b.sumSquares, 2e-3 * a.sumSquares);
            XCTAssertEqualWithAccuracy(a.bandSumSquares[2], b.bandSumSquares[2], 3e-3 * a.bandSumSquares[2] + 1e-9);
            XCTAssertEqualWithAccuracy(a.loudest, b.loudest, 2e-3 * a.loudest);
            XCTAssertEqualWithAccuracy(a.bandLoudest[1], b.bandLoudest[1], 2e-3 * a.bandLoudest[1] + 1e-6);
        }
    }
}

// An archive has no checksum, so every malformed field is refused rather than
// read: a refused entry decodes again, a read one poisons every view.
- (void)testTheArchiveRefusesWhatItCannotTrust {
    auto summary = VibeRampSummary(300);
    std::vector<uint8_t> blob = summary->encode();
    XCTAssertTrue(Summary::decode(blob.data(), blob.size()) != nullptr);
    XCTAssertTrue(Summary::decode(nullptr, 0) == nullptr);
    XCTAssertTrue(Summary::decode(blob.data(), blob.size() - 1) == nullptr, @"truncated");
    for (size_t offset : {(size_t)0, (size_t)4, (size_t)8, (size_t)12, (size_t)16, (size_t)24, (size_t)48}) {
        std::vector<uint8_t> broken = blob;
        broken[offset] ^= 0x5A;
        XCTAssertTrue(Summary::decode(broken.data(), broken.size()) == nullptr, @"header byte %zu", offset);
    }
    // Non-finite values in an uncompressed payload.
    auto bad = std::make_unique<Summary>(1, 1, false, 44100);
    float lo = 0, hi = 0;
    for (int i = 0; i < 4; i++) bad->appendBin(&lo, &hi, 0, nullptr, 1);
    bad->markComplete();
    std::vector<uint8_t> small = bad->encode();
    uint16_t infinity = 0x7C00;
    std::memcpy(small.data() + small.size() - 2, &infinity, 2);
    XCTAssertTrue(Summary::decode(small.data(), small.size()) == nullptr, @"non-finite");
    // Unaligned bytes are read safely.
    std::vector<uint8_t> shifted(blob.size() + 1);
    std::memcpy(shifted.data() + 1, blob.data(), blob.size());
    XCTAssertTrue(Summary::decode(shifted.data() + 1, blob.size()) != nullptr);
}

#pragma mark - Detail

// Bins of 256 frames over a stream whose frame i is sin(i / 10), and a
// detail holding blocks of those frames.
static std::unique_ptr<Summary> VibeSineSummary(int64_t frames, std::vector<float> &samples) {
    samples.resize(size_t(frames));
    for (int64_t i = 0; i < frames; i++) samples[size_t(i)] = float(std::sin(double(i) / 10));
    auto summary = std::make_unique<Summary>(256, 1, false, 44100);
    for (int64_t start = 0; start < frames; start += 256) {
        uint32_t count = uint32_t(std::min<int64_t>(256, frames - start));
        auto range = std::minmax_element(samples.begin() + start, samples.begin() + start + count);
        double sum = 0;
        for (uint32_t j = 0; j < count; j++) sum += double(samples[size_t(start + j)]) * samples[size_t(start + j)];
        summary->appendBin(&*range.first, &*range.second, sum, nullptr, count);
    }
    summary->markComplete();
    return summary;
}

static void VibeInsertBlocks(const Summary &summary, const std::vector<float> &samples) {
    const int64_t blockFrames = wavecore::Detail::kBlockFrames;
    for (int64_t block = 0; block * blockFrames < int64_t(samples.size()); block++) {
        auto begin = samples.begin() + block * blockFrames;
        auto end = samples.begin() + std::min<int64_t>(int64_t(samples.size()), (block + 1) * blockFrames);
        summary.detail().insertBlock(block, std::vector<float>(begin, end));
    }
}

// Finer than a bin, a column reads the frames themselves: their extremes,
// across a block's edge, and their sum of squares.
- (void)testColumnsFinerThanABinReadTheFrames {
    std::vector<float> samples;
    const int64_t frames = wavecore::Detail::kBlockFrames + 5000;
    auto summary = VibeSineSummary(frames, samples);
    std::vector<Column> before(64), after(64);
    int64_t firstIndex = (wavecore::Detail::kBlockFrames - 128) / 4;
    summary->columns(4, firstIndex, 64, before.data());
    VibeInsertBlocks(*summary, samples);
    summary->columns(4, firstIndex, 64, after.data());
    for (size_t c = 0; c < 64; c++) {
        int64_t start = (firstIndex + int64_t(c)) * 4;
        float lo = INFINITY, hi = -INFINITY;
        double sum = 0;
        for (int64_t i = start; i < start + 4; i++) {
            lo = std::min(lo, samples[size_t(i)]);
            hi = std::max(hi, samples[size_t(i)]);
            sum += double(samples[size_t(i)]) * samples[size_t(i)];
        }
        // The line's ends reach a little past the outer samples' centers.
        XCTAssertLessThanOrEqual(after[c].lo, lo + 1e-6);
        XCTAssertGreaterThanOrEqual(after[c].hi, hi - 1e-6);
        XCTAssertGreaterThan(after[c].lo, lo - 0.06);
        XCTAssertLessThan(after[c].hi, hi + 0.06);
        XCTAssertEqualWithAccuracy(after[c].sumSquares, sum, 1e-4);
        XCTAssertEqualWithAccuracy(after[c].frames, 4, 1e-9);
        XCTAssertEqualWithAccuracy(after[c].loudest, std::sqrt(sum / 4), 1e-4, @"a column finer than a bin is its own level");
        // Without the detail the bins answered, each spanning its whole bin.
        XCTAssertGreaterThanOrEqual(before[c].hi - before[c].lo, after[c].hi - after[c].lo);
    }
}

// A column narrower than a frame holds the line's span across it, so at
// sample zoom the picture is the line joining the samples.
- (void)testAColumnInsideAFrameIsTheLinesSpan {
    std::vector<float> samples;
    auto summary = VibeSineSummary(1000, samples);
    VibeInsertBlocks(*summary, samples);
    Column column;
    // A quarter of the way from frame 100's center to frame 101's.
    summary->columns(0.25, 403, 1, &column);
    float at = samples[100] + (samples[101] - samples[100]) * 0.25f;
    float next = samples[100] + (samples[101] - samples[100]) * 0.5f;
    XCTAssertEqualWithAccuracy(column.lo, std::min(at, next), 1e-6);
    XCTAssertEqualWithAccuracy(column.hi, std::max(at, next), 1e-6);
}

// Without every block a read crosses, the bins answer, and an evicted block
// is gone.
- (void)testAMissingBlockFallsBackToTheBins {
    std::vector<float> samples;
    const int64_t blockFrames = wavecore::Detail::kBlockFrames;
    auto summary = VibeSineSummary(3 * blockFrames, samples);
    summary->detail().insertBlock(0, std::vector<float>(samples.begin(), samples.begin() + blockFrames));
    Column straddling, inside;
    summary->columns(16, blockFrames / 16 - 1, 1, &straddling);
    XCTAssertEqualWithAccuracy(straddling.frames, 16, 1e-9);
    XCTAssertTrue(summary->detail().hasBlock(0));
    XCTAssertFalse(summary->detail().columns(16, blockFrames / 16 - 1, 1, summary->frames(), &inside));
    for (int64_t block = 1; block <= int64_t(wavecore::Detail::kMaxBlocks); block++) {
        summary->detail().insertBlock(block, std::vector<float>(16, 0));
    }
    XCTAssertFalse(summary->detail().hasBlock(0), @"the oldest goes first");
    // A coarser grid never reads the detail.
    Column coarse;
    summary->columns(512, 0, 1, &coarse);
    XCTAssertEqualWithAccuracy(coarse.hi, 1, 1e-3);
}

// A read keeps the blocks it lacked until they are taken, once. A read too
// wide for the blocks held answers from the bins and asks for nothing.
- (void)testAReadAsksForTheBlocksItLacked {
    std::vector<float> samples;
    const int64_t blockFrames = wavecore::Detail::kBlockFrames;
    const int64_t readBlocks = int64_t(wavecore::Detail::kMaxReadBlocks);
    auto summary = VibeSineSummary((readBlocks + 2) * blockFrames, samples);
    wavecore::Detail &detail = summary->detail();
    detail.insertBlock(0, std::vector<float>(samples.begin(), samples.begin() + blockFrames));
    XCTAssertEqual(detail.insertCount(), 1u);
    std::vector<Column> columns(2);
    summary->columns(16, blockFrames / 16 - 1, 2, columns.data());
    XCTAssertTrue(detail.takeLackedBlocks() == std::vector<int64_t>({1}));
    XCTAssertTrue(detail.takeLackedBlocks().empty(), @"taken once");
    size_t wide = size_t((readBlocks + 1) * blockFrames / 128);
    std::vector<Column> across(wide);
    summary->columns(128, 0, wide, across.data());
    XCTAssertTrue(detail.takeLackedBlocks().empty());
    summary->columns(16, blockFrames / 16 - 1, 2, columns.data());
    detail.insertBlock(1, std::vector<float>(samples.begin() + blockFrames, samples.begin() + 2 * blockFrames));
    XCTAssertEqual(detail.insertCount(), 2u);
    XCTAssertTrue(detail.takeLackedBlocks().empty(), @"an insert answers what it lacked");
}

@end
