//
//  AudioSessionController.h
//  Vibe (iOS)
//
//  The AVAudioSession half of what AudioPlayer+Devices does on macOS:
//  activation, and the route/interruption events that must pause playback.
//  It never touches the engine — the delegate maps its verdicts onto the
//  player's public transport API.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioSessionController;

@protocol AudioSessionControllerDelegate <NSObject>

// The session lost the output or was interrupted (call, Siri, another app's
// exclusive audio, a route's old device vanishing, media services reset,
// engine config change). Pause if playing.
- (void)audioSessionShouldPause:(AudioSessionController *)controller;

// An interruption ended and the system says resuming is appropriate. Sent
// only when playback was playing when the matching interruption began.
- (void)audioSessionShouldResume:(AudioSessionController *)controller;

@end

@interface AudioSessionController : NSObject

@property (nonatomic, weak) id<AudioSessionControllerDelegate> delegate;

// The delegate reports here whether playback was running as of the last
// shouldPause; the controller reads it to decide whether an
// interruption-ended shouldResume is warranted.
@property (nonatomic, assign) BOOL wasPlayingAtInterruption;

// Category Playback + setActive:YES. Idempotent and cheap — call before
// every play/resume rather than at launch, so Vibe never claims audio it is
// not using (the same rule NowPlayingController applies to the Now Playing
// card).
- (BOOL)activate;

@end

NS_ASSUME_NONNULL_END
