//
//  AudioResampler.h
//  Vibe
//
//  The voice bus's sample-rate converter: Apple's AudioConverterRef at
//  mastering complexity and maximum quality, or r8brain-free-src
//  (Vibe/ThirdParty/r8brain), behind one fill in AudioConverterFillComplexBuffer's
//  shape, so the bus drives either through the same input proc: float32
//  non-interleaved in and out, the proc pulled until a fill is met or the proc
//  answers a nonzero status, which ends the fill with what it produced and
//  leaves the filter primed. Neither is told the stream's end: N frames fed
//  come out as round(N × ratio) once pushed through with silence, as the bus's
//  flush does. Decode queue only; not realtime.
//

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Which resampler converts a file whose rate is not the bus's.
typedef NS_ENUM(NSInteger, VibeResampler) {
    VibeResamplerApple = 0,   // AudioConverterRef at mastering complexity, maximum quality
    VibeResamplerR8brain,     // r8brain-free-src, linear phase, 24-bit preset, 1% transition band
};

// The one spelling of each, for reports and the debug channel.
static inline NSString *VibeResamplerName(VibeResampler resampler) {
    return resampler == VibeResamplerR8brain ? @"r8brain" : @"apple";
}

// C linkage: the bus (.m) calls the .mm.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeConverter VibeConverter;

// Float32 non-interleaved `from` to `to`, the same channel count. NULL when
// the converter could not be made.
VibeConverter *_Nullable VibeConverterCreate(VibeResampler resampler, const AudioStreamBasicDescription *from,
                                            const AudioStreamBasicDescription *to);
void VibeConverterDispose(VibeConverter *converter);
VibeResampler VibeConverterResampler(const VibeConverter *converter);

// The proc is asked for at most 4096 packets; under r8brain its converter
// argument is not an AudioConverterRef and must not be used.
OSStatus VibeConverterFill(VibeConverter *converter, AudioConverterComplexInputDataProc proc, void *_Nullable userData,
                           UInt32 *ioFrames, AudioBufferList *output);

// For the audio-path report: `resampler`, `algorithm`, and Apple's `quality`
// as read back (iOS's resampler reports no algorithm).
NSDictionary<NSString *, id> *VibeConverterReport(const VibeConverter *converter);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
