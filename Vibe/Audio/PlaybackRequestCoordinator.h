//
//  PlaybackRequestCoordinator.h
//  Vibe
//
//  Arbitrates the parties that compete over one pending file open — the play
//  that started it, the open worker, the timeout, a prefetch that may deliver
//  it, a re-drop that rebinds its row, and the transport. It owns both the
//  request's state and the decision of what the delegate must be told, which
//  is the half that used to sit inline in AudioPlayer and could not be tested.
//  Foundation-only, so stale-completion and rebind ordering are covered
//  without an AVAudioEngine.
//
//  Queue-confined: every method runs on AudioPlayer's serial player queue.
//

#import <Foundation/Foundation.h>

#import "PlaybackIntent.h"

NS_ASSUME_NONNULL_BEGIN

// What a same-path play changed about the request already in flight, and who
// therefore has to be told.
typedef struct {
    BOOL matched;
    BOOL trackChanged;
    BOOL pausedChanged;
    // The slow-load delegate call already fired against the OLD row object,
    // and the controller drops deliveries whose track is not the playlist's
    // current one — so a rebound row needs it again, or its loading UI never
    // appears for the rest of the open.
    BOOL shouldNotifySlowLoad;
    BOOL shouldNotifyLoadingPaused;
} VibePlaybackRequestRebind;

// One pending open. Callers only ever receive copies (see currentRequest), so
// these are readonly and a held reference cannot be mutated underfoot by a
// later rebind.
@interface VibePlaybackRequest : NSObject

@property (nonatomic, readonly, strong) id track;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) VibePendingPlaybackIntent intent;
@property (nonatomic, readonly) uint64_t identifier;
@property (nonatomic, readonly) uint64_t submittedPlayIdentifier;
@property (nonatomic, readonly, getter=isSlow) BOOL slow;

@end

@interface PlaybackRequestCoordinator : NSObject

// A copy of the request in flight, or nil — a copy so that a caller holding it
// across a delegate hop reads what it asked for, not what a rebind has since
// made of it.
@property (nullable, nonatomic, readonly, strong) VibePlaybackRequest *currentRequest;

// Starting a request supersedes every previous one. Identifiers never repeat
// during this object's lifetime — not even across invalidate — so a late
// worker cannot consume a later open for the same path.
- (uint64_t)beginWithTrack:(id)track
                      path:(NSString *)path
                    intent:(VibePendingPlaybackIntent)intent
   submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

- (BOOL)isLoadingPath:(nullable NSString *)path;

// A play for the path already in flight: adopt its row and intent rather than
// starting a second open. It MUTATES on a match, so call it only from the
// branch that acts on the result.
- (VibePlaybackRequestRebind)rebindTrack:(id)track
                                    path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

// Returns the current request only on its first valid slow delivery.
- (nullable VibePlaybackRequest *)markSlowForRequest:(uint64_t)identifier;
- (nullable VibePlaybackRequest *)togglePause;

// Accepted when EITHER identity still holds: the row the seek was aimed at, or
// the exact play it was submitted against. Each covers what the other cannot —
// the identifier binds a seek issued before its play reached the queue, the
// row covers one issued after — and a rebind swaps the row object for the SAME
// file, so requiring both would drop a seek whose target audio never moved.
// Pass 0 for an identifier the caller could not determine; the decision then
// rests on the row alone.
- (BOOL)seekToPosition:(NSTimeInterval)position
      ifCurrentTrackIs:(nullable id)track
 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier;

// Atomically returns and invalidates the matching request. A completion or
// timeout that loses the race gets nil and must not change playback.
- (nullable VibePlaybackRequest *)consumeRequest:(uint64_t)identifier;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
