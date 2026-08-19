//
//  AudioPlayer+Seek.h
//  Vibe
//
//  Moving the playhead, which on AVAudioPlayerNode means stopping the node and
//  rescheduling the file from a new frame — there is no seek primitive. That
//  makes it the most delicate operation the player performs, and the reason
//  this is one file rather than a method among others:
//
//  - **A bare stop mid-render clicks**, so a seek while playing is a fade down,
//    a reschedule, and a fade up. Paused, it is a silent in-place reschedule.
//  - **Stopping the node drops any queued gapless segment**, so the splice is
//    disarmed first and re-armed after the reschedule (AudioPlayer+Gapless.h).
//  - **A seek can arrive before the play it belongs to has reached the queue.**
//    The submitted-play identity binds a seek to the exact queued play, so a
//    seek submitted a moment after a play does not evaporate in the gap before
//    the player queue enters Loading.
//  - **Unscheduling a stale splice reuses this whole path**, through
//    seekToPosition:restoringPreemptedPause: — the fade down/reschedule/fade
//    up dance is the only click-free way to drop a queued segment. It costs
//    one spurious didFinishSeeking:, which only settles UI. Restoring matters
//    because that seek is internal: a user seek deliberately cancels a pending
//    pause, but a pause raced against a playlist retarget must survive it, so
//    the internal seek lands parked instead of fading back up.
//
//  The reschedule half is private to this file: seekToPosition: is the only
//  caller, and the whole point of the pair is that nothing else may enter
//  halfway.
//

#import "AudioPlayer.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Seek)

// Moves the playhead, asynchronously: the move is submitted to the player
// queue and settles with a didFinishSeeking: callback. Positions outside the
// file are clamped. Safe to call while Loading — the seek binds to the play
// that is still opening and applies when it starts.
- (void)seekToPosition:(NSTimeInterval)position;

// The internal splice-unschedule form: a pending pause this seek preempts is
// carried through and the reschedule lands parked, with didPausePlaying:
// delivered. Every user seek takes the plain form, which cancels the pause.
- (void)seekToPosition:(NSTimeInterval)position
        restoringPreemptedPause:(BOOL)restoringPreemptedPause;

@end

NS_ASSUME_NONNULL_END
