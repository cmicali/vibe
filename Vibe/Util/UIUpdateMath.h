//
//  UIUpdateMath.h
//  Vibe
//
//  The playback-UI tick rate from the numbers alone, for UIUpdateTimer.
//

#import <Foundation/Foundation.h>

// Where an ordinary song rests: 1200 px over four minutes asks ~2.5 Hz.
static const NSUInteger kVibeUIUpdateHzMin = 3;

// Cheap only because the waveform repaints on device-pixel crossings and the
// time labels are change-guarded at one second.
static const double kVibeUITargetPxPerTick = 2.0;

// The playhead moves widthPx × rate / duration device pixels per second;
// this is the Hz that steps it kVibeUITargetPxPerTick per tick, clamped to
// [kVibeUIUpdateHzMin, capHz]. A zero duration (loading, parked) rests at the
// floor. The comparisons send NaN and infinity to a clamp, never to a cast
// with undefined behavior.
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
