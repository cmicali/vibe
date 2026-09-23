//
//  AudioPlayer+Recovery.h
//  Vibe (iOS)
//
//  The player's iOS engine-recovery half — what AudioPlayer+Devices'
//  config-change and device-loss handling is on macOS. It lives in this
//  directory so only the VibeiOS target compiles it: the mac app never sees
//  these entry points, where reinitializing after a media-services reset in
//  particular would be harmful (its config-change observer would keep
//  watching the discarded engine, and the output-device binding would go
//  stale). AudioSessionController's delegate verdicts are the only callers.
//
//  Both are simple because voices keep their state across an engine stop:
//  nothing is rescheduled, and recovery is an engine start.
//

#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^VibeMediaServicesResetCompletion)(
        AudioTrack * _Nullable resetTrack,
        NSTimeInterval position);

@interface AudioPlayer (Recovery)

// The engine stopped itself because the output configuration changed — a new
// route or sample rate, as when headphones or Bluetooth connect — not because
// output was lost. Restarts the engine, and the current voice continues from
// the frame it stopped at. A no-op unless actually playing with a stopped
// engine: paused and stopped players recover lazily through the next engine
// start, and the route-loss pause is the session controller's separate
// verdict. A restart that fails parks the track Paused, and says so through
// didPausePlaying:.
- (void)recoverFromEngineConfigurationChange;

// Media services crashed and were relaunched: the engine, its nodes and every
// open AVAudioFile are invalid and must be recreated, per AVAudioSession's
// contract for AVAudioSessionMediaServicesWereResetNotification. Call this on
// the notification's receiving thread. It establishes a player-queue barrier
// at that edge, ordered with play submissions, then drops the invalid objects,
// recreates the engine and reports Stopped with no currentTrack. completion
// runs on main with the pre-reset track and its position after that state is
// authoritative. It is dropped when a play submitted after the reset edge
// owns the rebuilt engine instead. Like stop, rebuilding fires no delegate
// callback.
- (void)beginMediaServicesResetWithCompletion:
        (nullable VibeMediaServicesResetCompletion)completion;

@end

NS_ASSUME_NONNULL_END
