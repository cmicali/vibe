//
//  AudioVoiceBusInternal.h
//  Vibe
//
//  The test seam: the host-less suite calls VibeVoiceBusRender directly over
//  the bus's mix and buffers it owns, with no pipeline. Nothing in the app
//  imports this.
//

#import "AudioVoiceBus.h"

NS_ASSUME_NONNULL_BEGIN

@class VibeVoiceRecord;

@interface AudioVoiceBus (Rendering)

// The decode queue, nil under inline decoding: the race tests hold it.
@property (nonatomic, readonly, nullable) dispatch_queue_t decodeQueue;

// Slots in each state, for the pool tests.
- (NSUInteger)slotCountInState:(VibeVoiceState)state;
- (NSUInteger)pendingVoiceCount;

// Decoder steps the race tests hold the decode queue inside.
- (BOOL)prepareRecord:(VibeVoiceRecord *)record file:(AVAudioFile *)file decodeFormat:(AVAudioFormat *)decodeFormat;
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final;
- (void)recycleSlot:(NSUInteger)slot generation:(VibeVoiceID)generation;

// A render stuck inside the bus: while set, a render blocks in
// VibeVoiceBusRender after it has entered, so a decoder waiting for it to
// leave waits in earnest; debugRendersHeld counts the renders blocked there.
// Debug builds only. Any thread.
- (void)debugHoldRender:(BOOL)hold;
- (NSUInteger)debugRendersHeld;

@end

NS_ASSUME_NONNULL_END
