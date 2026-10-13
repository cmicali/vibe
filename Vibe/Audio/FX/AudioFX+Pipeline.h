//
//  AudioFX+Pipeline.h
//  Vibe
//
//  The player pipeline's half of AudioFX: the connect, the media-services
//  reset, the hosting the master bus renders, and the render itself. The tests
//  read the render counters. AudioFX.m implements all of it.
//

#import "AudioFX.h"

@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

typedef struct VibeFXChain VibeFXChain;

@interface AudioFX (Pipeline)

// On the queue with the output stopped; idempotent. The units are hosted at
// the first connect (`format` stereo float32 non-interleaved) and kept; a
// connect at another rate re-hosts them and re-applies the intent.
// Disconnecting rests every unit and tail without changing intent.
- (void)setConnected:(BOOL)connected format:(nullable AVAudioFormat *)format maximumFrameCount:(UInt32)maximumFrameCount;

// Media-services reset, on the player queue after withdrawing the chain:
// dispose orphaned units without messaging them; the next connect re-hosts.
- (void)markDead;

// The current hosting, NULL while unhosted. A published chain stays valid for
// every render that read it. Player queue.
- (VibeFXChain *)chain;

// Player queue: reads the hosting.
- (NSUInteger)hostedUnitCount;
// Render calls across all units. Any thread.
- (uint64_t)unitRenders;

@end

// In place over `io`: stereo float32, non-interleaved, at most the hosted
// maximumFrameCount frames. Audio thread. The first unit render that fails
// ends the call with its status; the caller silences the slice.
OSStatus VibeFXChainRender(VibeFXChain *chain, const AudioTimeStamp *timestamp, UInt32 frames, AudioBufferList *io) CA_REALTIME_API;

NS_ASSUME_NONNULL_END
