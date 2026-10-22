//
//  AudioError.m
//  Vibe
//
//  In a file of their own, so the host-less test suite can link the error
//  rules without compiling the player.
//

#import "AudioError.h"

NSString *const kVibeAudioErrorTrackURLKey = @"VibeAudioErrorTrackURL";

static NSString *sDomain;

void VibeAudioErrorSetDomain(NSString *domain) {
    sDomain = [domain copy];
}

NSString *VibeAudioErrorDomain(void) {
    NSString *domain = sDomain;
    NSCAssert(domain, @"VibeAudioErrorSetDomain was not called before the first play-path error");
    return domain ?: @"VibeAudioErrorDomain";
}

// Descriptions are for logs, never localized; the UI's line is
// VibeStatusForPlayError (Common/StringRules.h).
NSError *VibeAudioError(VibeAudioErrorCode code, NSString *description, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
        if (underlying.localizedDescription.length) {
            description = [NSString stringWithFormat:@"%@ (%@)", description, underlying.localizedDescription];
        }
    }
    info[NSLocalizedDescriptionKey] = description;
    return [NSError errorWithDomain:VibeAudioErrorDomain() code:code userInfo:info];
}

// Stamps the failing track's URL (kVibeAudioErrorTrackURLKey).
NSError *VibeAudioErrorForTrack(VibeAudioErrorCode code, NSString *description, NSError *underlying, NSURL *trackURL) {
    NSError *error = VibeAudioError(code, description, underlying);
    if (!trackURL) {
        return error;
    }
    NSMutableDictionary *info = [error.userInfo mutableCopy];
    info[kVibeAudioErrorTrackURLKey] = trackURL;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}
