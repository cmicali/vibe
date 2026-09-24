//
//  AudioVoiceBusInternal.h
//  Vibe
//
//  The test seam: the host-less suite drives the render block directly, with
//  no engine, over buffers it owns. Nothing in the app imports this.
//

#import "AudioVoiceBus.h"

NS_ASSUME_NONNULL_BEGIN

@class VibeVoiceRecord;

@interface AudioVoiceBus (Rendering)

// The block the source node was created with. Calling it is a render: it
// runs on the caller's thread with the audio thread's contract.
@property (nonatomic, readonly) AVAudioSourceNodeRenderBlock renderBlock;

// The decode queue, nil under inline decoding: the race tests hold it.
@property (nonatomic, readonly, nullable) dispatch_queue_t decodeQueue;

// Slots in each state, for the pool tests.
- (NSUInteger)slotCountInState:(VibeVoiceState)state;
- (NSUInteger)pendingVoiceCount;

// Decoder steps the race tests hold the decode queue inside.
- (BOOL)prepareRecord:(VibeVoiceRecord *)record file:(AVAudioFile *)file decodeFormat:(AVAudioFormat *)decodeFormat;
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final;

@end

NS_ASSUME_NONNULL_END
