//
//  PlaybackRequestCoordinator.m
//  Vibe
//

#import "PlaybackRequestCoordinator.h"

// Writable only in here. Everything handed out is a copy, so the readonly
// declaration in the header is the whole caller-facing contract.
@interface VibePlaybackRequest ()
@property (nonatomic, strong) id track;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) VibePendingPlaybackIntent intent;
@property (nonatomic) uint64_t identifier;
@property (nonatomic) uint64_t submittedPlayIdentifier;
@property (nonatomic, getter=isSlow) BOOL slow;
@end

@implementation VibePlaybackRequest
@end

@implementation PlaybackRequestCoordinator {
    VibePlaybackRequest *_currentRequest;
    // Never reset, not even by invalidate: a reused identifier would let a
    // worker blocked on a dead mount consume a later open for the same path.
    uint64_t _nextIdentifier;
}

- (VibePlaybackRequest *)currentRequest {
    return [self copyOfRequest:_currentRequest];
}

- (uint64_t)beginWithTrack:(id)track
                      path:(NSString *)path
                    intent:(VibePendingPlaybackIntent)intent
   submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    VibePlaybackRequest *request = [VibePlaybackRequest new];
    request.track = track;
    request.path = [path copy];
    request.intent = intent;
    request.identifier = ++_nextIdentifier;
    request.submittedPlayIdentifier = submittedPlayIdentifier;
    _currentRequest = request;
    return request.identifier;
}

- (VibePlaybackRequestRebind)rebindTrack:(id)track
                                    path:(NSString *)path
                                  intent:(VibePendingPlaybackIntent)intent
                 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    VibePlaybackRequestRebind result = {0};
    VibePlaybackRequest *request = _currentRequest;
    if (!request || ![request.path isEqualToString:path]) {
        return result;
    }
    result.matched = YES;
    result.trackChanged = request.track != track;
    result.pausedChanged = request.intent.paused != intent.paused;
    BOOL submissionChanged = request.submittedPlayIdentifier != submittedPlayIdentifier;
    result.shouldNotifySlowLoad = request.isSlow
            && (result.trackChanged || submissionChanged);
    result.shouldNotifyLoadingPaused = result.trackChanged || result.pausedChanged;
    request.track = track;
    request.intent = intent;
    request.submittedPlayIdentifier = submittedPlayIdentifier;
    return result;
}

- (VibePlaybackRequest *)markSlowForRequest:(uint64_t)identifier {
    VibePlaybackRequest *request = _currentRequest;
    if (!request || request.identifier != identifier || request.isSlow) {
        return nil;
    }
    request.slow = YES;
    return [self copyOfRequest:request];
}

- (VibePlaybackRequest *)togglePause {
    VibePlaybackRequest *request = _currentRequest;
    if (!request) {
        return nil;
    }
    request.intent = VibePendingPlaybackIntentByTogglingPause(request.intent);
    return [self copyOfRequest:request];
}

- (VibePlaybackRequest *)setPausedIfChanged:(BOOL)paused {
    VibePlaybackRequest *request = _currentRequest;
    if (!request || request.intent.paused == paused) {
        return nil;
    }
    VibePendingPlaybackIntent intent = request.intent;
    intent.paused = paused;
    request.intent = intent;
    return [self copyOfRequest:request];
}

- (BOOL)seekToPosition:(NSTimeInterval)position
      ifCurrentTrackIs:(id)track
 submittedPlayIdentifier:(uint64_t)submittedPlayIdentifier {
    VibePlaybackRequest *request = _currentRequest;
    if (!request) {
        return NO;
    }
    // Either identity is enough; see the header for why it is not both.
    BOOL trackMatches = track && request.track == track;
    BOOL playMatches = submittedPlayIdentifier
            && request.submittedPlayIdentifier == submittedPlayIdentifier;
    if (!trackMatches && !playMatches) {
        return NO;
    }
    request.intent = VibePendingPlaybackIntentBySeeking(request.intent, position);
    return YES;
}

- (VibePlaybackRequest *)consumeRequest:(uint64_t)identifier {
    VibePlaybackRequest *request = _currentRequest;
    if (!request || request.identifier != identifier) {
        return nil;
    }
    _currentRequest = nil;
    return [self copyOfRequest:request];
}

- (void)invalidate {
    _currentRequest = nil;
}

- (VibePlaybackRequest *)copyOfRequest:(VibePlaybackRequest *)request {
    if (!request) {
        return nil;
    }
    VibePlaybackRequest *copy = [VibePlaybackRequest new];
    copy.track = request.track;
    copy.path = request.path;
    copy.intent = request.intent;
    copy.identifier = request.identifier;
    copy.submittedPlayIdentifier = request.submittedPlayIdentifier;
    copy.slow = request.slow;
    return copy;
}

@end
