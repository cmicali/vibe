//
//  AudioError.h
//  Vibe
//
//  The play path's error vocabulary — domain, userInfo key, codes — apart from
//  the player so that a receiver deciding what to SAY about a failure need not
//  import the engine. AudioPlayer.h imports this, so nothing that already had
//  the codes has to change.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kVibeAudioErrorDomain;
// userInfo key carrying the failing track's URL on play-path errors. Error
// deliveries can race a track change, so receivers must match it against the
// current track before treating the error as the current track's.
extern NSString *const kVibeAudioErrorTrackURLKey;
typedef NS_ENUM(NSInteger, VibeAudioErrorCode) {
    VibeAudioErrorFileOpenFailed = 1,
    VibeAudioErrorEngineStartFailed,
    VibeAudioErrorDeviceUnavailable,
    VibeAudioErrorNotPlaying,
    VibeAudioErrorFileOpenTimedOut,
};

NS_ASSUME_NONNULL_END
