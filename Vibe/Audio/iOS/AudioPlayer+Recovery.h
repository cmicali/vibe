//
//  AudioPlayer+Recovery.h
//  Vibe (iOS)
//
//  The player's iOS output-recovery half — what AudioPlayer+Devices'
//  rate-change and device-loss handling is on macOS. It lives in this
//  directory so the mac target never compiles these entry points.
//  AudioSessionController's delegate verdicts are the only callers.
//

#import "AudioPlayer.h"

@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

typedef void (^VibeMediaServicesResetCompletion)(
        AudioTrack * _Nullable resetTrack,
        NSTimeInterval position);

@interface AudioPlayer (Recovery)

// The route moved without output being lost, or an interruption ended.
// While playing: follows the route's sample rate, rebuilding the pipeline
// with the track kept, and restarts a unit the system stopped; the voice
// continues from the frame it stopped at. Otherwise a no-op — the next start
// follows the route. A restart with no unit to make parks the track Paused
// (didPausePlaying:); one the unit refuses later parks it too, with the error
// every refused start sends.
- (void)recoverOutput;

// Media services crashed and were relaunched: the output unit and every
// open AudioFileHandle are invalid and must be recreated, per AVAudioSession's
// contract for AVAudioSessionMediaServicesWereResetNotification. Call this on
// the notification's receiving thread. It establishes a player-queue barrier
// at that edge, ordered with play submissions, then drops the invalid objects,
// rebuilds the output as init does and reports Stopped with no currentTrack. completion
// runs on main with the pre-reset track and its position after that state is
// authoritative. It is dropped when a play submitted after the reset edge
// owns the rebuilt output instead. Like stop, rebuilding fires no delegate
// callback.
- (void)beginMediaServicesResetWithCompletion:
        (nullable VibeMediaServicesResetCompletion)completion;

@end

NS_ASSUME_NONNULL_END
