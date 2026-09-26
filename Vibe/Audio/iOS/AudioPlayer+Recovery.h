//
//  AudioPlayer+Recovery.h
//  Vibe (iOS)
//
//  The player's iOS output-recovery half — what AudioPlayer+Devices'
//  rate-change and device-loss handling is on macOS. It lives in this
//  directory so only the VibeiOS target compiles it: the mac app never sees
//  these entry points, where reinitializing after a media-services reset in
//  particular would be harmful (the output-device binding would go stale).
//  AudioSessionController's delegate verdicts are the only callers.
//
//  Both are simple because voices keep their state across an output stop:
//  nothing is rescheduled, and recovery is a unit start.
//

#import "AudioPlayer.h"

@class AVAudioFormat;

NS_ASSUME_NONNULL_BEGIN

typedef void (^VibeMediaServicesResetCompletion)(
        AudioTrack * _Nullable resetTrack,
        NSTimeInterval position);

@interface AudioPlayer (Recovery)

// The route moved without output being lost — headphones or Bluetooth
// connected, an override — or an interruption ended. Follows the route's
// sample rate, rebuilding the pipeline at it with the track kept, and
// restarts a unit the system stopped under a playing voice; the current
// voice continues from the frame it stopped at. Otherwise a no-op: paused
// and stopped players follow lazily at the next start, and the route-loss
// pause is the session controller's separate verdict. A restart with no unit
// to make parks the track Paused (didPausePlaying:); one the unit refuses
// later parks it too, with the error every refused start sends.
- (void)recoverOutput;

// Media services crashed and were relaunched: the output unit and every
// open AudioFileHandle are invalid and must be recreated, per AVAudioSession's
// contract for AVAudioSessionMediaServicesWereResetNotification. Call this on
// the notification's receiving thread. It establishes a player-queue barrier
// at that edge, ordered with play submissions, then drops the invalid objects,
// rebuilds the carrier and reports Stopped with no currentTrack. completion
// runs on main with the pre-reset track and its position after that state is
// authoritative. It is dropped when a play submitted after the reset edge
// owns the rebuilt output instead. Like stop, rebuilding fires no delegate
// callback.
- (void)beginMediaServicesResetWithCompletion:
        (nullable VibeMediaServicesResetCompletion)completion;

@end

NS_ASSUME_NONNULL_END
