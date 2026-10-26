//
//  PlaybackShellRules.h
//  Vibe
//
//  How a shell's transport reads the player: when Previous is available, when
//  a seek's settlement is current, and when the deferred metadata sweep runs.
//  Functions of plain values, so both shells agree and they are tested
//  without a player. What the player itself decides is vibe-libs'
//  PlaybackDeliveryRules.h.
//

#import <Foundation/Foundation.h>
#import "VibePlayableItem.h"

NS_ASSUME_NONNULL_BEGIN

// Previous moves to the previous row. On the first row it restarts the
// loaded track instead. Every Previous a shell offers uses this, the system's
// Previous command included, so they agree. The current track is read too:
// stop is asynchronous, so a publish right after a close still reads a player
// that is not stopped.
static inline BOOL VibePlaybackPreviousIsAvailable(BOOL hasPreviousTrack, BOOL hasCurrentTrack,
                                                   BOOL playerIsStopped) {
    return hasPreviousTrack || (hasCurrentTrack && !playerIsStopped);
}

// An empty seek's settlement is meaningful only while still stopped. A real
// row is matched by identity, so another occurrence of its URL cannot own it.
static inline BOOL VibePlaybackSeekSettlementIsCurrent(
        id<VibePlayableItem> _Nullable soughtTrack, id<VibePlayableItem> _Nullable playlistTrack,
        BOOL playerIsStopped) {
    return soughtTrack ? soughtTrack == playlistTrack : playerIsStopped;
}

// The shell defers its metadata sweep until playback settles, with a fallback
// timer. Whichever arrives first consumes the pending work, once. An older
// timer must not consume a newer open's or append's pending sweep.
static inline BOOL VibePlaybackConsumePendingMetadataLoad(
        BOOL *pending, NSUInteger capturedMetadataLoadGeneration,
        NSUInteger currentMetadataLoadGeneration) {
    if (!*pending || capturedMetadataLoadGeneration != currentMetadataLoadGeneration) {
        return NO;
    }
    *pending = NO;
    return YES;
}

NS_ASSUME_NONNULL_END
