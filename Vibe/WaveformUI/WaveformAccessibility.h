//
//  WaveformAccessibility.h
//  Vibe
//
//  The waveform slider's spoken contract, shared by both views. Each shell
//  labels its view where it builds it.
//

#import <Foundation/Foundation.h>

// The step is 5% of the track, not seconds: each view knows a 0 to 1
// progress and reports a 0 to 1 seek, never the duration.
static const CGFloat kWaveformAccessibilityStep = 0.05;

// VoiceOver reads an NSNumber verbatim: 0.5 is "zero point five". A whole
// percentage in the user's locale; out-of-range input clamps.
static inline NSString *VibeWaveformAccessibilityValue(CGFloat progress) {
    if (!isfinite(progress)) {
        progress = 0;
    }
    progress = MAX(0.0, MIN(1.0, progress));
    return [NSNumberFormatter localizedStringFromNumber:@(progress)
                                            numberStyle:NSNumberFormatterPercentStyle] ?: @"";
}
