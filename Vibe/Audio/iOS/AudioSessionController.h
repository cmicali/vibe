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
//  Main thread only: activate, deactivateWhenIdle and every delegate verdict
//  run there. The media-reset receipt edge is the sole exception, documented
//  on that delegate method: it must establish the player's queue barrier
//  before a later main-thread play can pass it.
//

#import <Foundation/Foundation.h>

#import "OutputRouteRules.h"     // VibeOutputRouteKind, published below

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
// only when playback was playing at the matching Began edge and the controller
// has reactivated without clearing a newer route-loss or media-reset verdict.
- (void)audioSessionShouldResume:(AudioSessionController *)controller;

// The engine stopped itself because the output configuration changed — a new
// route or sample rate, as when headphones or Bluetooth connect — not because
// output was lost. Playback should continue on the new route: route the
// verdict to the player's recoverFromEngineConfigurationChange, which
// restarts in place while playing and no-ops otherwise. The controller
// classifies the previous and current output routes before sending it, so a
// configuration notification that precedes headphone-loss notification is a
// pause instead.
- (void)audioSessionEngineConfigurationChanged:(AudioSessionController *)controller;

// Media services crashed and were relaunched: every live audio object is
// invalid. This is called synchronously on the notification's receiving
// thread, not main. Its only permitted action is beginMediaServicesReset on
// the player; that method's main completion owns UI state and re-parking.
- (void)audioSessionDidReceiveMediaServicesReset:(AudioSessionController *)controller;

// The system moved the audio to a different output, or an activation recorded
// one. Read outputRouteKind and outputRouteName: the event carries no payload
// deliberately, so a burst of route changes coalesces into one read of the
// current answer rather than delivering a pair already moved past.
- (void)audioSessionOutputRouteDidChange:(AudioSessionController *)controller;

@end

@interface AudioSessionController : NSObject

@property (nonatomic, weak, readonly) id<AudioSessionControllerDelegate> delegate;

// Parks the mixable Ambient category on the shared session. Claims nothing,
// activates nothing, registers nothing — call it once before anything can
// build an audio graph, which is why it is a class method rather than part of
// init. AVAudioEngine instantiates its output unit while its master bus is
// wired, and that runs against whatever category the session carries; the
// system default is SoloAmbient, which is not mixable, so without this the
// engine's construction alone stops whatever else the device is playing.
// activate switches to Playback at the first play.
+ (void)prepareIdleCategory;

// Registration begins during initialization, so the delegate must already be
// present when the first notification can arrive.
- (instancetype)initWithDelegate:(id<AudioSessionControllerDelegate>)delegate
        NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Category Playback + setActive:YES, and cancels any pending idle
// deactivation. Idempotent and cheap — call before every user play/resume
// rather than at launch, so Vibe never claims audio it is not using (the same
// rule NowPlayingController applies to the Now Playing card). The controller
// handles interruption-ended automatic activation separately because that
// system suggestion may not clear route-loss or media-reset ownership.
- (BOOL)activate;

// Releases the session, with NotifyOthersOnDeactivation so the app Vibe
// interrupted gets its resume hint, once playback has sat idle for a grace
// period longer than the engine's own idle stop. Call whenever playback
// pauses or ends; a subsequent activate cancels it, and it holds off while an
// interruption is in progress, because deactivating mid-interruption can
// forfeit the interruption-ended notification the resume depends on.
- (void)deactivateWhenIdle;

// What the audio is coming out of. Written together under one lock, so the
// pair is always one route's answer. BEFORE the first activate the session can
// report no outputs at all, which reads as VibeOutputRouteKindNone — and an
// AirPlay destination picked while the session is inactive is not reflected
// until the next activation records it.
@property (nonatomic, readonly) VibeOutputRouteKind outputRouteKind;
@property (nonatomic, readonly, nullable) NSString *outputRouteName;

@end

NS_ASSUME_NONNULL_END
