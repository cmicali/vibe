//
//  PlaybackDeliveryRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;

// Previous moves to the previous row. On the first row it restarts the
// loaded track instead. Both shells' Previous, the mac's menu item and the
// system's Previous command use this, so they agree. The current track is
// read too: stop is asynchronous, so a publish right after a close still
// reads a player that is not stopped.
static inline BOOL VibePlaybackPreviousIsAvailable(BOOL hasPreviousTrack, BOOL hasCurrentTrack,
                                                   BOOL playerIsStopped) {
    return hasPreviousTrack || (hasCurrentTrack && !playerIsStopped);
}

// A buffering hold shows Buffering… once it has lasted this long. A shorter
// hold never flashes it. Both shells wait the same.
static const NSTimeInterval kVibeBufferingNoticeDelaySeconds = 0.5;

// A buffering edge, the same in both shells. It sets whether Buffering…
// shows now, and returns YES when the caller arms the delay. A seek during a
// hold ends one hold and starts the next. A notice that ended within the
// delay comes back at once, so the line does not drop out. *endedAt is when a
// shown notice last ended, in system uptime.
static inline BOOL VibeBufferingNoticeNoteEdge(BOOL buffering, NSTimeInterval now,
                                               BOOL *shown, NSTimeInterval *endedAt) {
    if (*shown && !buffering) {
        *endedAt = now;
    }
    *shown = buffering && now - *endedAt < kVibeBufferingNoticeDelaySeconds;
    return buffering && !*shown;
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
