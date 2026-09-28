//
//  AudioResampler.h
//  Vibe
//
//  r8brain-free-src (Vibe/ThirdParty/r8brain) in AudioConverterFillComplexBuffer's
//  shape, so the voice bus drives it through the same input proc as Apple's
//  converter: float32 non-interleaved in and out, the proc pulled until a
//  fill is met or the proc answers a nonzero status, which ends the fill with
//  what it produced and leaves the filter primed. Latency is compensated
//  inside, so N frames fed come out as round(N × ratio) once pushed through
//  with silence, as the bus's flush does. Decode queue only; not realtime.
//

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Which resampler converts a file whose rate is not the bus's.
typedef NS_ENUM(NSInteger, VibeResampler) {
    VibeResamplerApple = 0,   // AudioConverterRef at mastering complexity
    VibeResamplerR8brain,     // r8brain-free-src, linear phase, 24-bit preset
};

// The one spelling of each, for reports and the debug channel.
static inline NSString *VibeResamplerName(VibeResampler resampler) {
    return resampler == VibeResamplerR8brain ? @"r8brain" : @"apple";
}

// C linkage: the bus (.m) calls the .mm.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeR8Resampler VibeR8Resampler;

// NULL when the filters could not be built.
VibeR8Resampler *_Nullable VibeR8ResamplerCreate(double fromRate, double toRate, UInt32 channels);
void VibeR8ResamplerDispose(VibeR8Resampler *resampler);

// The proc is asked for at most 4096 packets; its converter argument is not
// an AudioConverterRef and must not be used.
OSStatus VibeR8ResamplerFill(VibeR8Resampler *resampler, AudioConverterComplexInputDataProc proc, void *_Nullable userData,
                             UInt32 *ioFrames, AudioBufferList *output);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
