//
//  AudioResampler.h
//  Vibe
//
//  The voice bus's sample-rate converter: r8brain-free-src
//  (Vibe/ThirdParty/r8brain), linear phase, its 24-bit preset, a 1% transition
//  band, behind one fill in AudioConverterFillComplexBuffer's shape: float32
//  non-interleaved in and out, the proc pulled until a fill is met or the proc
//  answers no packets, which ends the fill with what it produced and leaves
//  the filter primed; a nonzero status ends it and is returned. It is never
//  told the stream's end: N frames fed come out as round(N × ratio) once
//  pushed through with silence, as the bus's flush does. Decode queue only;
//  not realtime.
//

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the bus (.m) calls the .mm.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeConverter VibeConverter;

// Float32 non-interleaved `from` to `to`, the same channel count. NULL when
// the converter could not be made.
VibeConverter *_Nullable VibeConverterCreate(const AudioStreamBasicDescription *from, const AudioStreamBasicDescription *to);
void VibeConverterDispose(VibeConverter *converter);

// The proc is asked for at most 4096 packets; its converter argument is not an
// AudioConverterRef and must not be used.
OSStatus VibeConverterFill(VibeConverter *converter, AudioConverterComplexInputDataProc proc, void *_Nullable userData,
                           UInt32 *ioFrames, AudioBufferList *output);

// For the audio-path report: the `algorithm`.
NSDictionary<NSString *, id> *VibeConverterReport(const VibeConverter *converter);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
