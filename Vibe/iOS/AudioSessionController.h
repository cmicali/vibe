//
//  AudioSessionController.h
//  Vibe (iOS)
//
//  The AVAudioSession half of what AudioPlayer+Devices does on macOS:
//  activation and idle release, and the route, interruption, media-services
//  and engine-configuration events, each mapped to a delegate verdict. It
//  never touches the engine graph itself — the delegate maps the verdicts
//  onto the player's public transport and recovery API.
//
//  Main thread only: the delegate verdicts, activate and deactivateWhenIdle
//  all run there, and the notification handlers hop to it.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioSessionController;

@protocol AudioSessionControllerDelegate <NSObject>

// The session lost the output or was interrupted (call, Siri, another app's
// exclusive audio, a route's old device vanishing). Pause if playing, and
// return whether playback was playing when the verdict arrived; the
// controller records that at an interruption's Began edge — and only there —
// to decide the matching Ended resume, so the pauses that pile up
// mid-interruption cannot overwrite it.
- (BOOL)audioSessionShouldPause:(AudioSessionController *)controller;

// An interruption ended and the system says resuming is appropriate. Sent
// only when playback was playing when the matching interruption began.
- (void)audioSessionShouldResume:(AudioSessionController *)controller;

// The engine stopped itself because the output configuration changed — a new
// route or sample rate, as when headphones or Bluetooth connect — not because
// output was lost. Playback should continue on the new route: route the
// verdict to the player's recoverFromEngineConfigurationChange, which
// restarts in place while playing and no-ops otherwise.
- (void)audioSessionEngineConfigurationChanged:(AudioSessionController *)controller;

// Media services crashed and were relaunched: every live audio object is
// invalid. Rebuild through the player's reinitializeAfterMediaServicesReset
// and re-park the current track.
- (void)audioSessionMediaServicesWereReset:(AudioSessionController *)controller;

@end

@interface AudioSessionController : NSObject

@property (nonatomic, weak) id<AudioSessionControllerDelegate> delegate;

// Category Playback + setActive:YES, and cancels any pending idle
// deactivation. Idempotent and cheap — call before every play/resume rather
// than at launch, so Vibe never claims audio it is not using (the same rule
// NowPlayingController applies to the Now Playing card).
- (BOOL)activate;

// Releases the session, with NotifyOthersOnDeactivation so the app Vibe
// interrupted gets its resume hint, once playback has sat idle for a grace
// period longer than the engine's own idle stop. Call whenever playback
// pauses or ends; a subsequent activate cancels it, and it holds off while an
// interruption is in progress, because deactivating mid-interruption can
// forfeit the interruption-ended notification the resume depends on.
- (void)deactivateWhenIdle;

@end

NS_ASSUME_NONNULL_END
