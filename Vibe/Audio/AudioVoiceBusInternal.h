//
//  AudioVoiceBusInternal.h
//  Vibe
//
//  The test seam: the host-less suite drives the render block directly, with
//  no engine, over buffers it owns. Nothing in the app imports this.
//

#import "AudioVoiceBus.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioVoiceBus (Rendering)

// The block the source node was created with. Calling it is a render: it
// runs on the caller's thread with the audio thread's contract.
@property (nonatomic, readonly) AVAudioSourceNodeRenderBlock renderBlock;

// Slots in each state, for the pool tests.
- (NSUInteger)slotCountInState:(VibeVoiceState)state;
- (NSUInteger)pendingVoiceCount;

@end

NS_ASSUME_NONNULL_END
