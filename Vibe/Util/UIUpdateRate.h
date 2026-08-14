//
//  UIUpdateRate.h
//  Vibe
//
//  The playback-UI tick rate, as a function of the numbers alone — no timer,
//  no view. MainPlayerController feeds it the waveform's device-pixel width,
//  the cached duration and the varispeed rate, and hands the answer to its
//  UIUpdateTimer.
//

#import <Foundation/Foundation.h>

// The floor is what every ordinary song costs: at 1200 px a four-minute track
// asks for ~2.5 Hz, so the whole normal case rests here. The ceiling is the
// caller's — Settings > Advanced offers 3, 30 (default) and 60 Hz, and a cap
// at the floor is the fixed 3 Hz the app ticked at before this rule existed.
static const NSUInteger kVibeUIUpdateHzMin = 3;

// The step the rate aims for. Raising the rate is cheap only because the
// waveform view repaints on device-pixel crossings and the time labels are
// change-guarded at one second, so ticks that move the playhead a couple of
// pixels cost almost nothing.
static const double kVibeUITargetPxPerTick = 2.0;

// The playhead advances widthPx × rate / duration device pixels per wall
// second (position moves at `rate` file-seconds per wall second, and progress
// is file time over file time). Solving for the rate that steps it
// kVibeUITargetPxPerTick pixels per tick gives the Hz below.
//
// A duration of 0 is the Loading gap and the end-of-playlist park, where the
// cache is zeroed: no playhead speed exists, so rest at the floor. The
// comparisons are written so a NaN or infinite input lands on a clamp rather
// than on a cast with undefined behavior. capHz is the user's ceiling, itself
// floored at kVibeUIUpdateHzMin so no setting can tick slower than the app
// always has.
static inline NSUInteger VibeUIUpdateHzForPlayhead(double widthPx,
                                                   NSTimeInterval duration,
                                                   double rate,
                                                   NSUInteger capHz) {
    NSUInteger ceiling = MAX(capHz, kVibeUIUpdateHzMin);
    if (!(widthPx > 0) || !(duration > 0) || !(rate > 0)) {
        return kVibeUIUpdateHzMin;
    }
    double hz = ceil(widthPx * rate / duration / kVibeUITargetPxPerTick);
    if (!(hz > (double)kVibeUIUpdateHzMin)) {
        return kVibeUIUpdateHzMin;
    }
    if (hz >= (double)ceiling) {
        return ceiling;
    }
    return (NSUInteger)hz;
}
