//
//  PlaybackIntent.h
//  Vibe
//

#import <Foundation/Foundation.h>

typedef struct {
    NSTimeInterval position;
    BOOL paused;
} VibePendingPlaybackIntent;

static inline VibePendingPlaybackIntent VibePendingPlaybackIntentMake(
        NSTimeInterval position, BOOL paused) {
    return (VibePendingPlaybackIntent){ MAX(0, position), paused };
}

static inline VibePendingPlaybackIntent VibePendingPlaybackIntentByTogglingPause(
        VibePendingPlaybackIntent intent) {
    intent.paused = !intent.paused;
    return intent;
}

static inline VibePendingPlaybackIntent VibePendingPlaybackIntentBySeeking(
        VibePendingPlaybackIntent intent, NSTimeInterval position) {
    intent.position = MAX(0, position);
    return intent;
}

static inline BOOL VibePendingPlaybackIntentIsPlaying(VibePendingPlaybackIntent intent) {
    return !intent.paused;
}
