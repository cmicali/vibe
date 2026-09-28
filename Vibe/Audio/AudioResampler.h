//
//  AudioResampler.h
//  Vibe
//
//  The voice bus's sample-rate converter: r8brain-free-src
//  (Vibe/ThirdParty/r8brain), linear phase, its 24-bit preset, a 1% transition
//  band. A fill pulls float32 input through a callback until it has the frames
//  it was asked for or the callback answers none, which ends the fill with
//  what it produced and leaves the filter primed. It is never told the
//  stream's end: N frames fed come out as round(N × ratio) once pushed through
//  with silence, as the bus's flush does. Decode queue only; not realtime.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the bus (.m) calls the .mm.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeConverter VibeConverter;

// Points `channels[c]` at up to `maxFrames` frames of each channel's float32
// input, valid until the next call, and returns how many; 0 is none for now.
typedef uint32_t (*VibeConverterInputProc)(void *_Nullable userData, uint32_t maxFrames,
                                           const float *_Nullable *_Nonnull channels);

// NULL when the converter could not be made.
VibeConverter *_Nullable VibeConverterCreate(double fromRate, double toRate, uint32_t channels);
void VibeConverterDispose(VibeConverter *converter);

// Up to `frames` into `output`, one buffer per channel; returns the frames made.
uint32_t VibeConverterFill(VibeConverter *converter, VibeConverterInputProc input, void *_Nullable userData,
                           uint32_t frames, float *const _Nonnull *_Nonnull output);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
