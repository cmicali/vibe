//
//  AudioPlayer+Prefetch.h
//  Vibe
//
//  The PARK is the next file opened ahead of time; the SUCCESSOR is the park
//  queued on the current voice, continuing at the boundary with no gap.
//
//  - A generation fences each prefetch's open, so a superseded one cannot
//    park a stale handle.
//  - A parked handle holds an open fd: a file rewritten before the play plays
//    the bytes as prefetched.
//  - An open still in flight at play: is not adopted. A play of the same
//    track races it with its own open; an unrelated park is cancelled first;
//    the winner clears the loser's park before a late delivery can make the
//    current track its own successor.
//
//  The promote consumes the park, so a replay of the promoted row opens
//  fresh. Player queue only.
//

#import "AudioPlayer.h"
#import "AudioPrefetchRules.h"
#import <AVFAudio/AVFAudio.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Prefetch)

// nil drops the park, which is what a play past the last track does. A
// request for another track suppressed behind playback retains its track and
// resumes only after that playback succeeds.
- (void)prefetchOnQueue:(nullable AudioTrack *)track;

- (void)clearPrefetchOnQueue;
- (void)terminallyRetirePrefetchRequestOnQueue;
- (void)playbackDidSucceedForPrefetchOnQueue;
// playKey is the playing track's sourceKey.
- (void)retirePrefetchOnQueueAtPoint:(VibeAudioPrefetchRetirementPoint)point
                             playKey:(nullable NSString *)playKey;

// Queues the park on the current voice when every gate holds; idempotent.
- (void)maybeArmSuccessorOnQueue;
- (BOOL)gaplessArmAllowedOnQueue;
// Drops the queued successor: the voice ends at its own file, as unarmed.
- (void)unqueueSuccessorOnQueue;
// Forgets the successor's bookkeeping without touching the bus; for a voice
// that is being retired or has died.
- (void)clearSuccessorOnQueue;
// The boundary passed: the successor is sounding. Republishes it as current.
- (void)promoteSuccessorOnQueue;

@end

NS_ASSUME_NONNULL_END
