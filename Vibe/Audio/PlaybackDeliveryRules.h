//
//  PlaybackDeliveryRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;

// Both ways a macOS track end advances use this: parking a successor in the
// engine, and handling the end callback on main. A setting change must reach
// both even when no prefetched handle ever arrived.
static inline BOOL VibePlaybackShouldAdvanceAtTrackEnd(BOOL hasNextTrack, BOOL pauseAtTrackEnd) {
    return hasNextTrack && !pauseAtTrackEnd;
}

// An empty seek's settlement is meaningful only while still stopped. A real
// row is matched by identity, so another occurrence of its URL cannot own it.
static inline BOOL VibePlaybackSeekSettlementIsCurrent(
        AudioTrack *_Nullable soughtTrack, AudioTrack *_Nullable playlistTrack,
        BOOL playerIsStopped) {
    return soughtTrack ? soughtTrack == playlistTrack : playerIsStopped;
}

// The shell defers its metadata sweep until playback settles, with a fallback
// timer. Consume the pending work once, regardless of which arrives first;
// an older timer must not consume a newer open/append's pending sweep.
static inline BOOL VibePlaybackConsumePendingMetadataLoad(
        BOOL *pending, NSUInteger capturedMetadataLoadGeneration,
        NSUInteger currentMetadataLoadGeneration) {
    if (!*pending || capturedMetadataLoadGeneration != currentMetadataLoadGeneration) {
        return NO;
    }
    *pending = NO;
    return YES;
}

static inline BOOL VibePlaybackDeliveryIsCurrent(
        uint64_t owningSubmittedPlayIdentifier,
        uint64_t newestSubmittedPlayIdentifier) {
    return owningSubmittedPlayIdentifier != 0
            && owningSubmittedPlayIdentifier == newestSubmittedPlayIdentifier;
}

// A media-services reset is not itself a play, so zero is a valid initial
// snapshot here. Its completion may re-park the playlist only if no play was
// submitted while the engine rebuild was in flight.
static inline BOOL VibePlaybackSubmissionStateIsUnchanged(
        uint64_t capturedNewestSubmittedPlayIdentifier,
        uint64_t newestSubmittedPlayIdentifier) {
    return capturedNewestSubmittedPlayIdentifier == newestSubmittedPlayIdentifier;
}

NS_ASSUME_NONNULL_END
