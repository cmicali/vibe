//
//  PlaybackRequestCoordinator.h
//  Vibe
//
//  Request identity for one pending file open, contested by the play that
//  started it, the open worker, the timeout, a prefetch that may deliver it, a
//  re-drop that rebinds its row, and the transport. Owns the request's state
//  and what the delegate must be told. Foundation-only, so it is tested
//  host-less. Player queue only.
//

#import <Foundation/Foundation.h>

#import "PlaybackIntent.h"

// Never imported: the row pointer is stored and compared, never messaged.
@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

// What a same-path play changed about the request in flight.
typedef struct {
    BOOL matched;
    BOOL trackChanged;
    BOOL pausedChanged;
    // A slow-load delivery is guarded by submission identity on main, so a
    // rebind needs a fresh one; the open identifier is unchanged.
    BOOL shouldNotifySlowLoad;
    BOOL shouldNotifyLoadingPaused;
} VibePlaybackRequestRebind;

// Callers receive copies, so a held request is never changed by a rebind.
@interface VibePlaybackRequest : NSObject

@property (nonatomic, readonly, strong) AudioTrack *track;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) VibePendingPlaybackIntent intent;
@property (nonatomic, readonly) uint64_t identifier;
@property (nonatomic, readonly) uint64_t submittedPlayIdentifier;
@property (nonatomic, readonly, getter=isSlow) BOOL slow;

@end

@interface PlaybackRequestCoordinator : NSObject

// A copy, or nil.
@property (nullable, nonatomic, readonly, strong) VibePlaybackRequest *currentRequest;

// Supersedes every previous request. Identifiers never repeat, not even
// across invalidate, so a late worker cannot consume a later open of the
// same path.
- (uint64_t)beginWithTrack:(AudioTrack *)track
                      path:(NSString *)path
                    intent:(VibePendingPlaybackIntent)intent
   submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

// A play for the path already in flight adopts its row and intent instead of
// a second open. Mutates on a match: call it only where the result is acted on.
- (VibePlaybackRequestRebind)rebindTrack:(AudioTrack *)track
                                    path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

// Returns the current request only on its first valid slow delivery.
- (nullable VibePlaybackRequest *)markSlowForRequest:(uint64_t)identifier;
// The system's pause/resume verdicts are states, not toggles: returns the
// request only when its intent changed, so a duplicate delivery is silent.
- (nullable VibePlaybackRequest *)setPausedIfChanged:(BOOL)paused;
// The user's play/pause action remains a true toggle.
- (nullable VibePlaybackRequest *)togglePause;

// Accepted when EITHER the row or the submitted play still holds: the
// identifier covers a seek issued before its play reached the queue, the row
// one issued after, and a rebind swaps the row for the same file, so requiring
// both would drop a valid seek. An identifier of 0 leaves the row alone to
// decide.
- (BOOL)seekToPosition:(NSTimeInterval)position
      ifCurrentTrackIs:(nullable AudioTrack *)track
 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

// Atomically returns and invalidates the matching request. A completion or
// timeout that loses the race gets nil and must not change playback.
- (nullable VibePlaybackRequest *)consumeRequest:(uint64_t)identifier;
- (BOOL)isCurrentRequest:(uint64_t)identifier;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
