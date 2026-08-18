//
//  PlaybackDeliveryRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline BOOL VibePlaybackDeliveryIsCurrent(
        uint64_t owningSubmittedPlayIdentifier,
        uint64_t newestSubmittedPlayIdentifier) {
    return owningSubmittedPlayIdentifier != 0
            && owningSubmittedPlayIdentifier == newestSubmittedPlayIdentifier;
}

NS_ASSUME_NONNULL_END
