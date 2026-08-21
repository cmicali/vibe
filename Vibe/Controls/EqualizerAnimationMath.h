//
//  EqualizerAnimationMath.h
//  Vibe
//
//  The target and timing decisions for the five equalizer bars. The control
//  polls level snapshots on a slower clock and hands each material target change
//  to Core Animation, which interpolates at the display's cadence.
//

#import <Foundation/Foundation.h>
#import <math.h>

// Fast attack catches transients; slower release bridges low-energy gaps while
// preserving readable motion between analysis results.
static const CFTimeInterval kEqualizerAttackAnimationSeconds = 0.135;
static const CFTimeInterval kEqualizerReleaseAnimationSeconds = 0.55;

// Smaller changes cannot move either edge of a 14-point bar by a meaningful
// fraction of a pixel, and suppressing them prevents publication noise from
// continually replacing an otherwise useful compositor animation.
static const float kEqualizerMaterialTargetDelta = 0.005f;

static inline float VibeEqualizerClampedLevel(float level) {
    if (!isfinite(level) || level <= 0.0f) {
        return 0.0f;
    }
    return level < 1.0f ? level : 1.0f;
}

static inline BOOL VibeEqualizerTargetMateriallyChanged(float current, float target) {
    current = VibeEqualizerClampedLevel(current);
    target = VibeEqualizerClampedLevel(target);
    return fabsf(target - current) >= kEqualizerMaterialTargetDelta;
}

// Direction follows what is visibly on screen, not the previous model target:
// a replacement animation begins at the presentation layer's current scale.
static inline CFTimeInterval
VibeEqualizerAnimationDuration(CGFloat presentationScale, CGFloat targetScale) {
    if (!isfinite(presentationScale) || !isfinite(targetScale)) {
        return kEqualizerReleaseAnimationSeconds;
    }
    return targetScale > presentationScale
            ? kEqualizerAttackAnimationSeconds
            : kEqualizerReleaseAnimationSeconds;
}
