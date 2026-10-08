//
//  AudioVarispeed.h
//  Vibe
//
//  The pitch fader's stage: a varispeed between the voice bus and the FX.
//  At zero pitch it is a bit-perfect pass-through: the source goes straight
//  to the output, nothing converted, delayed or copied. Off zero it is a
//  Kaiser-windowed sinc, β 15.6 for about 150 dB of stopband, with 64 zero
//  crossings each side. Its −6 dB point is 22 kHz at 48 kHz, the same
//  fraction of any rate. Above a ratio of 1 the kernel is stretched by the
//  ratio, so its cutoff follows the output's Nyquist and no input above it
//  folds back. It reads the kernel from a polyphase table, with a cubic
//  across phases, and sums in double.
//
//  The stage owns its ring, its position and its tables. The queue half sets
//  the pitch and frees what it replaced once no render is inside the stage;
//  the caller owns that wait (AudioPlayer+Pipeline.m's afterRenderLeaves).
//  The audio-thread half renders one slice at a time and pulls its source
//  through a callback. docs/audio-quality.md has the measurements.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: the benchmarks (.mm) call it.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VibeVarispeed VibeVarispeed;
typedef struct VibeVarispeedTable VibeVarispeedTable;

// A list of up to two channel buffers, built on the stack.
typedef struct {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[2];
} VibeStereoBufferList;

// `frames` of `list`'s first `channels` buffers, from `offset`.
static inline VibeStereoBufferList VibeStereoBufferListSpan(const AudioBufferList *list, uint32_t channels, UInt32 offset,
                                                            UInt32 frames) CA_REALTIME_API {
    VibeStereoBufferList span = { channels, {{0}} };
    for (UInt32 c = 0; c < channels; c++) {
        span.mBuffers[c].mNumberChannels = 1;
        span.mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        span.mBuffers[c].mData = (float *)list->mBuffers[c].mData + offset;
    }
    return span;
}

// The stage's source: `frames` of it into `into`, the stage's channels.
typedef OSStatus (*VibeVarispeedInputProc)(void *context, UInt32 frames, AudioBufferList *into) CA_REALTIME_API;

#pragma mark - The queue

// A stage at zero pitch for slices of up to `maxFrames` of `channels` (1 or
// 2). It builds no kernel until the pitch first leaves zero. NULL when it
// cannot be allocated.
VibeVarispeed *_Nullable VibeVarispeedCreate(uint32_t channels, uint32_t maxFrames);
// With no render inside it.
void VibeVarispeedFree(VibeVarispeed *_Nullable stage);

// The pitch in percent, held to the fader's widest throw, ±16%. A new
// stretch builds its table here; the one it replaces comes back in
// `replaced`, for VibeVarispeedRetire once no render is inside. NO when the
// table could not be built: the last one stays, and a stage with none stays
// at zero.
BOOL VibeVarispeedSetPitch(VibeVarispeed *stage, double percent,
                           VibeVarispeedTable *_Nullable *_Nonnull replaced);
// Frees `replaced`, and any table kept before, unless the render's last
// slice used it: that one waits for the next retire. With no render inside.
void VibeVarispeedRetire(VibeVarispeed *stage, VibeVarispeedTable *replaced);

// From any thread, for the reports.
BOOL VibeVarispeedWanted(const VibeVarispeed *stage);   // the pitch is off zero
BOOL VibeVarispeedEngaged(const VibeVarispeed *stage);  // the converter is in the chain
double VibeVarispeedRatio(const VibeVarispeed *stage);
// The kernel's half-width in input frames: 64, and ceil(64 × ratio) above 1;
// 0 before the pitch first leaves zero.
uint32_t VibeVarispeedHalfWidth(const VibeVarispeed *stage);
// How late the stage plays the source, in output frames: the half-width at
// the ratio while the pitch is off zero, 0 otherwise.
double VibeVarispeedDelayFrames(const VibeVarispeed *stage);
uint64_t VibeVarispeedRenders(const VibeVarispeed *stage);    // the converter's slices
uint64_t VibeVarispeedRingWrites(const VibeVarispeed *stage); // none at zero pitch settled

#pragma mark - The audio thread

// One slice of `frames` (up to the stage's maxFrames) into `out`, the
// stage's channels. At zero pitch, the source straight in. Leaving zero, the
// slice plays the source directly and records it as the kernel's past, then
// the converter joins at the next frame. Off zero, the converter, the ratio
// ramped across the slice from the last slice's. Returning to zero, the
// source frames the converter had pulled ahead play first. No frame is
// skipped or repeated.
OSStatus VibeVarispeedRender(VibeVarispeed *stage, VibeVarispeedInputProc input, void *context, UInt32 frames,
                             AudioBufferList *out) CA_REALTIME_API;

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
