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

// CD frames, the unit of a cue window.
static const NSUInteger kVibeCDFramesPerSecond = 75;

// A track's window in file frames, from its cue window in CD frames (1/75 s):
// rounded at the file's rate, the two rows meeting at a marker round the same
// point, so they stay contiguous at a rate 75 does not divide. A cue end of 0,
// or one past the file's, is the file's end; empty when nothing is left.
static inline NSRange VibeCueWindow(NSUInteger cueStart, NSUInteger cueEnd, double sampleRate, int64_t fileLength) {
    int64_t start = llround((double)cueStart * sampleRate / kVibeCDFramesPerSecond);
    int64_t end = cueEnd > 0 ? MIN(llround((double)cueEnd * sampleRate / kVibeCDFramesPerSecond), fileLength) : fileLength;
    return start < end ? NSMakeRange((NSUInteger)start, (NSUInteger)(end - start)) : NSMakeRange(0, 0);
}

// Seconds into the window → the file frame a voice starts at, clamped to the
// window's last frame: a past-the-end start lands on the last frame rather
// than on nothing.
static inline int64_t VibeClampedStartFrame(NSTimeInterval seconds, double sampleRate, NSRange window) {
    int64_t frame = (int64_t)(seconds * sampleRate);
    return (int64_t)window.location + MAX(0, MIN(frame, (int64_t)window.length - 1));
}

// The inverse: a file frame → seconds into the window.
static inline NSTimeInterval VibeWindowSecondsAtFrame(int64_t frame, double sampleRate, NSRange window) {
    return (NSTimeInterval)(frame - (int64_t)window.location) / sampleRate;
}
