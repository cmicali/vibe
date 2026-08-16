//
//  AudioPlayer+Recovery.h
//  Vibe (iOS)
//
//  The player's iOS engine-recovery half — what AudioPlayer+Devices'
//  config-change and device-loss handling is on macOS. It lives in this
//  directory so only the VibeiOS target compiles it: the mac app never sees
//  these entry points, where reinitializeAfterMediaServicesReset in
//  particular would be harmful (its config-change observer would keep
//  watching the discarded engine, and the output-device binding would go
//  stale). AudioSessionController's delegate verdicts are the only callers.
//

#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (Recovery)

// The engine stopped itself because the output configuration changed — a new
// route or sample rate, as when headphones or Bluetooth connect — not because
// output was lost. Restarts playback in place at the current position,
// preserving the play state. A no-op unless actually playing with a stopped
// engine: paused and stopped players recover lazily through the next
// startEngineAndPlayNode:, and the route-loss pause is the session
// controller's separate verdict.
- (void)recoverFromEngineConfigurationChange;

// Media services crashed and were relaunched: the engine, its nodes and every
// open AVAudioFile are invalid and must be recreated, per AVAudioSession's
// contract for AVAudioSessionMediaServicesWereResetNotification. Drops them
// all, recreates the engine and reinstalls the FX graph, then reports Stopped
// with no currentTrack. Like stop, it fires no delegate callback; the caller
// owns re-parking or replaying the track.
- (void)reinitializeAfterMediaServicesReset;

@end

NS_ASSUME_NONNULL_END
