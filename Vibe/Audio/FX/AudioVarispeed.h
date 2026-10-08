//
//  AudioVarispeed.h
//  Vibe
//
//  The pitch fader's converter: a Kaiser-windowed sinc, β 15.6 for about
//  150 dB of stopband, with 64 zero crossings each side. Its −6 dB point is
//  22 kHz at 48 kHz, the same fraction of any rate. Above a ratio of 1 the
//  kernel is stretched by the ratio, so its cutoff follows the output's
//  Nyquist and no input above it folds back. It reads the kernel from a
//  polyphase table, with a cubic across phases, and sums in double.
//
//  This is the arithmetic alone. The pipeline (AudioPlayer+Pipeline.m) owns
//  the ring it reads, its place in the chain, the zero-pitch bypass and each
//  table's lifetime. docs/audio-quality.md has the measurements.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the benchmarks (.mm) call it.
#ifdef __cplusplus
extern "C" {
#endif

// The fader's widest throw, ±16%, and the kernel's half-width there,
// ceil(64 × 1.16). A ratio is held to the throw, and a reader sizes its ring
// and an engage's history for the half-width.
static const double kVibeVarispeedMaxRatio = 1.16;
static const uint32_t kVibeVarispeedMaxHalfWidth = 75;

// One stretch of the kernel as a polyphase table.
typedef struct {
    double stretch;  // the ratio above 1, else 1
    uint32_t half;   // the half-width in input frames: ceil(64 × stretch)
    double rows[];
} VibeVarispeedTable;

// The table for a ratio from 2 − kVibeVarispeedMaxRatio to
// kVibeVarispeedMaxRatio: stretched by the ratio above 1. About 0.1 ms;
// NULL when it cannot be allocated. Freed with free(). Not realtime.
VibeVarispeedTable *_Nullable VibeVarispeedTableCreate(double ratio);

// How far past `index` a slice of `frames` outputs reads the ring, as an
// exclusive bound, with the ratio ramped from `from` to `to` across it.
uint64_t VibeVarispeedReach(const VibeVarispeedTable *table, double fraction, double from, double to,
                            uint32_t frames) CA_REALTIME_API;

// `frames` outputs into `left` and `right`, the ratio ramped linearly from
// `from` to `to` across them. The position is `*index` and `*fraction` in
// ring frames, advanced by the frames consumed. The ring is a power of two,
// `mask` + 1 frames per channel, and must hold every frame from
// `*index` − half + 1 up to the reach.
void VibeVarispeedConvert(const VibeVarispeedTable *table, const float *ringLeft, const float *ringRight, uint32_t mask,
                          uint64_t *index, double *fraction, double from, double to, uint32_t frames,
                          float *left, float *right) CA_REALTIME_API;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
