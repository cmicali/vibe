//
//  AudioMasterBus.h
//  Vibe
//
//  The render: voice bus -> [varispeed] -> [FX] -> [meter] -> [volume] -> the
//  output unit's buffers. AudioPlayer+Pipeline is its player-queue side.
//  AudioMasterBusInternal.h is its layout.
//

#import "AudioVoiceBus.h"
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

// The largest slice the pipeline renders at once — the bus's own span, so
// the bus mixes every slice whole — and every hosted FX unit's frames per
// slice; an output unit's larger cycle is rendered in slices.
static const AVAudioFrameCount kVibeMasterBusMaxFrames = kVibeVoiceBusMaxRenderFrames;

// The pipeline's audio-thread state. Its layout is AudioMasterBusInternal.h.
typedef struct VibeMasterBus VibeMasterBus;
OSStatus VibeMasterBusRender(void *context, const AudioTimeStamp * _Nullable timestamp,
                            UInt32 frames, AudioBufferList *data) CA_REALTIME_API;

// Gate closed, nothing hosted. Lives from the player's init to its dealloc,
// so no queue-side reader finds it absent.
VibeMasterBus *VibeMasterBusCreate(void);
// The output volume's gain, 0..1, from any thread; the render ramps to it
// across its next slice, or lands on it at the next output start. 1, the
// default, leaves every sample untouched.
void VibeMasterBusSetVolume(VibeMasterBus *master, float gain);
// Frees the varispeed and the master bus; the output unit is stopped and no
// render is inside. The player's dealloc.
void VibeMasterBusFree(VibeMasterBus *master);

NS_ASSUME_NONNULL_END
