//
//  AudioPlayer+Prefetch.h
//  Vibe
//
//  The next track, from the moment it is named to the moment it is playing:
//  the PARK — the file the player opens ahead of time so a later play of it
//  starts without paying for the open — and the SUCCESSOR, the parked file
//  queued on the current voice so the bus continues into it at the boundary
//  with no gap.
//
//  The park lives by three rules:
//
//  - **The request id fences it.** Each prefetch pairs with its own async open,
//    so a superseded prefetch cannot park a stale handle when it finally lands.
//  - **A parked handle holds an open fd**, so a file rewritten between prefetch
//    and play plays the bytes as prefetched, as a file rewritten mid-playback
//    already does.
//  - **An open still in flight at play: time is not adopted.** A same-path play
//    races it with its own open; an unrelated park is cancelled before the
//    foreground open; a winner clears the loser's park before a late delivery
//    can make the now-current track its own successor.
//
//  The successor is the park itself: the bus's decoder is the only reader of
//  a file after a voice starts, so no private second handle is needed. It is
//  queued when the crossfade is at its minimum and, under bit-perfect output,
//  when the next file wants the device's current format; the bus reports the
//  boundary passing and the transport promotes the successor in place. The
//  promote consumes the park, so a replay of the promoted row opens fresh.
//
//  All on the player queue except prefetchTrack:.
//

#import "AudioPlayer.h"
#import "AudioPrefetchRules.h"
#import <AVFoundation/AVFoundation.h>

@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Prefetch)

// nil drops the park, which is what a play past the last track does. A
// different-path request suppressed behind playback retains its track and
// resumes only after that playback succeeds.
- (void)prefetchOnQueue:(nullable AudioTrack *)track;

- (void)clearPrefetchOnQueue;
- (void)terminallyRetirePrefetchRequestOnQueue;
- (void)playbackDidSucceedForPrefetchOnQueue;
- (void)retirePrefetchOnQueueAtPoint:(VibeAudioPrefetchRetirementPoint)point
                            playPath:(nullable NSString *)playPath;

// Queues the park on the current voice when every gate holds; idempotent.
- (void)maybeArmSuccessorOnQueue;
// Drops the queued successor: the voice ends at its own file, as unarmed.
- (void)unqueueSuccessorOnQueue;
// Forgets the successor's bookkeeping without touching the bus; for a voice
// that is being retired or has died.
- (void)clearSuccessorOnQueue;
// The boundary passed: the successor is sounding. Republishes it as current.
- (void)promoteSuccessorOnQueue;

@end

NS_ASSUME_NONNULL_END
