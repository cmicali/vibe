//
//  AudioPlayer+Gapless.h
//  Vibe
//
//  The next track, from the moment it is named to the moment it is playing:
//  the parked handle the player opens ahead of time, and the splice that
//  renders it without a gap. One file because they share state — the park is
//  where the splice's private handle is opened from, and both write the
//  in-flight open's claim.
//
//  THE PARK. Opening a file is what dominates transition latency — seconds
//  for a cloud placeholder — so the controller names the next track on every
//  track start and the player opens it ahead of time, off the queue, at
//  utility QoS. Three rules it lives by:
//
//  - **The request id fences it.** Each prefetch pairs with its own async open,
//    so a superseded prefetch cannot park a stale handle when it finally lands.
//  - **A parked handle holds an open fd**, so a file rewritten between prefetch
//    and play plays the bytes as prefetched. That matches what a file rewritten
//    mid-playback already does.
//  - **An open still in flight at play: time is not adopted.** Its utility-QoS
//    worker cannot be boosted, so the play races it with its own open rather
//    than waiting on it.
//
//  THE SPLICE. With crossfade off and a format-matching next track, the next
//  file is scheduled as a SECOND SEGMENT on the current player node, which
//  AVAudioPlayerNode renders back-to-back with the first, sample-accurately.
//  No teardown, no fade, no graph mutation at the boundary — the audio simply
//  continues, and the promote is bookkeeping catching up with sound already
//  playing.
//
//  The verbs run in the order one track's life passes through them: OPEN its
//  private handle (maybeOpenGaplessFileFor…), ARM it onto the node (maybeArm…),
//  PROMOTE it to current when the boundary passes (promote…), UNSCHEDULE it
//  when the playlist's next changes underneath (unschedule…), CLEAR it when the
//  material is dead (clear…). All on the player queue except prefetchTrack:.
//
//  ALWAYS, and the one that breaks first: every `[node stop]` of the
//  current node drops its queued segment too. Every such site must clear the
//  armed flag first and, when it keeps playing the same file, re-arm after
//  its reschedule.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Gapless)

// Runs on _queue. nil drops the park, which is what a play past the last track
// does.
- (void)prefetchOnQueue:(nullable AudioTrack *)track;

// Every site in AudioPlayer.m that stops and reschedules the current node must
// disarm and re-arm through these.
- (void)setGaplessQueuedOnQueue:(BOOL)queued;
- (void)maybeArmGaplessOnQueue;
- (void)clearGaplessOnQueue;
- (void)promoteGaplessOnQueue;
- (void)unscheduleGaplessOnQueue;
- (void)maybeOpenGaplessFileForTrack:(AudioTrack *)track prefetchedFile:(AVAudioFile *)prefetchedFile;

@end

NS_ASSUME_NONNULL_END
