//
//  AudioVoiceBusInternal.h
//  Vibe
//
//  The test seam: the host-less suite calls VibeVoiceBusRender directly over
//  the bus's mix and buffers it owns, with no pipeline. Only the bus
//  implementation and the tests import this.
//

#import "AudioVoiceBus.h"

NS_ASSUME_NONNULL_BEGIN

@class AudioVoiceRecord;

@interface AudioVoiceBus (Rendering)

// The decode queue, nil under inline decoding: the race tests hold it.
@property (nonatomic, readonly, nullable) dispatch_queue_t decodeQueue;

// Slots in each state, for the pool tests.
- (NSUInteger)slotCountInState:(VibeVoiceState)state;
- (NSUInteger)pendingVoiceCount;

// Decoder steps the race tests hold the decode queue inside.
- (BOOL)prepareRecord:(AudioVoiceRecord *)record file:(AudioFileHandle *)file;
- (uint32_t)produceChunkForSlot:(NSUInteger)slot final:(BOOL *)final;
- (void)recycleSlot:(NSUInteger)slot generation:(VibeVoiceID)generation;

@end

NS_ASSUME_NONNULL_END
